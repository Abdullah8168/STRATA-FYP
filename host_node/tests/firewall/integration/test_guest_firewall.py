"""Integration: the guest firewall (Iteration 2) on a real kernel.

Replaces the earlier test_isolation / test_unsolicited_drop / test_rate_limit,
which never exercised the forward chain (they targeted the Pi's own
addresses, never gave the guest the admitted MAC, and hung on `nc -l -w`).

    guest ns ──vstrata── Pi (root, ruleset loaded) ──vwan── internet ns (198.51.100.7)
                                                  └──vlan── home-LAN device (192.168.1.2)

Every "must be blocked" assertion is paired with a control showing the same
path works when it should, so a broken topology can't pass as "blocked".

Run on Linux as root:
    sudo .venv/bin/python -m pytest -v -m integration tests/firewall/integration/test_guest_firewall.py
"""

from __future__ import annotations

import json
import subprocess
import time
from collections.abc import Iterator
from contextlib import ExitStack, contextmanager

import pytest

from strata_host.firewall import NftContext, render_ruleset
from strata_host.firewall.netns import (
    GUEST_NS_IP,
    GUEST_VETH_NS,
    add_authed_mac,
    applied_rules,
    guest_namespace,
    in_ns,
    remove_authed_mac,
)

from ._topology import TARGET, fetch, http_server, remote_namespace, sh

INET_NS, INET_HOST, INET_PEER = "strata_inetx", "vwan0", "vwan1"
LAN_NS, LAN_HOST, LAN_PEER = "strata_lanx", "vlan0", "vlan1"
LAN_DEVICE = "192.168.1.2"
GUEST_IP = GUEST_NS_IP.split("/")[0]


@contextmanager
def guest_network(mac: str, *, admitted: bool = True,
                  internet_files: dict[str, bytes] | None = None) -> Iterator[str]:
    ctx = NftContext(guest_iface="vstrata0", wan_iface=INET_HOST, wg_enabled=False)
    with ExitStack() as stack:
        stack.enter_context(applied_rules(render_ruleset(ctx)))
        ns = stack.enter_context(guest_namespace())
        stack.enter_context(remote_namespace(INET_NS, INET_HOST, INET_PEER, "10.77.0",
                                             "INTERNET", files=internet_files))
        stack.enter_context(
            remote_namespace(LAN_NS, LAN_HOST, LAN_PEER, "192.168.1", "LAN", serve_ip=None)
        )
        sh("ip", "route", "replace", f"{TARGET}/32", "via", "10.77.0.2")
        stack.callback(sh, "ip", "route", "del", f"{TARGET}/32", check=False)
        in_ns(ns, ["ip", "link", "set", GUEST_VETH_NS, "address", mac])
        if admitted:
            add_authed_mac(mac)
        yield ns


@pytest.mark.integration
def test_unadmitted_guest_has_no_internet_until_admitted(authed_mac):
    with guest_network(authed_mac, admitted=False) as ns:
        before = fetch(ns)
        add_authed_mac(authed_mac)
        after = fetch(ns)
    assert before.startswith("FAIL"), f"guest reached the internet before paying: {before!r}"
    assert after == "INTERNET", f"admitted guest still blocked: {after!r}"


@pytest.mark.integration
def test_admitted_guest_cannot_reach_host_lan(authed_mac):
    with guest_network(authed_mac) as ns:
        internet = fetch(ns)
        lan_from_guest = fetch(ns, LAN_DEVICE)
        lan_from_pi = fetch(None, LAN_DEVICE)
    assert internet == "INTERNET", "control: admitted guest must reach the internet"
    assert lan_from_pi == "LAN", "control: the LAN device must be reachable from the Pi"
    assert lan_from_guest.startswith("FAIL"), (
        f"guest reached a device on the host's home LAN: {lan_from_guest!r}"
    )


@pytest.mark.integration
def test_removing_mac_revokes_access(authed_mac):
    with guest_network(authed_mac) as ns:
        before = fetch(ns)
        remove_authed_mac(authed_mac)
        after = fetch(ns)
    assert before == "INTERNET"
    assert after.startswith("FAIL"), f"guest kept internet after being removed: {after!r}"


