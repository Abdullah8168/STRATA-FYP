#!/usr/bin/env python3
"""Start a metered test session for a device on the STRATA AP (no app needed).

For manual testing on the Pi with CHAIN_ENABLED=false: signs the session-start
message with a throwaway guest wallet and admits the device's MAC, exactly as
the Flutter app would. Needs ALLOW_CLIENT_MAC=true in host_node/.env because
the request comes from the Pi itself, not from the phone.

Usage (on the Pi, host node already running):
    .venv/bin/python scripts/pi_start_test_session.py --mac aa:bb:cc:dd:ee:ff
    .venv/bin/python scripts/pi_start_test_session.py --stop <session_id>
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path
from uuid import uuid4

from eth_account import Account
from eth_account.messages import encode_defunct

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from strata_host.session_crypto import build_session_start_message  # noqa: E402


def _call(base: str, method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        base + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        sys.exit(f"{method} {path} failed: {exc.code} {exc.read().decode()}")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--mac", help="device MAC, from: ip neigh show dev wlan0")
    p.add_argument("--quota-mb", type=int, default=1024)
    p.add_argument("--stop", metavar="SESSION_ID")
    p.add_argument("--url", default="http://127.0.0.1:8080")
    a = p.parse_args()

    if a.stop:
        r = _call(a.url, "POST", "/session/stop", {"session_id": a.stop, "reason": "admin_stop"})
        print(f"stopped {r['session_id']}  bytes_used={r['bytes_used']}")
        return
    if not a.mac:
        p.error("--mac is required")

    info = _call(a.url, "GET", "/host/info")
    host = info["host_wallet_address"] or "0x" + "2" * 40
    guest = Account.create()
    quota = a.quota_mb * 1024 * 1024
    nonce = str(uuid4())
    mac = a.mac.lower()
    msg = build_session_start_message(
        guest_wallet=guest.address, host_wallet=host, mac_address=mac,
        quota_bytes=quota, nonce=nonce,
    )
    sig = guest.sign_message(encode_defunct(text=msg)).signature.hex()
    r = _call(a.url, "POST", "/session/start", {
        "guest_wallet_address": guest.address,
        "host_wallet_address": host,
        "mac_address": mac,
        "quota_bytes": quota,
        "price_per_gb_wei": info.get("price_per_gb_wei") or "0",
        "nonce": nonce,
        "guest_signature": sig if sig.startswith("0x") else "0x" + sig,
    })
    print(f"session {r['session_id']}  status={r['status']}  mac={r['mac_address']}  quota={a.quota_mb} MB")
    print(f"watch:  curl -s '{a.url}/session/status?session_id={r['session_id']}'")
    print(f"stop:   .venv/bin/python scripts/pi_start_test_session.py --stop {r['session_id']}")


if __name__ == "__main__":
    main()
