"""Conntrack-based metering + kernel prerequisites (Iteration 3 fixes)."""

from __future__ import annotations

import asyncio
import subprocess
import sys
from uuid import uuid4

from strata_host.config import Settings
from strata_host.enforcer import EnforcerService
from strata_host.meter import MeterService
from strata_host.models import StartSessionRequest
from strata_host.nft_bootstrap import KERNEL_PREREQS, enable_kernel_prereqs
from strata_host.store import SessionStore
from strata_host.traffic import TrafficReader, parse_conntrack_line

GUEST = "192.168.50.10"
OTHER = "192.168.50.11"


def _tcp(src: str, sport: int, up: int, down: int, state: str = "ESTABLISHED", timeout: int = 431999) -> str:
    return (
        f"ipv4     2 tcp      6 {timeout} {state} src={src} dst=93.184.216.34 "
        f"sport={sport} dport=443 packets=3 bytes={up} src=93.184.216.34 "
        f"dst=10.66.66.2 sport=443 dport={sport} packets=4 bytes={down} [ASSURED] mark=0 zone=0 use=2"
    )


def _table(*lines: str) -> str:
    return "\n".join(lines) + "\n"


# --- parsing ------------------------------------------------------------------


def test_parse_tcp_row():
    key, src, orig, reply = parse_conntrack_line(_tcp(GUEST, 5000, 1200, 9000))
    assert src == GUEST
    assert (orig, reply) == (1200, 9000)
    # Key is the original tuple only: stable across timeout / state changes.
    assert key == parse_conntrack_line(_tcp(GUEST, 5000, 1, 1, state="TIME_WAIT", timeout=5))[0]
    assert "10.66.66.2" not in key


def test_parse_udp_and_icmp_rows():
    udp = (
        "ipv4     2 udp      17 25 src=192.168.50.10 dst=1.1.1.1 sport=5353 dport=53 "
        "packets=1 bytes=70 src=1.1.1.1 dst=10.66.66.2 sport=53 dport=5353 packets=1 bytes=120 mark=0 use=1"
    )
    icmp = (
        "ipv4     2 icmp     1 29 src=192.168.50.10 dst=8.8.8.8 type=8 code=0 id=7 "
        "packets=1 bytes=84 src=8.8.8.8 dst=10.66.66.2 type=0 code=0 id=7 packets=1 bytes=84 mark=0 use=1"
    )
    assert parse_conntrack_line(udp)[1:] == (GUEST, 70, 120)
    key, src, _, _ = parse_conntrack_line(icmp)
    assert src == GUEST and "id=7" in key


def test_parse_skips_ipv6_and_rows_without_counters():
    no_acct = (
        "ipv4     2 tcp      6 300 ESTABLISHED src=192.168.50.10 dst=1.2.3.4 sport=1 dport=443 "
        "src=1.2.3.4 dst=10.66.66.2 sport=443 dport=1 [ASSURED] mark=0 use=1"
    )
    assert parse_conntrack_line(no_acct) is None
    assert parse_conntrack_line("ipv6     10 tcp 6 300 ESTABLISHED src=fd00::1 bytes=1") is None


# --- accumulation ---------------------------------------------------------------


def _reader() -> TrafficReader:
    return TrafficReader("wlan0")


def test_growth_is_counted_once():
    r = _reader()
    r.refresh(_table(_tcp(GUEST, 5000, 100, 1000)))
    r.refresh(_table(_tcp(GUEST, 5000, 150, 4000)))
    r.refresh(_table(_tcp(GUEST, 5000, 150, 4000)))  # no growth
    assert r._totals[GUEST] == [150, 4000]


def test_closed_connection_bytes_are_kept():
    """Regression: the old reader summed live rows, so totals dropped (and
    later growth was swallowed) whenever a connection closed."""
    r = _reader()
    r.refresh(_table(_tcp(GUEST, 5000, 500, 50_000), _tcp(GUEST, 5001, 100, 1_000)))
    r.refresh(_table(_tcp(GUEST, 5001, 100, 1_000)))  # 5000 closed
    assert r._totals[GUEST] == [600, 51_000]
    r.refresh(_table(_tcp(GUEST, 5001, 200, 3_000), _tcp(GUEST, 5002, 10, 10)))
    assert r._totals[GUEST] == [710, 53_010]


def test_reused_tuple_counts_as_new_connection():
    r = _reader()
    r.refresh(_table(_tcp(GUEST, 5000, 800, 8_000)))
    r.refresh(_table(_tcp(GUEST, 5000, 50, 70)))  # counters went down: new conn
    assert r._totals[GUEST] == [850, 8_070]


def test_totals_are_per_source_ip():
    r = _reader()
    r.refresh(_table(_tcp(GUEST, 5000, 10, 20), _tcp(OTHER, 6000, 30, 40)))
    assert r._totals[GUEST] == [10, 20]
    assert r._totals[OTHER] == [30, 40]


def test_absolute_pair_maps_mac_and_orders_in_out(monkeypatch):
    r = _reader()
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.setattr(r, "_ips_for_mac", lambda mac: [GUEST] if mac == "aa:bb:cc:dd:ee:ff" else [])
    feed = iter([_table(_tcp(GUEST, 5000, 100, 900)), _table()])
    monkeypatch.setattr(r, "_read_conntrack", lambda: next(feed))
    assert r.absolute_pair("AA:BB:CC:DD:EE:FF") == (900, 100)  # (download, upload)
    r._last_refresh = float("-inf")
    assert r.absolute_pair("aa:bb:cc:dd:ee:ff") == (900, 100), "must not drop after close"
    assert r.absolute_pair("11:11:11:11:11:11") == (0, 0)


