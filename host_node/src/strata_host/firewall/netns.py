"""Network-namespace harness for the Phase F integration tests.

These functions only ever run on Linux as root. The test conftest
auto-skips integration tests when those preconditions aren't met, so we
don't need any "fake" fallback here — if we got this far the kernel
side-effects are wanted.

Everything shells out to `ip` / `nft` for parity with the production
shape of the host node (see Phase B's `nft_set.py`).
"""

from __future__ import annotations

import shutil
import subprocess
import threading
from contextlib import contextmanager
from typing import Iterator

# Single global lock — `nft -f -` against `table inet strata` is a global
# kernel resource, so we serialize tests that touch it.
_NFT_LOCK = threading.Lock()

# The harness "AP" subnet. Matches the integration tests' expectations.
GUEST_NS_NAME = "strata_guest"
GUEST_VETH_HOST = "vstrata0"
GUEST_VETH_NS = "vstrata1"
GUEST_NS_IP = "192.168.50.10/24"
GUEST_HOST_IP = "192.168.50.1/24"
GUEST_DEFAULT_GW = "192.168.50.1"
HOST_LAN_TARGET_IP = "192.168.50.20"


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=True)


def _run_no_check(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def in_ns(ns: str, cmd: list[str]) -> subprocess.CompletedProcess:
    """Run a command inside a netns; returns the subprocess result.

    Does NOT raise on non-zero — tests want to assert on rc themselves.
    """
    return _run_no_check(["ip", "netns", "exec", ns, *cmd])


@contextmanager
def guest_namespace(name: str = GUEST_NS_NAME) -> Iterator[str]:
    """Create a netns wired to the root namespace via a veth pair.

    Inside the namespace:
      - 192.168.50.10/24 on the inner veth
      - default route via 192.168.50.1
      - lo is up
    Outside:
      - 192.168.50.1/24 on the host veth
      - IPv4 forwarding enabled (best effort — not undone on exit, since
        operators usually want it on for the host node anyway)

    Yields the namespace name.
    """
    # Clean any leftover from a previous failed run.
    _run_no_check(["ip", "netns", "del", name])
    _run_no_check(["ip", "link", "del", GUEST_VETH_HOST])

    _run(["ip", "netns", "add", name])
    _run(["ip", "link", "add", GUEST_VETH_HOST, "type", "veth", "peer", "name", GUEST_VETH_NS])
    _run(["ip", "link", "set", GUEST_VETH_NS, "netns", name])

    _run(["ip", "addr", "add", GUEST_HOST_IP, "dev", GUEST_VETH_HOST])
    _run(["ip", "link", "set", GUEST_VETH_HOST, "up"])

    _run(["ip", "netns", "exec", name, "ip", "link", "set", "lo", "up"])
    _run(["ip", "netns", "exec", name, "ip", "addr", "add", GUEST_NS_IP, "dev", GUEST_VETH_NS])
    _run(["ip", "netns", "exec", name, "ip", "link", "set", GUEST_VETH_NS, "up"])
    _run(["ip", "netns", "exec", name, "ip", "route", "add", "default", "via", GUEST_DEFAULT_GW])

    # Best-effort: enable IPv4 forwarding so traffic can leave via the
    # nft forward chain. If the system already has it on, this is a no-op.
    _run_no_check(["sysctl", "-q", "-w", "net.ipv4.ip_forward=1"])

    try:
        yield name
    finally:
        _run_no_check(["ip", "netns", "del", name])
        _run_no_check(["ip", "link", "del", GUEST_VETH_HOST])


@contextmanager
def host_lan_target(ip: str = HOST_LAN_TARGET_IP) -> Iterator[str]:
    """Add a dummy /32 to the loopback so guests can try (and fail) to
    reach a host-LAN address. We use lo because it's always up and we
    don't need to touch real interfaces.
    """
    cidr = f"{ip}/32"
    _run_no_check(["ip", "addr", "del", cidr, "dev", "lo"])
    _run(["ip", "addr", "add", cidr, "dev", "lo"])
    try:
        yield ip
    finally:
        _run_no_check(["ip", "addr", "del", cidr, "dev", "lo"])


@contextmanager
def applied_rules(rendered: str) -> Iterator[None]:
    """Apply a rendered ruleset, yield, then drop the table on exit.

    Serialized via _NFT_LOCK so two tests can't fight over the same
    kernel table.
    """
    if shutil.which("nft") is None:
        raise RuntimeError("nft binary is required for integration tests")

    with _NFT_LOCK:
        proc = subprocess.run(
            ["nft", "-f", "-"], input=rendered, text=True, capture_output=True
        )
        if proc.returncode != 0:
            raise RuntimeError(f"nft load failed: {proc.stderr.strip()}")
        try:
            yield
        finally:
            _run_no_check(["nft", "delete", "table", "inet", "strata"])


def add_authed_mac(mac: str) -> None:
    """Helper: add a MAC to the strata_authed set."""
    _run(
        [
            "nft",
            "add",
            "element",
            "inet",
            "strata",
            "strata_authed",
            f"{{ {mac} }}",
        ]
    )


def remove_authed_mac(mac: str) -> None:
    _run_no_check(
        [
            "nft",
            "delete",
            "element",
            "inet",
            "strata",
            "strata_authed",
            f"{{ {mac} }}",
        ]
    )
