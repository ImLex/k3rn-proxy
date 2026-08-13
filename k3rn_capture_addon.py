"""
mitmproxy addon: capture the HackEx targets a member OPENS -> their private
K3RN capture inbox (Supabase `captures`).

This is personal-tracking, not a shared-DB writer. As an api2.hackex.net response
passes through:

  * /v1/user_victim_access (entering/opening a target) is upserted into `captures`,
    owned by the scanning member (resolved from their fixed WireGuard IP ->
    Discord id -> profiles.user_id). One row per (owner, player), refreshed on
    re-open. The target's `user_software` list is captured alongside identity.

  * /v1/user_spam + /v1/user_siphon (the member's OWN deployment screens) are
    upserted into `virus_deployments`, owned by the same member. These feed the
    app's Virus tab (spam/siphon earnings). Each call returns the member's full
    list, so deployments no longer present are marked active=false, not deleted.

  * /v1/victim_user_wallet (opening a target's wallet) patches crypto-held
    (hot/cold) onto that capture row. /v1/wallet_transfer_from_victim (looting)
    appends one row to `target_crypto_events` — the per-target theft time-series
    that drives the app's scoring engine (extractedTotal / rate / trend). Both
    are attributed by victim_user_id, which equals captures.player_id.

Random scans (/v1/user_scan_random etc.) are intentionally IGNORED — only targets
the member actively opens are tracked.

Nothing is written to the shared players/player_ips/audit_logs/installed_software
tables. Promoting a capture into the shared crew DB is an explicit member action
in the iOS app; it never happens automatically here.

It is a service_role writer (bypasses RLS) so it can insert on any member's
behalf, but it only ever touches the `captures` table.

Run:
    SUPABASE_URL=https://xxxx.supabase.co \
    SUPABASE_SERVICE_KEY=<service_role key> \
    K3RN_WG_MAP=./k3rn_capture_map.json \
    mitmdump -s k3rn_capture_addon.py

Response shape (from HE2Bot: mam/*):
    /v1/user_victim_access?victim_user_id=N -> {..identity.., "user_software": [
      {software_type_id, software_level, software_id}, ... ]}
      identity: id/user_id, level, reputation, fw_level, username, ip, crew_tag, ...
"""

import datetime
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import queue
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

logger = logging.getLogger("k3rn_capture")

GAME_HOST = "api2.hackex.net"
GAME_ORIGIN = "https://" + GAME_HOST
# The HackEx app-bundle HMAC secret. Stable through v1.4.2; overridable via env in
# case the game rotates it. Used only to RE-SIGN requests we mutate (deep-scan
# count boost, Bypass victim swap, auto-abort) so the server accepts them.
API_SECRET = os.environ.get(
    "K3RN_APP_SECRET",
    "9778f8bac4f3907226337dc5d4ab706851026b5febafeb9edf01f340109d1fb3",
)
# The one endpoint we actively boost: a random scan. Passive capture ignores it,
# but the scanner rewrites `count` when the member has Deep scan on.
SCAN_PATH = "/v1/user_scan_random"
# A Bypass process start (process_type_id=1, software_id=2) is what unmasks a
# target's real IP; the reveal feature hijacks it to a queued victim.
PROCESS_PATH = "/v1/process"
PROCESS_DELETE_PATH = "/v1/process_delete"
# When no original count is present, cap what the iPhone actually receives so the
# in-game scan screen isn't flooded with the boosted pool.
SCAN_TRUNCATE_DEFAULT = 10


def _sign(method: str, path: str, body: str = "") -> tuple[str, str]:
    """HMAC-SHA256 over `{METHOD}:{path}:{ts}:{body}` (matches the HackEx app and
    the PC scanner addons). Returns (hex_signature, unix_ts)."""
    ts = str(int(time.time()))
    msg = f"{method}:{path}:{ts}:{body}"
    sig = hmac.new(API_SECRET.encode(), msg.encode(), hashlib.sha256).hexdigest()
    return sig, ts


def _set_sig(flow, sig: str, ts: str) -> None:
    """Overwrite the X-Signature / X-Timestamp headers on a request in place,
    preserving the original header casing."""
    keys = {k.lower(): k for k in flow.request.headers.keys()}
    flow.request.headers[keys.get("x-signature", "X-Signature")] = sig
    flow.request.headers[keys.get("x-timestamp", "X-Timestamp")] = ts
# A member opens a target two ways: a fresh target hits /v1/user_victim_access,
# an already-bypassed one hits /v1/user_victim. Both carry identity + user_software.
VICTIM_PATHS = {"/v1/user_victim", "/v1/user_victim_access"}
# The member's own deployment screens -> Virus tab earnings. path -> kind.
VIRUS_PATHS = {"/v1/user_spam": "spam", "/v1/user_siphon": "siphon"}
# Per-target crypto (the live-tracking core), both keyed by victim_user_id:
#   victim_user_wallet     -> crypto HELD snapshot (hot/cold) on the capture row
#   wallet_transfer_from_victim -> one THEFT event appended to the time-series
VICTIM_WALLET_PATH = "/v1/victim_user_wallet"
LOOT_PATH = "/v1/wallet_transfer_from_victim"
# Starting a bypass unmasks the target's IP: POST /v1/process (and the ongoing
# list GET /v1/user_processes) return user_processes[] whose `victim_ip_real` is
# the real full IP even when `ip` is masked "xxx.xxx.xxx.xxx". Keyed by
# victim_user_id, so we patch it straight onto the capture row.
PROCESS_PATHS = {"/v1/process", "/v1/user_processes"}
# The member's OWN account (mirror of the victim capture, for themselves):
#   /v1/user        -> own identity + user_software -> own_profile
#   /v1/user_wallet -> own crypto held (hot/cold)   -> own_profile
OWN_PROFILE_PATH = "/v1/user"
OWN_WALLET_PATH = "/v1/user_wallet"
# Opt-in: when K3RN_DUMP_OWN is set, the raw /v1/user and /v1/user_wallet bodies
# are appended to this file so the exact payload (esp. the device field) can be
# confirmed from a real login, then the mapping tightened. Off by default.
OWN_DUMP_PATH = os.environ.get("K3RN_DUMP_OWN")