@pytest.mark.integration
def test_internet_cannot_open_connections_to_guest(authed_mac):
    with guest_network(authed_mac) as ns, http_server(ns, GUEST_IP, "GUEST"):
        outbound = fetch(ns)
        inbound = fetch(INET_NS, GUEST_IP)
    assert outbound == "INTERNET", "control: guest-initiated traffic must work"
    assert inbound.startswith("FAIL"), f"internet host connected into the guest: {inbound!r}"


_STREAM_PORT = 9100
_STREAM_SERVER = f"""
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(({TARGET!r}, {_STREAM_PORT})); s.listen()
c, _ = s.accept(); buf = bytes(65536)
while True:
    c.sendall(buf)
"""
# Prints bytes received in each 1-second bucket for 6 seconds.
_STREAM_CLIENT = f"""
import socket, time
c = socket.create_connection(({TARGET!r}, {_STREAM_PORT}), timeout=3); c.settimeout(0.2)
end = time.time() + 6; tick = time.time() + 1; n = 0; out = []
while time.time() < end:
    try:
        n += len(c.recv(65536))
    except (socket.timeout, OSError):
        pass
    if time.time() >= tick:
        out.append(n); n = 0; tick += 1
print(out)
"""


@pytest.mark.integration
def test_revoking_guest_stops_a_running_download(authed_mac):
    """Quota cut-off / session stop must end transfers already in progress,
    not just block new connections."""
    import ast
    import sys

    with guest_network(authed_mac) as ns:
        server = subprocess.Popen(
            ["ip", "netns", "exec", INET_NS, sys.executable, "-c", _STREAM_SERVER],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            time.sleep(0.5)
            client = subprocess.Popen(
                ["ip", "netns", "exec", ns, sys.executable, "-c", _STREAM_CLIENT],
                stdout=subprocess.PIPE, text=True,
            )
            time.sleep(2.5)
            remove_authed_mac(authed_mac)
            out, _ = client.communicate(timeout=20)
        finally:
            server.terminate()
            server.wait(timeout=5)
    per_second = ast.literal_eval(out.strip())
    assert per_second[0] > 1_000_000, f"control: download never ran {per_second}"
    assert max(per_second[-2:]) < 100_000, (
        f"download kept running after the guest was removed: {per_second} bytes/s"
    )


def _iperf(ns: str, *, reverse: bool) -> float:
    """Mbit/s between the guest and the internet host (upload unless reverse)."""
    server = subprocess.Popen(
        ["ip", "netns", "exec", INET_NS, "iperf3", "-s", "-1", "-B", TARGET],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(0.5)
        # -O 2: ignore the first 2 s, where nft's initial burst allowance
        # (one second's worth) would inflate a short average by ~10 Mbit/s.
        args = ["iperf3", "-c", TARGET, "-t", "6", "-O", "2", "-J"] + (["-R"] if reverse else [])
        proc = in_ns(ns, args)
    finally:
        server.terminate()
        server.wait(timeout=5)
    data = json.loads(proc.stdout)
    assert "error" not in data, data.get("error")
    return data["end"]["sum_received"]["bits_per_second"] / 1e6


@pytest.mark.integration
def test_guest_upload_capped_at_50_mbit(authed_mac):
    with guest_network(authed_mac) as ns:
        mbps = _iperf(ns, reverse=False)
    # Uncapped, veth runs at ~25 Gbit/s here. 6250 kbytes/s = 51.2 Mbit/s.
    assert 20 < mbps <= 55, f"guest upload {mbps:.1f} Mbit/s, expected the 50 Mbit/s cap"


@pytest.mark.integration
def test_guest_download_capped_at_50_mbit(authed_mac):
    with guest_network(authed_mac) as ns:
        mbps = _iperf(ns, reverse=True)
    assert 20 < mbps <= 55, f"guest download {mbps:.1f} Mbit/s, expected the 50 Mbit/s cap"
