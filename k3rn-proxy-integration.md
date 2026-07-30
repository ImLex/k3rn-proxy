# K3RN Intel — Auto-Capture Proxy Integration

How the WireGuard + mitmproxy pipeline feeds the **existing K3RN Supabase**
(`players` / `player_ips` / `audit_logs` / `profiles` / `crew_order`) as a third
writer alongside the Discord bot and the web/iOS clients. **Nothing existing
changes**; this adds one migration and one server-side writer.

## Design in one line

The proxy is a **service_role writer, like the bot** — it replicates K3RN's
section-6 write sequence exactly, upserts players by their unique username,
attributes changes to the **scanning crew member's Discord ID**, and logs every
real change as a new audit action `player.capture` (skipping no-op captures).

## Where the proxy sits

```
iPhone (WireGuard, fixed per-member IP) ──game traffic──> Oracle box
     mitmproxy (--ignore-hosts, decrypt only api2.hackex.net)
        │ addon parses API JSON
        ▼  (service_role key, like the Discord bot)
   K3RN Supabase  ← same DB the bot + web + iOS all use
```

Runs next to the existing Discord bot on the same Oracle Ampere box; both use
`service_role` and both must self-enforce the rules RLS applies to clients.

## Migration 0006 — software tables (extends, doesn't modify)

New file `KDBWeb/supabase/migrations/0006_software.sql`. Adds two tables + RLS
in the existing `is_member()` / `is_admin()` style. Does **not** touch `players`,
so the bot and web app keep working unchanged.

```sql
-- Software catalog
create table if not exists software (
  id       uuid primary key default gen_random_uuid(),
  name     text not null unique,
  category text not null default 'UTILITY'
);

-- A player's installed software + level (owner distinguishes target vs self-scan)
create table if not exists installed_software (
  id          uuid primary key default gen_random_uuid(),
  player_id   uuid not null references players(id) on delete cascade,
  software_id uuid not null references software(id) on delete cascade,
  level       int  not null default 1,
  owner       text not null default 'TARGET',
  source      text not null default 'CAPTURE',
  updated_at  timestamptz not null default now(),
  unique (player_id, software_id, owner)
);
create index if not exists idx_inst_player on installed_software(player_id);

alter table software           enable row level security;
alter table installed_software enable row level security;

-- Members read; only service_role writes (proxy/bot). Mirror your existing policy style.
create policy sw_read   on software           for select using (is_member());
create policy inst_read on installed_software for select using (is_member());
-- No member insert/update policies: writes come from service_role (bypasses RLS).
```

> `firewall` already exists on `players` — do NOT duplicate it into software. Keep
> it as the single `players.firewall` column your bot/web already use.

## New audit action

Add `player.capture` to the namespaced action set (`player.create`,
`player.update`, `player.delete`, `player.restore`, `player.merge`,
**`player.capture`**). Same shape (before/after JSON snapshots). This lets the
Activity screen filter auto-captures while still attributing them to the scanner.

## Actor attribution — scanning crew member

Each crew member has a fixed WireGuard IP. Map WG IP → the member's **Discord
snowflake** (the same `discord_user_id` the bot/web use as actor). Captured audit
rows use that ID, so they show the member's nickname in Activity exactly like
manual edits.

```python
WG_IP_TO_DISCORD = {
    "10.8.0.2": ("123456789012345678", "Alice"),   # (discord_user_id, name)
    "10.8.0.3": ("234567890123456789", "Bob"),
}
```

## Proxy writer — replicate K3RN's section-6 sequence

Service_role. For each captured target, do exactly what a human edit does, but
**skip the write entirely if nothing changed** (no audit spam, no `updated_at` bump).