# HackEx software_type_id -> display name (from HE2Bot mam/worker.py _SW_NAMES).
SW_NAMES = {
    1: "Firewall", 2: "Bypasser", 3: "Cracker", 4: "Encryptor",
    5: "Antivirus", 6: "Spam", 7: "Rootkit", 9: "Proxy",
    11: "Trace", 13: "Keygen", 15: "Siphon",
}
SW_CATEGORY = {
    "Firewall": "DEFENSE", "Antivirus": "DEFENSE", "Proxy": "DEFENSE",
    "Trace": "DEFENSE", "Encryptor": "DEFENSE",
    "Bypasser": "ATTACK", "Cracker": "ATTACK", "Spam": "ATTACK",
    "Rootkit": "ATTACK", "Siphon": "ATTACK",
    "Keygen": "UTILITY",
}
# Firewall level lives on players.firewall / capture.firewall, not in software.
SW_SKIP_TYPE_IDS = {1}

QUEUE_MAX = 50_000
# How often to re-read the wg_peers registry so self-onboarded crew mates start
# being captured without a proxy restart.
WG_MAP_REFRESH = int(os.environ.get("WG_MAP_REFRESH", "30"))
# Throttle for the unmapped-peer warning: a member whose WG IP isn't in the map
# (missing/revoked wg_peers row, or a stale in-process map) would otherwise be
# dropped silently. Log once per IP per interval so a mis-mapped session that
# fires many game calls doesn't flood the journal.
UNKNOWN_PEER_LOG_INTERVAL = int(os.environ.get("UNKNOWN_PEER_LOG_INTERVAL", "300"))


# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
def _load_wg_map():
    """WG IP -> (discord_user_id, name). JSON: {"10.8.0.2": ["123...", "Alice"]}."""
    path = os.environ.get("K3RN_WG_MAP") or str(
        Path(__file__).with_name("k3rn_capture_map.json")
    )
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = json.load(f)
    except FileNotFoundError:
        logger.warning("WG map file not found at %s — every capture will be skipped", path)
        return {}
    except Exception as exc:  # noqa: BLE001 - startup diagnostics
        logger.error("failed to read WG map %s: %s", path, exc)
        return {}
    return {ip: (str(v[0]), str(v[1])) for ip, v in raw.items()}


