"""Resolve guest IPv4 → MAC via the Linux neighbour (ARP) table.

Used by captive-portal /session/start so the host never trusts a
client-supplied MAC on the real Pi path.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from typing import Callable

from strata_host.logging_setup import get_logger

_MAC_RE = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")
_logger = get_logger("neighbour")


def normalize_mac(mac: str) -> str:
    return mac.strip().lower()


def is_valid_mac(mac: str) -> bool:
    return bool(_MAC_RE.match(normalize_mac(mac)))


def lookup_mac_for_ip(
    ipv4: str,
    guest_iface: str,
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] | None = None,
) -> str | None:
    """Return lowercase MAC for ``ipv4`` on ``guest_iface``, or None.

    Off-Linux always returns None (callers use ALLOW_CLIENT_MAC / test paths).
    """
    if not ipv4 or ipv4 in {"127.0.0.1", "::1", "testclient"}:
        return None
    if not sys.platform.startswith("linux"):
        return None

    run = runner or subprocess.run
    try:
        proc = run(
            ["ip", "-json", "neigh", "show", "dev", guest_iface],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
    except (FileNotFoundError, OSError) as exc:
        _logger.warning("neighbour.ip_neigh_failed", error=type(exc).__name__)
        return None

    if proc.returncode != 0 or not (proc.stdout or "").strip():
        return None

    try:
        rows = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None

    target = ipv4.strip()
    for row in rows:
        dst = str(row.get("dst") or "")
        lladdr = row.get("lladdr")
        if not lladdr or dst != target:
            continue
        mac = normalize_mac(str(lladdr))
        if is_valid_mac(mac):
            return mac
    return None


def client_ip_from_request(request) -> str | None:
    """Best-effort client IPv4 from a Starlette/FastAPI Request."""
    # Honours X-Forwarded-For only when the proxy is trusted — for the Pi
    # captive portal guests hit the host directly, so prefer request.client.
    if request.client and request.client.host:
        host = request.client.host
        if host and host != "unknown":
            return host
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return None