```python
"""mitmproxy addon: capture api2.hackex.net -> K3RN Supabase, as a service_role writer.
Mirrors KDBWeb/src/app/actions/players.ts write sequence. Attributes to scanner."""
import json, os, ipaddress, urllib.request

GAME_HOST   = "api2.hackex.net"
SUPA_URL    = os.environ["SUPABASE_URL"]          # https://eokucxysugglijyvhbdy.supabase.co
SERVICE_KEY = os.environ["SUPABASE_SERVICE_KEY"]  # service_role, server-only

WG_IP_TO_DISCORD = { "10.8.0.2": ("123...","Alice"), "10.8.0.3": ("234...","Bob") }

def _req(method, path, body=None, extra=None):
    url = f"{SUPA_URL}/rest/v1/{path}"
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    for k, v in {"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}",
                 "Content-Type": "application/json", **(extra or {})}.items():
        r.add_header(k, v)
    with urllib.request.urlopen(r, timeout=6) as resp:
        txt = resp.read().decode()
        return json.loads(txt) if txt else None

def normalize_ipv4(s):
    try:
        return str(ipaddress.IPv4Address(s.strip()))   # strips leading zeros, validates
    except Exception:
        return None

def get_player_by_username(username):
    rows = _req("GET", f"players?username=eq.{urllib.parse.quote(username)}"
                        f"&deleted_at=is.null&select=*", extra={"Accept":"application/json"})
    return rows[0] if rows else None

def upsert_player(row):
    return _req("POST", "players?on_conflict=username",
                body=row, extra={"Prefer":"resolution=merge-duplicates,return=representation"})

def upsert_player_ip(player_id, ip):
    _req("POST", "player_ips?on_conflict=player_id,ip",
         body={"player_id": player_id, "ip": ip, "last_seen": "now()"},
         extra={"Prefer":"resolution=merge-duplicates"})

def write_audit(actor_id, actor_name, action, target_id, before, after):
    _req("POST", "audit_logs",
         body={"discord_user_id": actor_id, "discord_username": actor_name,
               "action": action, "target_player_id": target_id,
               "before": before, "after": after})

# Fields the capture is allowed to touch (mirror the column-level grant set).
CAP_FIELDS = ["username","player_id","crew","crew_rank","current_ip","level","firewall","reputation"]

def _changed(before, after):
    if before is None:
        return True
    return any((before.get(k) or None) != (after.get(k) or None) for k in CAP_FIELDS)

def handle_scan(d, actor_id, actor_name):
    username = (d.get("username") or "").strip()
    if not username:
        return
    ip = normalize_ipv4(d["ip"]) if d.get("ip") else None
    before = get_player_by_username(username)

    new_row = {
        "username": username,
        "player_id": (d.get("player_id") or None),
        "crew": (d.get("crew") or None),
        "crew_rank": ("member" if d.get("crew") else None),
        "current_ip": ip,
        "level": d.get("level"),
        "firewall": d.get("firewall"),
        "updated_by": actor_id,
    }
    # merge onto existing so we overwrite only captured fields, keep the rest
    after = {**(before or {}), **{k: v for k, v in new_row.items() if v is not None or k in CAP_FIELDS}}

    if not _changed(before, after):
        # still refresh IP last_seen even on no-op, but skip player update + audit
        if ip and before:
            upsert_player_ip(before["id"], ip)
        return

    saved = upsert_player(new_row)[0]
    pid = saved["id"]
    if ip:
        upsert_player_ip(pid, ip)
    # software (migration 0006)
    for sw in d.get("software", []):
        sid = _upsert_software(sw["name"], sw.get("category","UTILITY"))
        _req("POST", "installed_software?on_conflict=player_id,software_id,owner",
             body={"player_id": pid, "software_id": sid, "level": sw.get("level",1),
                   "owner":"TARGET", "source":"CAPTURE", "updated_at":"now()"},
             extra={"Prefer":"resolution=merge-duplicates"})
    action = "player.capture" if before is None else "player.capture"
    write_audit(actor_id, actor_name, action, pid, before, saved)

def _upsert_software(name, category):
    rows = _req("POST", "software?on_conflict=name",
                body={"name": name, "category": category},
                extra={"Prefer":"resolution=merge-duplicates,return=representation"})
    return rows[0]["id"]

ROUTES = { "/api/v2/scan/result": handle_scan }   # <- real paths from your capture

def response(flow):
    if flow.request.pretty_host != GAME_HOST:
        return
    path = flow.request.path.split("?")[0]
    h = ROUTES.get(path)
    if not h:
        return
    try:
        client_ip = flow.client_conn.peername[0]
    except Exception:
        return
    actor = WG_IP_TO_DISCORD.get(client_ip)
    if not actor:                     # unknown peer -> don't write
        return
    try:
        d = json.loads(flow.response.get_text())
    except Exception:
        return
    h(d, actor[0], actor[1])
```

## Rules the proxy MUST follow (because service_role bypasses RLS)

- Only upsert the **column-level-grant fields** (`CAP_FIELDS`) — never touch
  `deleted_at`, `created_at`, `updated_at` (trigger-maintained).
- **Username is unique, case-insensitive** → always upsert on `username`; a seen
  player is updated, never duplicated. (Your `23505` case becomes a merge.)
- **Every real change → one `audit_logs` row** with full before/after. **No-op
  captures write nothing** (skip player update + audit; only refresh IP last_seen).
- IP: normalize IPv4 (strip leading zeros) before writing; append via
  `player_ips` upsert `on_conflict=player_id,ip`.
- Delete/restore/merge remain **human/bot only** — the proxy never soft-deletes.
- Attribute to the **scanning member's Discord ID**; unknown WG peer → no write.

## iOS app — unchanged from your K3RN guide, plus software

Build the native SwiftUI app per `IOS_APP_GUIDE.md` / `IOS_APP_SPEC.md` as-is
(Discord OAuth, RLS, the 8-9 screens). The only additions:
- Player detail shows **installed software** (read `installed_software` join
  `software`), since capture now populates it.
- Activity screen: add **`player.capture`** to the action filter so members can
  see auto-captured changes (attributed to the scanner's nickname).

## Build order

1. Add & run `0006_software.sql` in K3RN Supabase; verify bot + web still work.
2. Give the proxy the **service_role** key (same box as the bot) + WG-IP→Discord map.
3. Fill `ROUTES` + field mapping from your PC mitmproxy capture.
4. Scan a target -> confirm a `player.capture` audit row appears, attributed to you,
   and the player/IP/software rows update.
5. Build the iOS app from the existing guide (+ software view, + capture filter).

## Watch-outs

- Service_role = full power. The proxy must self-enforce every rule above; there's
  no RLS safety net for it (same responsibility the Discord bot already carries).
- Keep `firewall` only on `players` (don't recreate it in software).
- No-op suppression is essential — without it, every scan bumps `updated_at` and
  floods "Updated Today" + Activity.
- Capturing enemy recon into a shared DB is the kind of companion tooling some game
  ToS forbid — worth a check, same caveat as before.