# --------------------------------------------------------------------------- #
# Supabase REST helpers (service_role)
# --------------------------------------------------------------------------- #
class Supabase:
    def __init__(self, url: str, service_key: str):
        self.base = url.rstrip("/") + "/rest/v1/"
        self.key = service_key

    def _req(self, method: str, path: str, body=None, prefer: str | None = None):
        url = self.base + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("apikey", self.key)
        req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if prefer:
            req.add_header("Prefer", prefer)
        with urllib.request.urlopen(req, timeout=10) as resp:
            txt = resp.read().decode()
            return json.loads(txt) if txt else None

    def list_wg_peers(self):
        """Active registry rows -> {wg_ip: (discord_id, discord_id)}. Replaces the
        hand-edited K3RN_WG_MAP file: crew mates self-onboard via provision-peer.

        A wg_ip must map to exactly one member. If two non-revoked rows claim the
        same IP for DIFFERENT discord ids (a re-provision that didn't revoke the old
        row, or an allocator race), the IP is ambiguous: REST order isn't stable
        across refreshes, so mapping it would attribute that IP's game traffic to
        one member or the other at random — the member sees the WRONG game account.
        We drop a collided IP from the map and log it loudly, so the colliding
        member captures nothing (and surfaces as an unmapped peer) until the stale
        row is revoked. A loud, safe failure beats silent cross-writing."""
        rows = self._req(
            "GET", "wg_peers?select=wg_ip,discord_id&revoked_at=is.null"
        )
        by_ip: dict[str, set[str]] = {}
        for r in rows or []:
            ip = str(r.get("wg_ip") or "").split("/", 1)[0].strip()
            disc = r.get("discord_id")
            if ip and disc:
                by_ip.setdefault(ip, set()).add(str(disc))
        out = {}
        for ip, discs in by_ip.items():
            if len(discs) > 1:
                logger.error(
                    "wg_peers IP collision: %s claimed by %d active peers %s — "
                    "dropping it from the map (capture disabled for this IP until "
                    "the stale row's revoked_at is set)",
                    ip, len(discs), sorted(discs),
                )
                continue
            disc = next(iter(discs))
            out[ip] = (disc, disc)
        return out

    def get_profile_user_id(self, discord_id: str):
        rows = self._req(
            "GET",
            f"profiles?discord_user_id=eq.{urllib.parse.quote(str(discord_id))}"
            "&select=user_id",
        )
        return rows[0]["user_id"] if rows else None

    def upsert_capture(self, body: dict):
        self._req(
            "POST",
            "captures?on_conflict=owner_user_id,player_id",
            body=body,
            # merge-duplicates updates only the columns we send, so an existing
            # uploaded_at (which we never send) is preserved on re-capture.
            prefer="resolution=merge-duplicates",
        )

    def upsert_virus_deployments(self, rows: list):
        if not rows:
            return
        self._req(
            "POST",
            "virus_deployments?on_conflict=owner_user_id,kind,virus_id",
            body=rows,
            # merge-duplicates: first_seen (never sent) is preserved on existing
            # rows and defaults to now() only on first insert.
            prefer="resolution=merge-duplicates",
        )

    def deactivate_absent(self, owner_user_id: str, kind: str, keep_ids: list):
        """Mark this member's deployments of `kind` that are no longer present
        (not in keep_ids) as inactive, so vanished spam/siphon stops counting."""
        q = (
            f"virus_deployments?owner_user_id=eq.{urllib.parse.quote(owner_user_id)}"
            f"&kind=eq.{urllib.parse.quote(kind)}&active=eq.true"
        )
        if keep_ids:
            joined = ",".join(urllib.parse.quote(str(i)) for i in keep_ids)
            q += f"&virus_id=not.in.({joined})"
        self._req("PATCH", q, body={"active": False})

    def update_capture_crypto(self, owner_user_id: str, player_id: str, body: dict):
        """Patch crypto-held onto an existing capture row. No-op if the member
        hasn't opened this target (no capture) — held crypto needs the identity."""
        q = (
            f"captures?owner_user_id=eq.{urllib.parse.quote(owner_user_id)}"
            f"&player_id=eq.{urllib.parse.quote(player_id)}"
        )
        self._req("PATCH", q, body=body)

    def update_capture_ip(self, owner_user_id: str, player_id: str, ip: str):
        """Patch the unmasked real IP onto an existing capture row. No-op if the
        member has no capture for this target yet (identity comes from user_victim)."""
        q = (
            f"captures?owner_user_id=eq.{urllib.parse.quote(owner_user_id)}"
            f"&player_id=eq.{urllib.parse.quote(player_id)}"
        )
        self._req("PATCH", q, body={"current_ip": ip})

    def update_capture_wallet_address(self, owner_user_id: str, player_id: str, address: str):
        """Patch the target's hx wallet address onto an existing capture row. Sent
        as its own request (not folded into the crypto patch) so it fails in
        isolation if the wallet_address column hasn't been migrated yet — crypto
        capture is unaffected."""
        q = (
            f"captures?owner_user_id=eq.{urllib.parse.quote(owner_user_id)}"
            f"&player_id=eq.{urllib.parse.quote(player_id)}"
        )
        self._req("PATCH", q, body={"wallet_address": address})

    def insert_crypto_event(self, body: dict):
        self._req("POST", "target_crypto_events", body=body)

    # -- scanner (0013) ---------------------------------------------------- #
    def get_all_scan_settings(self):
        """discord_id -> (deep_scan bool, scan_count int). Read in bulk on the
        refresh loop so the request hook can decide to boost without a live DB
        round-trip on every scan."""
        rows = self._req(
            "GET",
            "scan_settings?select=owner_discord_id,deep_scan,scan_count",
        )
        out = {}
        for r in rows or []:
            disc = r.get("owner_discord_id")
            if disc:
                out[str(disc)] = (
                    bool(r.get("deep_scan")),
                    int(r.get("scan_count") or 5000),
                )
        return out

    def upsert_scan_targets(self, rows: list):
        """Accumulating private pool: one row per (owner, player). merge-duplicates
        preserves first_scanned_at (never re-sent) while refreshing the rest."""
        if not rows:
            return
        self._req(
            "POST",
            "scan_targets?on_conflict=owner_user_id,player_id",
            body=rows,
            prefer="resolution=merge-duplicates",
        )

    def get_pending_reveal(self, owner_user_id: str):
        """The member's single pending reveal target, or None. Read live per Bypass
        (rare) so a just-queued reveal is honored immediately."""
        rows = self._req(
            "GET",
            f"reveal_queue?owner_user_id=eq.{urllib.parse.quote(owner_user_id)}"
            "&status=eq.pending&select=id,player_id&limit=1",
        )
        return rows[0] if rows else None

    def resolve_reveal(self, reveal_id: str, ip: str | None, status: str):
        self._req(
            "PATCH",
            f"reveal_queue?id=eq.{urllib.parse.quote(str(reveal_id))}",
            body={
                "status": status,
                "real_ip": ip,
                "resolved_at": _now_iso(),
            },
        )

    def update_scan_real_ip(self, owner_user_id: str, player_id: str, ip: str):
        q = (
            f"scan_targets?owner_user_id=eq.{urllib.parse.quote(owner_user_id)}"
            f"&player_id=eq.{urllib.parse.quote(str(player_id))}"
        )
        self._req("PATCH", q, body={"real_ip": ip})

    def upsert_own_profile(self, body: dict):
        """One row per (member, game account) — see 0011. merge-duplicates so the
        profile handler and the wallet handler can each write their own columns
        without clobbering the other's (crypto vs identity/software)."""
        self._req(
            "POST",
            "own_profile?on_conflict=owner_user_id,player_id",
            body=body,
            prefer="resolution=merge-duplicates",
        )


# --------------------------------------------------------------------------- #
# Parsing
# --------------------------------------------------------------------------- #
def normalize_ipv4(s):
    try:
        return str(ipaddress.IPv4Address(str(s).strip()))
    except Exception:  # noqa: BLE001 - malformed IP -> drop the IP, keep the row
        return None


def _clean(v):
    if v is None:
        return None
    if isinstance(v, str):
        s = v.strip()
        return s or None
    return v


def _num(v):
    """Coerce a possibly-string game field to a number, else None."""
    if v is None or v == "":
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return int(f) if f.is_integer() else f


def _int(v):
    n = _num(v)
    return int(n) if n is not None else None


def map_spam(r: dict) -> dict | None:
    """/v1/user_spam row -> virus_deployments columns (kind='spam')."""
    vid = r.get("id") or r.get("virus_id")
    if vid is None:
        return None
    return {
        "kind": "spam",
        "virus_id": str(vid),
        "ip": _clean(r.get("victim_ip") or r.get("ip") or r.get("address")),
        "level": _int(r.get("spam_level") or r.get("level")),
        "earning_rate_hr": _num(r.get("earning_rate_hr")),
        "total_earned": _num(r.get("total_earnings")),
        "age_days": _int(r.get("days_deployed")),
        "decay_pct": _num(r.get("decay_pct")),
    }


