"""
mitmproxy addon: capture the HackEx targets a member OPENS -> their private
K3RN capture inbox (Supabase `captures`).

This is personal-tracking, not a shared-DB writer. As an api2.hackex.net response
passes through:

  * /v1/user_victim_access (entering/opening a target) is upserted into `captures`,
    owned by the scanning member (resolved from their fixed WireGuard IP ->
    Discord id -> profiles.user_id). One row per (owner, player), refreshed on
    re-open. The target's `user_software` list is captured alongside identity.

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
      identity: id/user_id, level, reputation, fw_level, username, ip, clan, ...
"""

import datetime
import ipaddress
import json
import logging
import os
import queue
import threading
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

logger = logging.getLogger("k3rn_capture")

GAME_HOST = "api2.hackex.net"
# A member opens a target two ways: a fresh target hits /v1/user_victim_access,
# an already-bypassed one hits /v1/user_victim. Both carry identity + user_software.
VICTIM_PATHS = {"/v1/user_victim", "/v1/user_victim_access"}

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

    # -- mitmproxy lifecycle ------------------------------------------------ #
    def running(self):
        if not self.enabled:
            logger.error(
                "SUPABASE_URL / SUPABASE_SERVICE_KEY not set — K3RN capture is OFF"
            )
            return
        if self._worker is None:
            self._worker = threading.Thread(
                target=self._drain, name="k3rn-capture", daemon=True
            )
            self._worker.start()
            logger.info(
                "K3RN capture inbox writer started (%d WG peers mapped)", len(self.wg_map)
            )

    def response(self, flow):
        if not self.enabled or flow.request.pretty_host != GAME_HOST:
            return
        if flow.request.path.split("?", 1)[0] not in VICTIM_PATHS:
            return  # only opened targets are tracked
        actor = self.wg_map.get(self._client_ip(flow))
        if not actor:  # unknown WG peer -> not one of our members
            return
        data = self._json_body(flow)
        if data is None:
            return
        self._enqueue({
            "victim_user_id": flow.request.query.get("victim_user_id"),
            "data": data,
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

    @staticmethod
    def _json_body(flow):
        try:
            data = json.loads(flow.response.get_text())
        except Exception:  # noqa: BLE001 - non-JSON / empty body
            return None
        return data if isinstance(data, dict) else None

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
            out.append({
                "name": name,
                "category": SW_CATEGORY.get(name, "UTILITY"),
                "level": level if level is not None else 1,
            })
        return out, firewall

    # -- writer thread ------------------------------------------------------ #
    def _drain(self):
        while True:
            job = self._q.get()
            try:
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
                               "clan", "crew")
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
            "current_ip": parsed["current_ip"],
            "level": parsed["level"],
            "firewall": parsed["firewall"] if parsed["firewall"] is not None else fw_from_sw,
            "reputation": parsed["reputation"],
            "crew": _clean(merged.get("clan") or merged.get("crew")),
            "software": software,
            "captured_at": _now_iso(),
        }
        self.db.upsert_capture(body)


addons = [K3rnCapture()]
