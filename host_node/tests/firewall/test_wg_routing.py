"""Fast tests for guest-only WireGuard policy routing.

A tiny in-memory "kernel" stands in for ``ip`` / ``sysctl`` / ``wg`` so we
can assert on resulting state (rules, routes) rather than only on command
strings. The real-kernel version lives in
``tests/firewall/integration/test_wg_guest_routing.py``.
"""

from __future__ import annotations

import subprocess
import time

import pytest

from strata_host.config import Settings
from strata_host.firewall.wg_routing import (
    KILL_SWITCH_METRIC,
    GuestRouting,
    RoutingError,
)


class FakeKernel:
    def __init__(self, *, links: set[str] | None = None) -> None:
        self.links = set(links or {"wlan0", "eth0"})
        self.rules: list[tuple[str, str]] = []  # (selector, priority)
        self.routes: dict[str, set[str]] = {}  # table -> route lines
        self.sysctls: dict[str, str] = {}
        self.handshake: int | None = None
        self.fail_on: str | None = None
        self.calls: list[list[str]] = []

    def _ok(self, cmd, out: str = "") -> subprocess.CompletedProcess:
        return subprocess.CompletedProcess(cmd, 0, out, "")

    def _err(self, cmd, msg: str = "error") -> subprocess.CompletedProcess:
        return subprocess.CompletedProcess(cmd, 2, "", msg)

    def __call__(self, cmd: list[str]) -> subprocess.CompletedProcess:
        self.calls.append(cmd)
        if self.fail_on and self.fail_on in " ".join(cmd):
            return self._err(cmd, "injected failure")
        if cmd[0] == "sysctl":
            key, value = cmd[-1].split("=")
            self.sysctls[key] = value
            return self._ok(cmd)
        if cmd[0] == "wg":
            if cmd[2] not in self.links:
                return self._err(cmd)
            out = f"PEERKEY=\t{self.handshake}\n" if self.handshake else "PEERKEY=\t0\n"
            return self._ok(cmd, out)
        if cmd[:3] == ["ip", "link", "show"]:
            return self._ok(cmd) if cmd[-1] in self.links else self._err(cmd)
        if cmd[:3] == ["ip", "rule", "show"]:
            prio = cmd[-1]
            lines = [f"{p}:\t{spec}" for (spec, p) in self.rules if p == prio]
            return self._ok(cmd, "\n".join(lines))
        if cmd[:3] == ["ip", "rule", "add"]:
            assert cmd[-2] == "priority"
            self.rules.append((" ".join(cmd[3:-2]), cmd[-1]))
            return self._ok(cmd)
        if cmd[:3] == ["ip", "rule", "del"]:
            key = (" ".join(cmd[3:-2]), cmd[-1])
            if key in self.rules:
                self.rules.remove(key)
                return self._ok(cmd)
            return self._err(cmd, "No such file or directory")
        if cmd[:3] == ["ip", "route", "replace"]:
            table = cmd[cmd.index("table") + 1]
            spec = [c for i, c in enumerate(cmd[3:], 3) if c != "table" and cmd[i - 1] != "table"]
            if "dev" in spec and spec[spec.index("dev") + 1] not in self.links:
                return self._err(cmd, "Cannot find device")
            self.routes.setdefault(table, set()).add(" ".join(spec))
            return self._ok(cmd)
        if cmd[:3] == ["ip", "route", "del"]:
            table = cmd[cmd.index("table") + 1]
            spec = " ".join(c for i, c in enumerate(cmd[3:], 3) if c != "table" and cmd[i - 1] != "table")
            if spec in self.routes.get(table, set()):
                self.routes[table].remove(spec)
                return self._ok(cmd)
            return self._err(cmd)
        if cmd[:3] == ["ip", "route", "show"]:
            return self._ok(cmd, "\n".join(sorted(self.routes.get(cmd[-1], set()))))
        if cmd[:3] == ["ip", "route", "flush"]:
            self.routes.pop(cmd[-1], None)
            return self._ok(cmd)
        raise AssertionError(f"unexpected command: {cmd}")

    def drop_link(self, name: str) -> None:
        """Simulate `wg-quick down`: the link and every route via it vanish."""
        self.links.discard(name)
        for table, lines in self.routes.items():
            self.routes[table] = {l for l in lines if f"dev {name}" not in l}


def _settings(**overrides) -> Settings:
    base = dict(
        WG_ENABLED=True,
        WG_PEER_PUBLIC_KEY="peer",
        WG_PEER_ENDPOINT="203.0.113.5:51820",
        GUEST_IFACE="wlan0",
        GUEST_SUBNET="192.168.50.0/24",
        WG_ROUTE_TABLE=51820,
        WG_RULE_PRIORITY=10000,
        WG_FALLBACK_TO_WAN=False,
    )
    base.update(overrides)
    return Settings(**base)