def map_siphon(r: dict) -> dict | None:
    """/v1/user_siphon row -> virus_deployments columns (kind='siphon')."""
    vid = r.get("id") or r.get("virus_id")
    if vid is None:
        return None
    return {
        "kind": "siphon",
        "virus_id": str(vid),
        "ip": _clean(r.get("victim_ip") or r.get("ip") or r.get("address")),
        "level": _int(r.get("siphon_level") or r.get("level")),
        "percent": _num(r.get("siphon_rate") or r.get("percent")),
        "total_siphoned": _num(r.get("total_siphoned")),
    }


def parse_result(r: dict) -> dict | None:
    """Map a raw HackEx victim identity dict onto capture columns."""
    username = (r.get("username") or "").strip()
    if not username:
        return None
    pid = r.get("id") or r.get("user_id")
    fw = r.get("fw_level")
    if fw is None:
        fw = r.get("firewall_level")
    return {
        "username": username,
        "player_id": str(pid) if pid is not None else None,
        "current_ip": normalize_ipv4(r.get("ip")) if r.get("ip") else None,
        "level": r.get("level"),
        "firewall": fw,
        "reputation": r.get("reputation"),
    }


def parse_scan_row(r: dict) -> dict | None:
    """Map one /v1/user_scan_random result onto scan_targets columns. Keeps the
    masked/displayed `ip` as-is (real_ip is filled later by a reveal). The row
    fields mirror a victim identity: id/level/reputation/firewall_level/status/
    username/ip/created_at."""
    if not isinstance(r, dict):
        return None
    pid = r.get("id") or r.get("user_id")
    if pid is None:
        return None
    username = (r.get("username") or "").strip() or None
    fw = r.get("firewall_level")
    if fw is None:
        fw = r.get("fw_level")
    return {
        "player_id": str(pid),
        "username": username,
        "ip": _clean(r.get("ip")),
        "level": _int(r.get("level")),
        "firewall": _int(fw),
        "reputation": _int(r.get("reputation")),
        "status": _clean(r.get("status")),
        "game_created_at": _clean(r.get("created_at")),
    }


def _own_device(data: dict) -> str | None:
    """Own-device label from /v1/user. Confirmed by the K3RN_DUMP_OWN capture:
    the device is a `user_device` subobject whose `name` is the human-readable
    model (e.g. "Raider"). Falls back to flat keys if the shape ever changes."""
    dev = data.get("user_device")
    if isinstance(dev, dict):
        name = dev.get("name")
        if name:
            return str(name).strip()
    for key in ("device_name", "device", "device_type"):
        v = data.get(key)
        if v is not None and v != "":
            return str(v)
    return None


def _wallet_address(w: dict) -> str | None:
    """The target's hx wallet address from a user_wallet object. Confirmed key is
    `address` (mirrors own /v1/user_wallet); fallbacks cover shape drift."""
    for key in ("address", "wallet_address", "hx_address", "hot_address"):
        v = _clean(w.get(key))
        if v:
            return v
    return None


def _now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


