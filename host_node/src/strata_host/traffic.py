"""Per-guest traffic totals via neighbour table + conntrack byte counters.

Linux-only. Used by :class:`strata_host.meter.MeterService` when a real reader
is wired in; off-Linux the reader reports zero.

Conntrack only shows *live* connections, so summing its ``bytes=`` fields
directly would lose every byte of a connection the moment it closes (and a
browsing guest opens and closes hundreds). Instead each refresh diffs every
flow against its previous reading and adds the growth to a per-source-IP
running total that never goes down. At most one refresh interval of traffic
on a connection that closes between two reads is missed.

Byte counters require ``net.netfilter.nf_conntrack_acct=1``;
:func:`strata_host.nft_bootstrap.enable_kernel_prereqs` sets it at startup.
"""

from __future__ import annotations

import asyncio
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from strata_host.logging_setup import get_logger

CONNTRACK_PROC = Path("/proc/net/nf_conntrack")
# Re-reading conntrack for every session on every meter tick is wasteful;
# totals are cumulative, so a short cache doesn't lose anything.
MIN_REFRESH_SECONDS = 0.25

_KV = re.compile(r"(\w+)=(\S+)")


def _norm_mac(mac: str) -> str:
    return mac.strip().lower()


def parse_conntrack_line(line: str) -> tuple[str, str, int, int] | None:
    """Parse one ``/proc/net/nf_conntrack`` (or ``conntrack -L -o extended``) row.

    Returns ``(flow_key, original_src_ip, orig_bytes, reply_bytes)`` or None
    for non-IPv4 rows and rows without byte counters (accounting off).

    ``flow_key`` is the protocol plus the original-direction tuple, which is
    stable for the life of the connection (unlike timeout / TCP state).
    """
    parts = line.split()
    if len(parts) < 4 or parts[0] != "ipv4":
        return None
    proto = parts[2]
    key_fields: list[str] = []
    src: str | None = None
    byte_counts: list[int] = []
    for k, v in _KV.findall(line):
        if k == "bytes":
            byte_counts.append(int(v))
            continue
        if k in ("packets", "mark", "zone", "use", "secctx"):
            continue
        # The tuple fields repeat for the reply direction once the first
        # counter has been seen; only the original direction is the key.
        if byte_counts:
            continue
        if k == "src" and src is None:
            src = v
        key_fields.append(f"{k}={v}")
    if src is None or not byte_counts:
        return None
    orig = byte_counts[0]
    reply = byte_counts[1] if len(byte_counts) > 1 else 0
    return (proto + " " + " ".join(key_fields), src, orig, reply)


@dataclass
class TrafficReader:
    """Resolve guest MAC → IPv4 via ``ip -json neigh``, then report monotonic
    per-IP byte totals built from conntrack flow deltas.

    ``bytes_in`` approximates download (reply direction); ``bytes_out`` upload
    (original direction). Needs root to read conntrack on a production Pi.
    """

    guest_iface: str
    _logger: object = field(default_factory=lambda: get_logger("traffic"), init=False)
    _prev_abs: dict[str, tuple[int, int]] = field(default_factory=dict, init=False)
    # flow_key -> (orig_bytes, reply_bytes) at the last refresh
    _flows: dict[str, tuple[int, int]] = field(default_factory=dict, init=False)
    # src ip -> [orig_total, reply_total]; only ever grows
    _totals: dict[str, list[int]] = field(default_factory=dict, init=False)
    _last_refresh: float = field(default=float("-inf"), init=False)
    _warned_no_counters: bool = field(default=False, init=False)

    async def read_bytes(self, mac_address: str) -> tuple[int, int]:
        """Return ``(bytes_in, bytes_out)`` for ``mac`` since the last call."""
        if not sys.platform.startswith("linux"):
            return (0, 0)
        mac = _norm_mac(mac_address)
        cur = await asyncio.to_thread(self._absolute_pair_sync, mac)
        prev = self._prev_abs.get(mac)
        self._prev_abs[mac] = cur
        if prev is None:
            return (0, 0)
        return (max(0, cur[0] - prev[0]), max(0, cur[1] - prev[1]))

    def absolute_pair(self, mac_address: str) -> tuple[int, int]:
        """Cumulative ``(bytes_in, bytes_out)`` snapshot (not delta). Never
        decreases for a given IP, so callers can diff against a baseline."""
        if not sys.platform.startswith("linux"):
            return (0, 0)
        return self._absolute_pair_sync(_norm_mac(mac_address))

    def reset_mac(self, mac_address: str) -> None:
        """Drop delta baseline so the next ``read_bytes`` starts clean."""
        self._prev_abs.pop(_norm_mac(mac_address), None)

    def _absolute_pair_sync(self, mac: str) -> tuple[int, int]:
        self.refresh()
        orig_b = reply_b = 0
        for ip in self._ips_for_mac(mac):
            orig, reply = self._totals.get(ip, (0, 0))
            orig_b += orig
            reply_b += reply
        return (reply_b, orig_b)

    # --- conntrack accounting --------------------------------------------------
    def refresh(self, text: str | None = None, *, force: bool = False) -> None:
        """Fold the current conntrack table into the running totals.

        ``text`` lets tests feed a fixture instead of reading the kernel.
        """
        now = time.monotonic()
        if text is None:
            if not force and now - self._last_refresh < MIN_REFRESH_SECONDS:
                return
            text = self._read_conntrack()
            if text is None:
                return
        self._last_refresh = now

        seen: dict[str, tuple[int, int]] = {}
        rows = 0
        for line in text.splitlines():
            if line.startswith("ipv4"):
                rows += 1
            parsed = parse_conntrack_line(line)
            if parsed is None:
                continue
            key, src, orig, reply = parsed
            prev = self._flows.get(key)
            if prev is None or orig < prev[0] or reply < prev[1]:
                # New flow, or the same tuple reused by a new connection.
                d_orig, d_reply = orig, reply
            else:
                d_orig, d_reply = orig - prev[0], reply - prev[1]
            tot = self._totals.setdefault(src, [0, 0])
            tot[0] += d_orig
            tot[1] += d_reply
            seen[key] = (orig, reply)
        # Flows missing from this read have closed; forget them.
        self._flows = seen

        if rows and not seen and not self._warned_no_counters:
            self._warned_no_counters = True
            self._logger.warning(
                "traffic.conntrack_no_byte_counters",
                hint="set net.netfilter.nf_conntrack_acct=1 (the host node does this as root)",
            )

    def _read_conntrack(self) -> str | None:
        try:
            return CONNTRACK_PROC.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            pass
        # Kernels built without CONFIG_NF_CONNTRACK_PROCFS: same row format
        # from the conntrack CLI (apt install conntrack).
        try:
            proc = subprocess.run(
                ["conntrack", "-L", "-f", "ipv4", "-o", "extended"],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )
        except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
            return None
        if proc.returncode != 0:
            return None
        return proc.stdout

    def _ips_for_mac(self, mac: str) -> list[str]:
        try:
            proc = subprocess.run(
                ["ip", "-json", "neigh", "show", "dev", self.guest_iface],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )
        except (FileNotFoundError, OSError):
            return []
        if proc.returncode != 0 or not proc.stdout.strip():
            return []
        try:
            rows = json.loads(proc.stdout)
        except json.JSONDecodeError:
            return []
        ips: list[str] = []
        for row in rows:
            dst = row.get("dst")
            lladdr = row.get("lladdr")
            if not dst or not lladdr:
                continue
            if str(lladdr).lower() != mac:
                continue
            d = str(dst)
            if "." in d and ":" not in d:
                ips.append(d)
        return ips
