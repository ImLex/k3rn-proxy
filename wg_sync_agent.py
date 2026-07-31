#!/usr/bin/env python3
"""
k3rn wg-sync agent — reconcile the live WireGuard interface from the Supabase
`wg_peers` registry so crew mates self-onboard with no SSH.

The iOS app provisions a peer (its public key + an allocated 10.8.0.x) into
`wg_peers` via the provision-peer Edge Function. This agent polls that table
(service_role, bypasses RLS) and makes `wg0` match it:

  * a new / rotated active peer  -> `wg set wg0 peer <pubkey> allowed-ips <ip>/32`
  * a revoked or deleted peer    -> `wg set wg0 peer <pubkey> remove`

State lives only in the DB. We deliberately do NOT write wg0.conf: on reboot the
agent simply re-adds every active peer from the registry, so there's nothing to
clobber in the hand-written server config. Runtime-only `wg set` is enough.

Runs as root (needs `wg set`). See k3rn-wg-sync.service.

    SUPABASE_URL=... SUPABASE_SERVICE_KEY=... WG_IFACE=wg0 \
    POLL_SECONDS=15 python3 wg_sync_agent.py
"""

import ipaddress
import json
import logging
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
)
logger = logging.getLogger("wg_sync")

IFACE = os.environ.get("WG_IFACE", "wg0")
POLL = int(os.environ.get("POLL_SECONDS", "15"))
SUBNET = ipaddress.ip_network(os.environ.get("WG_SUBNET", "10.8.0.0/24"))


def _norm_ip(raw: str) -> str | None:
    """'10.8.0.5' or '10.8.0.5/32' -> '10.8.0.5', validated inside the subnet."""
    try:
        host = ipaddress.ip_address(str(raw).split("/", 1)[0].strip())
    except ValueError:
        return None
    return str(host) if host in SUBNET else None


class Supabase:
    def __init__(self, url: str, key: str):
        self.base = url.rstrip("/") + "/rest/v1/"
        self.key = key

    def active_peers(self) -> dict[str, str]:
        """{public_key: '10.8.0.x'} for every non-revoked registry row."""
        url = self.base + "wg_peers?select=public_key,wg_ip&revoked_at=is.null"
        req = urllib.request.Request(url)
        req.add_header("apikey", self.key)
        req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("Accept", "application/json")
        with urllib.request.urlopen(req, timeout=10) as resp:
            rows = json.loads(resp.read().decode() or "[]")
        out: dict[str, str] = {}
        for r in rows:
            pk = (r.get("public_key") or "").strip()
            ip = _norm_ip(r.get("wg_ip") or "")
            if pk and ip:
                out[pk] = ip
        return out


def wg_current() -> dict[str, str]:
    """Live peers on the interface: {public_key: allowed-ips-first}."""
    out = subprocess.run(
        ["wg", "show", IFACE, "dump"],
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    peers: dict[str, str] = {}
    for line in out[1:]:  # line 0 is the interface itself, not a peer
        f = line.split("\t")
        if len(f) >= 4 and f[0]:
            allowed = f[3].split(",", 1)[0].strip()  # first allowed-ip
            peers[f[0]] = _norm_ip(allowed) or allowed
    return peers


def wg_set_peer(pubkey: str, ip: str) -> None:
    subprocess.run(
        ["wg", "set", IFACE, "peer", pubkey, "allowed-ips", f"{ip}/32"],
        check=True,
    )
    logger.info("peer +%s -> %s", pubkey[:12], ip)


def wg_remove_peer(pubkey: str) -> None:
    subprocess.run(
        ["wg", "set", IFACE, "peer", pubkey, "remove"], check=True
    )
    logger.info("peer -%s removed", pubkey[:12])


def reconcile(db: Supabase) -> None:
    desired = db.active_peers()
    current = wg_current()

    for pk, ip in desired.items():
        if current.get(pk) != ip:
            wg_set_peer(pk, ip)

    # Remove managed peers no longer in the registry (only touch addresses in our
    # subnet so an unrelated manual peer, if any, is left alone).
    for pk, ip in current.items():
        if pk not in desired and ip and _norm_ip(ip):
            wg_remove_peer(pk)


def main() -> int:
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not (url and key):
        logger.error("SUPABASE_URL / SUPABASE_SERVICE_KEY not set")
        return 1
    db = Supabase(url, key)
    logger.info("wg-sync started (iface=%s, poll=%ss)", IFACE, POLL)
    while True:
        try:
            reconcile(db)
        except subprocess.CalledProcessError as exc:
            logger.error("wg command failed: %s", exc)
        except urllib.error.URLError as exc:
            logger.warning("supabase unreachable: %s", exc)
        except Exception as exc:  # noqa: BLE001 - never let the loop die
            logger.error("reconcile error: %s", exc)
        time.sleep(POLL)


if __name__ == "__main__":
    sys.exit(main())