# --------------------------------------------------------------------------- #
# Addon
# --------------------------------------------------------------------------- #
class K3rnCapture:
    def __init__(self):
        url = os.environ.get("SUPABASE_URL")
        key = os.environ.get("SUPABASE_SERVICE_KEY")
        self.enabled = bool(url and key)
        self.db = Supabase(url, key) if self.enabled else None
        self.wg_map = _load_wg_map()
        self._q: "queue.Queue[dict]" = queue.Queue(QUEUE_MAX)
        self._worker: threading.Thread | None = None
        self._uid_cache: dict[str, str] = {}  # discord_id -> profiles.user_id
        # owner_user_id -> the own game account (player_id) last seen logged in,
        # so the wallet handler (which carries no player_id) can target the right
        # own_profile row when a member has several HackEx accounts.
        self._own_pid: dict[str, str] = {}
        # discord_id -> (deep_scan, scan_count), refreshed on the wg-map loop so
        # the request hook decides the boost without a live DB read per scan.
        self._scan_settings: dict[str, tuple[bool, int]] = {}
        # wg_ip -> monotonic time it was last warned about as unmapped. Throttles
        # the unknown-peer log so a mis-mapped session doesn't flood the journal.
        self._unknown_ip_log: dict[str, float] = {}

    # -- mitmproxy lifecycle ------------------------------------------------ #
    def running(self):
        if not self.enabled:
            logger.error(
                "SUPABASE_URL / SUPABASE_SERVICE_KEY not set — K3RN capture is OFF"
            )
            return
        if self._worker is None:
            # The registry is the source of truth; the file map (if any) is only a
            # fallback if the first DB read fails.
            try:
                peers = self.db.list_wg_peers()
                if peers:
                    self.wg_map = peers
            except Exception as exc:  # noqa: BLE001 - fall back to file map
                logger.warning("initial wg_peers load failed, using file map: %s", exc)
            self._worker = threading.Thread(
                target=self._drain, name="k3rn-capture", daemon=True
            )
            self._worker.start()
            threading.Thread(
                target=self._refresh_wg_map, name="k3rn-wgmap", daemon=True
            ).start()
            logger.info(
                "K3RN capture inbox writer started (%d WG peers mapped)", len(self.wg_map)
            )

    def _refresh_wg_map(self):
        """Periodically re-read wg_peers so a newly self-provisioned crew mate is
        captured without a restart. A failed read keeps the last good map. The same
        loop refreshes each member's Deep-scan setting."""
        while True:
            time.sleep(WG_MAP_REFRESH)
            try:
                peers = self.db.list_wg_peers()
                if peers:
                    self.wg_map = peers
            except Exception as exc:  # noqa: BLE001 - keep the last good map
                logger.warning("wg_peers refresh failed: %s", exc)
            try:
                self._scan_settings = self.db.get_all_scan_settings()
            except Exception as exc:  # noqa: BLE001 - keep the last good settings
                logger.warning("scan_settings refresh failed: %s", exc)

    def request(self, flow):
        """Ride the member's own in-flight request. Two active mutations, both
        opt-in and both re-signed so the server's device_check still passes:
          * Deep-scan boost: rewrite the scan `count` up to the member's setting.
          * Reveal hijack: redirect a Bypass start to a queued reveal target.
        Everything else passes through untouched."""
        if not self.enabled or flow.request.pretty_host != GAME_HOST:
            return
        ip = self._client_ip(flow)
        actor = self.wg_map.get(ip)
        if not actor:  # unknown WG peer -> not one of our members
            self._note_unknown_peer(ip)
            return
        path = flow.request.path.split("?", 1)[0]
        if flow.request.method == "GET" and path == SCAN_PATH:
            self._boost_scan(flow, actor)
        elif flow.request.method == "POST" and path == PROCESS_PATH:
            self._hijack_bypass(flow, actor)

    def _boost_scan(self, flow, actor):
        """If the member has Deep scan on, raise `count` to their scan_count and
        re-sign. The original count is stashed so the response is truncated back to
        it — the in-game scan screen looks unchanged."""
        actor_id, _ = actor
        deep, scan_count = self._scan_settings.get(actor_id, (False, 0))
        if not deep:
            return
        orig = flow.request.query.get("count")
        flow.request.query["count"] = str(scan_count)
        flow.metadata["k3rn_scan_boost"] = True
        flow.metadata["k3rn_scan_orig"] = orig
        sig, ts = _sign("GET", flow.request.path)
        _set_sig(flow, sig, ts)

    def _hijack_bypass(self, flow, actor):
        """A Bypass start (process_type_id=1, software_id=2) unmasks a target's real
        IP. If the member has a pending reveal queued, swap the victim to that target
        and re-sign; the response handler reads victim_ip_real and auto-aborts."""
        body = self._req_json(flow)
        if not body:
            return
        try:
            if int(body.get("process_type_id", 0)) != 1 or int(body.get("software_id", 0)) != 2:
                return
        except (TypeError, ValueError):
            return
        owner_user_id = self._resolve_user_id(actor[0])
        if not owner_user_id:
            return
        try:
            pending = self.db.get_pending_reveal(owner_user_id)
        except Exception as exc:  # noqa: BLE001 - a failed read must not break the bypass
            logger.warning("reveal lookup failed: %s", exc)
            return
        if not pending:
            return
        target_pid = str(pending.get("player_id"))
        body["victim_user_id"] = target_pid
        new_text = json.dumps(body, separators=(",", ":"))
        flow.request.set_text(new_text)
        sig, ts = _sign("POST", flow.request.path, new_text)
        _set_sig(flow, sig, ts)
        flow.metadata["k3rn_reveal_id"] = pending.get("id")
        flow.metadata["k3rn_reveal_pid"] = target_pid
        flow.metadata["k3rn_reveal_owner"] = owner_user_id

    def response(self, flow):
        if not self.enabled or flow.request.pretty_host != GAME_HOST:
            return
        path = flow.request.path.split("?", 1)[0]
        # Scanner: a boosted scan is captured into the private pool, then its
        # response is truncated back to the original count. Only fires when the
        # request hook actually boosted it (member had Deep scan on).
        if path == SCAN_PATH and flow.metadata.get("k3rn_scan_boost"):
            self._handle_scan_response(flow)
            return
        # Reveal: a hijacked Bypass carries the queued target's real IP. Finish the
        # reveal (patch real_ip, resolve queue, auto-abort) — but still fall through
        # so the passive victim_ip capture runs too.
        if path == PROCESS_PATH and flow.metadata.get("k3rn_reveal_id"):
            self._handle_reveal_response(flow)
        is_victim = path in VICTIM_PATHS
        virus_kind = VIRUS_PATHS.get(path)
        is_wallet = path == VICTIM_WALLET_PATH
        is_loot = path == LOOT_PATH
        is_own_profile = path == OWN_PROFILE_PATH
        is_own_wallet = path == OWN_WALLET_PATH
        is_process = path in PROCESS_PATHS
        if not (is_victim or virus_kind or is_wallet or is_loot
                or is_own_profile or is_own_wallet or is_process):
            return  # not one of the endpoints we track
        ip = self._client_ip(flow)
        actor = self.wg_map.get(ip)
        if not actor:  # unknown WG peer -> not one of our members
            self._note_unknown_peer(ip)
            return
        data = self._json_body(flow)
        if data is None:
            return
        if (is_own_profile or is_own_wallet) and OWN_DUMP_PATH:
            self._dump_own(path, data)
        if is_victim:
            self._enqueue({
                "job": "victim",
                "victim_user_id": flow.request.query.get("victim_user_id"),
                "data": data,
                "actor": actor,
            })
        elif virus_kind:
            self._enqueue({
                "job": "virus",
                "kind": virus_kind,
                "rows": data.get(virus_kind) or [],
                "actor": actor,
            })
        elif is_wallet:
            self._enqueue({
                "job": "wallet",
                "victim_user_id": flow.request.query.get("victim_user_id"),
                "data": data,
                "actor": actor,
            })
        elif is_loot:
            if not data.get("success"):
                return  # rejected loot steals nothing
            req = self._req_json(flow)
            self._enqueue({
                "job": "theft",
                "victim_user_id": (req.get("victim_user_id")
                                   if req else None),
                "requested": (req.get("amount") if req else None),
                "data": data,
                "actor": actor,
            })
        elif is_own_profile:
            self._enqueue({"job": "own_profile", "data": data, "actor": actor})
        elif is_own_wallet:
            self._enqueue({"job": "own_wallet", "data": data, "actor": actor})
        elif is_process:
            self._enqueue({
                "job": "victim_ip",
                "procs": data.get("user_processes") or [],
                "actor": actor,
            })

    def _enqueue(self, job):
        try:
            self._q.put_nowait(job)
        except queue.Full:
            logger.warning("capture queue full — dropping job")

    # -- helpers ------------------------------------------------------------ #
    @staticmethod
    def _client_ip(flow):
        cc = flow.client_conn
        peer = getattr(cc, "peername", None) or getattr(cc, "address", None)
        return peer[0] if peer else None

    def _note_unknown_peer(self, ip):
        """A GAME_HOST flow from a WG IP that isn't in the map — almost always a
        crew member whose wg_peers row is missing/revoked, or a stale in-process
        map after a re-provision. These used to drop silently (no write, no log),
        which turned one member's stalled capture into a multi-hour hunt. Warn once
        per IP per UNKNOWN_PEER_LOG_INTERVAL so a mis-mapped session doesn't flood."""
        if not ip:
            return
        now = time.monotonic()
        if now - self._unknown_ip_log.get(ip, 0.0) < UNKNOWN_PEER_LOG_INTERVAL:
            return
        self._unknown_ip_log[ip] = now
        logger.warning(
            "unmapped WG peer %s hit %s — capture dropped (IP not in wg_map; "
            "check wg_peers row / revoked_at, or restart to rebuild the map)",
            ip, GAME_HOST,
        )

    @staticmethod
    def _json_body(flow):
        try:
            data = json.loads(flow.response.get_text())
        except Exception:  # noqa: BLE001 - non-JSON / empty body
            return None
        return data if isinstance(data, dict) else None

    @staticmethod
    def _req_json(flow):
        try:
            data = json.loads(flow.request.get_text())
        except Exception:  # noqa: BLE001 - non-JSON / empty request body
            return None
        return data if isinstance(data, dict) else None

    @staticmethod
    def _dump_own(path: str, data: dict):
        """Debug: append a raw own-account payload for shape confirmation."""
        try:
            with open(OWN_DUMP_PATH, "a", encoding="utf-8") as f:
                f.write(json.dumps({"path": path, "at": _now_iso(), "body": data}) + "\n")
        except Exception as exc:  # noqa: BLE001 - dump is best-effort
            logger.warning("own dump failed: %s", exc)

    def _resolve_user_id(self, discord_id: str):
        uid = self._uid_cache.get(discord_id)
        if uid:
            return uid
        uid = self.db.get_profile_user_id(discord_id)
        if uid:
            self._uid_cache[discord_id] = uid  # only cache hits; misses may resolve later
        return uid

    @staticmethod
    def _software_list(raw):
        """Return (software_list, firewall_level). Firewall (type 1) is not a
        listed item — its level populates the capture's firewall column instead."""
        out = []
        firewall = None
        for sw in raw or []:
            try:
                type_id = int(sw.get("software_type_id", 0) or 0)
            except (TypeError, ValueError):
                continue
            if type_id == 0:
                continue
            level = sw.get("software_level")
            if type_id in SW_SKIP_TYPE_IDS:
                try:
                    firewall = int(level) if level is not None else firewall
                except (TypeError, ValueError):
                    pass
                continue
            name = SW_NAMES.get(type_id, f"Software {type_id}")
            lvl = _int(level)
            out.append({
                "name": name,
                "category": SW_CATEGORY.get(name, "UTILITY"),
                "level": lvl if lvl is not None else 1,
            })
        return out, firewall

    # -- writer thread ------------------------------------------------------ #
    def _drain(self):
        while True:
            job = self._q.get()
            try:
                kind = job.get("job")
                if kind == "virus":
                    self._capture_virus(job)
                elif kind == "wallet":
                    self._capture_wallet(job)
                elif kind == "theft":
                    self._capture_theft(job)
                elif kind == "own_profile":
                    self._capture_own_profile(job)
                elif kind == "own_wallet":
                    self._capture_own_wallet(job)
                elif kind == "victim_ip":
                    self._capture_victim_ip(job)
                elif kind == "scan":
                    self._capture_scan(job)
                elif kind == "reveal":
                    self._reveal(job)
                else:
                    self._capture(job)
            except Exception as exc:  # noqa: BLE001 - never kill the writer loop
                logger.error("capture write failed: %s", exc)
            finally:
                self._q.task_done()

    def _capture(self, job):
        actor_id, _actor_name = job["actor"]
        owner_user_id = self._resolve_user_id(actor_id)
        if not owner_user_id:
            logger.info("no profile for discord %s yet — capture skipped", actor_id)
            return

        data = job["data"]
        vid = job.get("victim_user_id")
        ident = data.get("user") if isinstance(data.get("user"), dict) else {}
        merged = {**ident, **{k: data[k] for k in
                              ("id", "user_id", "username", "ip", "level",
                               "reputation", "fw_level", "firewall_level",
                               "crew_tag", "clan", "crew")
                              if k in data}}
        if merged.get("id") is None and merged.get("user_id") is None and vid:
            merged["user_id"] = vid

        parsed = parse_result(merged)
        if not parsed:
            return

        software, fw_from_sw = self._software_list(data.get("user_software", []))
        body = {
            "owner_user_id": owner_user_id,
            "owner_discord_id": actor_id,
            "player_id": parsed["player_id"],
            "username": parsed["username"],
            "level": parsed["level"],
            "firewall": parsed["firewall"] if parsed["firewall"] is not None else fw_from_sw,
            "reputation": parsed["reputation"],
            # The game sends the crew tag as `crew_tag` ("TRSEC"); clan/crew are
            # older payload spellings kept as fallbacks.
            "crew": _clean(merged.get("crew_tag") or merged.get("clan")
                           or merged.get("crew")),
            "software": software,
            "captured_at": _now_iso(),
        }
        # Only write current_ip when we actually have one. Opening a masked target
        # yields no IP (parsed["current_ip"] is None); sending null would clobber a
        # real IP already patched in from a bypass (/v1/process).
        if parsed["current_ip"]:
            body["current_ip"] = parsed["current_ip"]
        self.db.upsert_capture(body)

    def _capture_victim_ip(self, job):
        """A bypass start (POST /v1/process) or the ongoing-process list unmasks
        the target's real IP in `victim_ip_real`. Patch it onto the matching
        capture row, keyed by victim_user_id. normalize_ipv4 rejects the masked
        "xxx.xxx.xxx.xxx" sentinel, so only a genuine IP is written."""
        actor_id, _actor_name = job["actor"]
        owner_user_id = self._resolve_user_id(actor_id)
        if not owner_user_id:
            return
        procs = job.get("procs") or []
        if isinstance(procs, dict):
            procs = [procs]
        real_by_victim = {}
        for p in procs:
            if not isinstance(p, dict):
                continue
            vid = p.get("victim_user_id")
            real = normalize_ipv4(p.get("victim_ip_real"))
            if vid is None or not real:
                continue
            real_by_victim[str(vid)] = real  # dedupe repeated victims in the list
        for player_id, ip in real_by_victim.items():
            self.db.update_capture_ip(owner_user_id, player_id, ip)

    # -- scanner (0013) ----------------------------------------------------- #
    def _handle_scan_response(self, flow):
        """Boosted /v1/user_scan_random: enqueue the full pool into scan_targets,
        then truncate the response back to the original count so the game UI is
        unchanged. Runs in the response hook so truncation happens before the body
        is handed to the iPhone."""
        actor = self.wg_map.get(self._client_ip(flow))
        data = self._json_body(flow)
        results = (data or {}).get("scan_results")
        if actor and isinstance(results, list):
            self._enqueue({"job": "scan", "rows": results, "actor": actor})
        # Truncate what the iPhone receives back to its original count.
        if isinstance(results, list):
            try:
                orig = int(flow.metadata.get("k3rn_scan_orig"))
            except (TypeError, ValueError):
                orig = SCAN_TRUNCATE_DEFAULT
            if orig < 0:
                orig = SCAN_TRUNCATE_DEFAULT
            data["scan_results"] = results[:orig]
            try:
                flow.response.set_text(json.dumps(data))
            except Exception as exc:  # noqa: BLE001 - leave body as-is on failure
                logger.warning("scan truncate failed: %s", exc)

    def _handle_reveal_response(self, flow):
        """Hijacked Bypass response: read the queued target's real IP + process id,
        then hand off to the writer to patch scan_targets, resolve the reveal, and
        auto-abort the process (single-lookup — never leave it running)."""
        data = self._json_body(flow)
        pid = flow.metadata.get("k3rn_reveal_pid")
        procs = (data or {}).get("user_processes") or []
        if isinstance(procs, dict):
            procs = [procs]
        real_ip, process_id = None, None
        for p in procs:
            if isinstance(p, dict) and str(p.get("victim_user_id")) == str(pid):
                real_ip = normalize_ipv4(p.get("victim_ip_real") or p.get("ip"))
                process_id = p.get("id")
                break
        if process_id is None:  # fall back to the newest process just started
            for p in procs:
                if isinstance(p, dict):
                    real_ip = real_ip or normalize_ipv4(
                        p.get("victim_ip_real") or p.get("ip"))
                    process_id = p.get("id")
                    break
        self._enqueue({
            "job": "reveal",
            "reveal_id": flow.metadata.get("k3rn_reveal_id"),
            "owner_user_id": flow.metadata.get("k3rn_reveal_owner"),
            "player_id": pid,
            "real_ip": real_ip,
            "process_id": process_id,
            "session": self._session_headers(flow),
        })

    def _capture_scan(self, job):
        actor_id, _ = job["actor"]
        owner_user_id = self._resolve_user_id(actor_id)
        if not owner_user_id:
            logger.info("no profile for discord %s yet — scan skipped", actor_id)
            return
        now = _now_iso()
        rows = []
        for raw in job.get("rows") or []:
            mapped = parse_scan_row(raw)
            if not mapped:
                continue
            rows.append({
                "owner_user_id": owner_user_id,
                "owner_discord_id": actor_id,
                "last_scanned_at": now,
                **mapped,
            })
        self.db.upsert_scan_targets(rows)

    def _reveal(self, job):
        owner = job.get("owner_user_id")
        pid = job.get("player_id")
        ip = job.get("real_ip")
        reveal_id = job.get("reveal_id")
        if ip and owner and pid:
            try:
                self.db.update_scan_real_ip(owner, str(pid), ip)
            except Exception as exc:  # noqa: BLE001 - resolve the queue regardless
                logger.warning("scan real_ip patch failed: %s", exc)
        if reveal_id:
            self.db.resolve_reveal(reveal_id, ip, "done" if ip else "failed")
        # Auto-abort the hijacked bypass so the member's tap doesn't actually run a
        # bypass against the reveal target — single lookup, never looped.
        process_id = job.get("process_id")
        if process_id is not None:
            self._abort_process(job.get("session") or {}, process_id)

    def _abort_process(self, session, process_id):
        """POST /v1/process_delete signed by us, forwarding the iPhone's own auth
        headers (api key / cookie / UA) so the server accepts the abort."""
        body = json.dumps({"process_id": str(process_id)}, separators=(",", ":"))
        sig, ts = _sign("POST", PROCESS_DELETE_PATH, body)
        req = urllib.request.Request(
            GAME_ORIGIN + PROCESS_DELETE_PATH, data=body.encode(), method="POST"
        )
        for k, v in (session or {}).items():
            req.add_header(k, v)
        req.add_header("Content-Type", "application/json")
        req.add_header("X-Signature", sig)
        req.add_header("X-Timestamp", ts)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                resp.read()
        except Exception as exc:  # noqa: BLE001 - abort is best-effort
            logger.warning("process_delete (auto-abort) failed: %s", exc)

    @staticmethod
    def _session_headers(flow):
        """The iPhone request's auth headers, minus anything we must recompute
        (signing) or that urllib sets itself (host/content-length/encoding)."""
        skip = {"host", "content-length", "content-type", "accept-encoding",
                "x-signature", "x-timestamp"}
        out = {}
        for k in flow.request.headers.keys():
            if k.lower() not in skip:
                out[k] = flow.request.headers[k]
        return out

    def _capture_virus(self, job):
        actor_id, _actor_name = job["actor"]
        owner_user_id = self._resolve_user_id(actor_id)
        if not owner_user_id:
            logger.info("no profile for discord %s yet — virus capture skipped", actor_id)
            return

        kind = job["kind"]
        mapper = map_spam if kind == "spam" else map_siphon
        now = _now_iso()
        rows, keep_ids = [], []
        for raw in job.get("rows") or []:
            if not isinstance(raw, dict):
                continue
            mapped = mapper(raw)
            if not mapped:
                continue
            keep_ids.append(mapped["virus_id"])
            rows.append({
                "owner_user_id": owner_user_id,
                "owner_discord_id": actor_id,
                "active": True,
                "last_seen": now,
                "captured_at": now,
                **mapped,
            })

        self.db.upsert_virus_deployments(rows)
        # A deployment that dropped off the member's list (removed / expired) is
        # marked inactive so it stops counting toward live earnings.
        self.db.deactivate_absent(owner_user_id, kind, keep_ids)

    def _capture_wallet(self, job):
        """GET /v1/victim_user_wallet -> crypto-held snapshot on the capture."""
        actor_id, _ = job["actor"]
        owner_user_id = self._resolve_user_id(actor_id)
        if not owner_user_id:
            return
        player_id = job.get("victim_user_id")
        if player_id is None:
            return
        wallet = job["data"].get("user_wallet")
        if not isinstance(wallet, dict):
            return
        self.db.update_capture_crypto(owner_user_id, str(player_id), {
            "crypto_hot": _num(wallet.get("hot")),
            "crypto_cold": _num(wallet.get("cold")),
            "crypto_updated_at": _now_iso(),
        })
        # The victim wallet payload also carries the target's persistent hx address.
        # Patched separately so a missing wallet_address column (pre-0010) can't
        # roll back the crypto write above.
        addr = _wallet_address(wallet)
        if addr:
            try:
                self.db.update_capture_wallet_address(owner_user_id, str(player_id), addr)
            except Exception as exc:  # noqa: BLE001 - address is best-effort until 0010 is run
                logger.warning("wallet_address patch skipped (run 0010?): %s", exc)

    def _capture_theft(self, job):
        """POST /v1/wallet_transfer_from_victim -> append one theft event."""
        actor_id, _ = job["actor"]
        owner_user_id = self._resolve_user_id(actor_id)
        if not owner_user_id:
            return
        player_id = job.get("victim_user_id")
        if player_id is None:
            return
        data = job["data"]
        amount = _num(
            data.get("amount_transfered",
                     data.get("amount_transferred", job.get("requested")))
        )
        if not amount:  # nothing actually taken
            return
        self.db.insert_crypto_event({
            "owner_user_id": owner_user_id,
            "owner_discord_id": actor_id,
            "player_id": str(player_id),
            "amount": amount,
            "source": "STEAL",
            "captured_at": _now_iso(),
        })

    def _capture_own_profile(self, job):
        """GET /v1/user -> the member's own identity + software into own_profile.
        Mirrors _capture but keyed to the member, not a victim."""
        actor_id, _ = job["actor"]
        owner_user_id = self._resolve_user_id(actor_id)
        if not owner_user_id:
            logger.info("no profile for discord %s yet — own profile skipped", actor_id)
            return

        data = job["data"]
        ident = data.get("user") if isinstance(data.get("user"), dict) else {}
        merged = {**ident, **{k: data[k] for k in
                              ("id", "user_id", "username", "ip", "level",
                               "reputation", "fw_level", "firewall_level",
                               "clan", "crew")
                              if k in data}}
        parsed = parse_result(merged)
        if not parsed:
            return

        if not parsed["player_id"]:
            logger.info("own profile has no player_id — skipped")
            return
        # Remember which account is active so the wallet handler can target it.
        self._own_pid[owner_user_id] = parsed["player_id"]

        software, fw_from_sw = self._software_list(data.get("user_software", []))
        body = {
            "owner_user_id": owner_user_id,
            "owner_discord_id": actor_id,
            "player_id": parsed["player_id"],
            "username": parsed["username"],
            "level": parsed["level"],
            "firewall": parsed["firewall"] if parsed["firewall"] is not None else fw_from_sw,
            "reputation": parsed["reputation"],
            "device": _own_device(data),
            "software": software,
            "captured_at": _now_iso(),
        }
        self.db.upsert_own_profile(body)

    def _capture_own_wallet(self, job):
        """GET /v1/user_wallet -> the member's own crypto held into own_profile."""
        actor_id, _ = job["actor"]
        owner_user_id = self._resolve_user_id(actor_id)
        if not owner_user_id:
            return
        wallet = job["data"].get("user_wallet")
        if not isinstance(wallet, dict):
            return
        # own_profile is keyed on (owner_user_id, player_id); the wallet payload
        # carries no id, so route it to the account last seen via /v1/user. If we
        # haven't seen a profile yet this session, defer — the next wallet refresh
        # (after a profile open) will land it.
        player_id = self._own_pid.get(owner_user_id)
        if not player_id:
            logger.info("own wallet before profile — crypto deferred")
            return
        self.db.upsert_own_profile({
            "owner_user_id": owner_user_id,
            "owner_discord_id": actor_id,
            "player_id": player_id,
            "crypto_hot": _num(wallet.get("hot")),
            "crypto_cold": _num(wallet.get("cold")),
            "crypto_updated_at": _now_iso(),
        })


addons = [K3rnCapture()]