def _routing(kernel: FakeKernel, **overrides) -> GuestRouting:
    return GuestRouting(_settings(**overrides), runner=kernel, force_fake=False)


KILL = f"unreachable default metric {KILL_SWITCH_METRIC}"


def test_apply_steers_only_guest_subnet_into_tunnel_table():
    k = FakeKernel(links={"wlan0", "eth0", "wg0"})
    _routing(k).apply()

    # iif wlan0: only packets forwarded from the AP, not the Pi's own
    # traffic sourced from 192.168.50.1.
    assert k.rules == [("from 192.168.50.0/24 iif wlan0 lookup 51820", "10000")]
    assert k.routes["51820"] == {
        "192.168.50.0/24 dev wlan0",
        "default dev wg0",
        KILL,
    }
    # Main table untouched: the Pi's own traffic keeps using the WAN.
    assert "main" not in k.routes
    assert k.sysctls["net.ipv4.ip_forward"] == "1"
    assert k.sysctls["net.ipv4.conf.wg0.rp_filter"] == "2"


def test_apply_is_idempotent():
    k = FakeKernel(links={"wlan0", "eth0", "wg0"})
    r = _routing(k)
    r.apply()
    r.apply()
    r.apply()
    assert len(k.rules) == 1, "re-applying must not stack duplicate ip rules"


def test_kill_switch_blocks_guests_when_tunnel_is_down():
    k = FakeKernel(links={"wlan0", "eth0", "wg0"})
    r = _routing(k)
    r.apply()
    k.drop_link("wg0")

    # Only the unreachable route is left for guest-sourced packets.
    assert k.routes["51820"] == {"192.168.50.0/24 dev wlan0", KILL}
    assert k.rules, "rule must stay so guests keep hitting the kill switch"


def test_apply_with_tunnel_missing_still_installs_kill_switch():
    k = FakeKernel(links={"wlan0", "eth0"})  # wg-quick up failed
    _routing(k).apply()
    assert k.routes["51820"] == {"192.168.50.0/24 dev wlan0", KILL}
    assert k.rules


def test_fallback_mode_omits_kill_switch():
    k = FakeKernel(links={"wlan0", "eth0", "wg0"})
    _routing(k, WG_FALLBACK_TO_WAN=True).apply()
    assert KILL not in k.routes["51820"]
    k.drop_link("wg0")
    # No default left in the guest table -> kernel falls through to main (WAN).
    assert not any(l.startswith(("default", "unreachable")) for l in k.routes["51820"])


def test_switching_to_fallback_removes_stale_kill_switch():
    k = FakeKernel(links={"wlan0", "eth0", "wg0"})
    _routing(k).apply()
    assert KILL in k.routes["51820"]
    _routing(k, WG_FALLBACK_TO_WAN=True).apply()
    assert KILL not in k.routes["51820"]


def test_ensure_repairs_route_after_tunnel_bounce():
    k = FakeKernel(links={"wlan0", "eth0", "wg0"})
    r = _routing(k)
    r.apply()
    k.drop_link("wg0")
    assert r.ensure() is False, "nothing to repair while wg0 is down"

    k.links.add("wg0")  # wg-quick up again, outside the host node
    assert r.ensure() is True
    assert "default dev wg0" in k.routes["51820"]
    assert r.ensure() is False, "second pass is a no-op"
    assert len(k.rules) == 1


def test_remove_cleans_up_rule_and_table_including_duplicates():
    k = FakeKernel(links={"wlan0", "eth0", "wg0"})
    r = _routing(k)
    r.apply()
    k.rules.append(k.rules[0])  # leftover from a crashed run
    r.remove()
    assert k.rules == []
    assert "51820" not in k.routes


def test_apply_raises_when_rule_cannot_be_installed():
    k = FakeKernel(links={"wlan0", "eth0", "wg0"})
    k.fail_on = "rule add"
    with pytest.raises(RoutingError):
        _routing(k).apply()


def test_status_reports_real_state():
    k = FakeKernel(links={"wlan0", "eth0", "wg0"})
    k.handshake = int(time.time()) - 30
    r = _routing(k)
    before = r.status()
    assert before.rule_installed is False
    r.apply()
    st = r.status()
    assert st.mode == "real"
    assert st.tunnel_up and st.rule_installed and st.tunnel_route_installed
    assert st.kill_switch is True
    assert 25 <= st.latest_handshake_age_seconds <= 60


def test_status_handshake_none_when_never_connected():
    k = FakeKernel(links={"wlan0", "eth0", "wg0"})
    assert _routing(k).status().latest_handshake_age_seconds is None


def test_fake_mode_touches_nothing():
    k = FakeKernel()
    r = GuestRouting(_settings(), runner=k, force_fake=True)
    r.apply()
    r.ensure()
    r.remove()
    assert k.calls == []
    assert r.status().mode == "fake"