def test_falls_back_to_conntrack_cli_when_proc_missing(monkeypatch, tmp_path):
    from strata_host import traffic

    monkeypatch.setattr(traffic, "CONNTRACK_PROC", tmp_path / "missing")
    calls = []

    def fake_run(cmd, **kw):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, _table(_tcp(GUEST, 1, 5, 6)), "")

    monkeypatch.setattr(traffic.subprocess, "run", fake_run)
    r = _reader()
    r.refresh(force=True)
    assert calls == [["conntrack", "-L", "-f", "ipv4", "-o", "extended"]]
    assert r._totals[GUEST] == [5, 6]


# --- meter never invents bytes on a real Pi -------------------------------------


class _FixedReader:
    def __init__(self) -> None:
        self.value = (0, 0)

    def absolute_pair(self, mac: str) -> tuple[int, int]:
        return self.value


async def test_demo_mode_does_not_add_random_bytes_with_real_reader(monkeypatch):
    import strata_host.meter as meter_mod

    monkeypatch.setattr(meter_mod.sys, "platform", "linux")
    settings = Settings(DEMO_MODE=True, METER_TICK_SECONDS=0.01)
    store = SessionStore()
    rec = await store.create_session(
        StartSessionRequest(
            guest_wallet_address="0x" + "1" * 40,
            host_wallet_address="0x" + "2" * 40,
            mac_address="aa:bb:cc:dd:ee:ff",
            quota_bytes=10**9,
            price_per_gb_wei="1",
            nonce=uuid4(),
            guest_signature="0x00",
        ),
        ttl_seconds=3600,
    )
    reader = _FixedReader()
    reader.value = (1_000, 100)  # baseline
    enforcer = EnforcerService()
    meter = MeterService(store, enforcer, settings, traffic_reader=reader)
    await meter.start_loop()
    try:
        await asyncio.sleep(0.1)
        idle = (await store.get_by_session_id(rec.session_id)).bytes_used
        reader.value = (6_000, 600)
        await asyncio.sleep(0.1)
        after = (await store.get_by_session_id(rec.session_id)).bytes_used
    finally:
        await meter.stop_loop()
    assert idle == 0, "idle session on a real Pi must not get synthetic bytes"
    assert after == 5_500


# --- kernel prerequisites ---------------------------------------------------------


class _Log:
    def __init__(self) -> None:
        self.events: list[tuple[str, str]] = []

    def info(self, event, **kw):
        self.events.append(("info", event))

    def warning(self, event, **kw):
        self.events.append(("warning", event))

    def error(self, event, **kw):
        self.events.append(("error", event))


def test_kernel_prereqs_skipped_in_fake_mode(monkeypatch):
    import strata_host.nft_bootstrap as nb

    monkeypatch.setattr(nb.subprocess, "run", lambda *a, **k: (_ for _ in ()).throw(AssertionError("ran")))
    log = _Log()
    assert enable_kernel_prereqs(log, force_fake=True) == {k: False for k in KERNEL_PREREQS}
    assert ("warning", "kernel.prereqs_skipped_fake_mode") in log.events


def _fake_proc_sys(monkeypatch, tmp_path, *, honour_writes: bool):
    import strata_host.nft_bootstrap as nb

    calls: list[list[str]] = []

    def path_for(key: str):
        return tmp_path / key

    for key in KERNEL_PREREQS:
        path_for(key).write_text("0\n")

    def fake_run(cmd, **kw):
        calls.append(cmd)
        if cmd[0] == "sysctl" and honour_writes:
            key, value = cmd[-1].split("=")
            path_for(key).write_text(value + "\n")
        return subprocess.CompletedProcess(cmd, 0, "", "")

    monkeypatch.setattr(nb, "_sysctl_path", path_for)
    monkeypatch.setattr(nb.subprocess, "run", fake_run)
    return calls


def test_kernel_prereqs_enable_forwarding_and_conntrack_accounting(monkeypatch, tmp_path):
    calls = _fake_proc_sys(monkeypatch, tmp_path, honour_writes=True)
    log = _Log()
    result = enable_kernel_prereqs(log, force_fake=False)
    assert result == {"net.ipv4.ip_forward": True, "net.netfilter.nf_conntrack_acct": True}
    assert ["modprobe", "nf_conntrack"] in calls
    assert ["sysctl", "-q", "-w", "net.ipv4.ip_forward=1"] in calls
    assert ["sysctl", "-q", "-w", "net.netfilter.nf_conntrack_acct=1"] in calls
    assert not any(level == "error" for level, _ in log.events)


def test_kernel_prereqs_report_failure_when_setting_does_not_stick(monkeypatch, tmp_path):
    _fake_proc_sys(monkeypatch, tmp_path, honour_writes=False)
    log = _Log()
    result = enable_kernel_prereqs(log, force_fake=False)
    assert result == {k: False for k in KERNEL_PREREQS}
    assert ("error", "kernel.prereq_failed") in log.events
