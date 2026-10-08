"""Integration: guest-only routing through the tunnel + kill switch.

Real kernel, no VPS needed. Two namespaces play "tunnel exit" and "WAN";
both own the same public-looking address 198.51.100.7 and serve a file
that says which side answered. The root namespace plays the Pi:

    guest ns ──vstrata── Pi (root) ──vtun (stands in for wg0)── tun ns  → "TUN"
                              └─────vwan (stands in for eth0)── wan ns  → "WAN"

The Pi's main table reaches 198.51.100.7 via the WAN, exactly like a real
Pi whose default route is eth0. Only GuestRouting can send guests to TUN.

Run on Linux as root:
    sudo .venv/bin/python -m pytest -q -m integration tests/firewall/integration/test_wg_guest_routing.py
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import ExitStack, contextmanager

import pytest

from strata_host.config import Settings
from strata_host.firewall import NftContext, render_ruleset
from strata_host.firewall.netns import (
    GUEST_VETH_NS,
    add_authed_mac,
    applied_rules,
    guest_namespace,
    in_ns,
)
from strata_host.firewall.wg_routing import GuestRouting

from ._topology import TARGET, fetch, make_link, remote_namespace, sh

TUN_NS, WAN_NS = "strata_tunx", "strata_wanx"
TUN_HOST, TUN_PEER = "vtun0", "vtun1"
WAN_HOST, WAN_PEER = "vwan0", "vwan1"
TABLE, PRIO = 51821, 10001  # don't collide with a running host node


@contextmanager
def _topology(authed_mac: str, *, fallback: bool) -> Iterator[tuple[str, GuestRouting]]:
    ctx = NftContext(
        guest_iface="vstrata0",
        wan_iface=WAN_HOST,
        wg_iface=TUN_HOST,
        wg_enabled=True,
        wg_fallback_to_wan=fallback,
    )
    settings = Settings(
        GUEST_IFACE="vstrata0",
        GUEST_SUBNET="192.168.50.0/24",
        WG_ROUTE_TABLE=TABLE,
        WG_RULE_PRIORITY=PRIO,
        WG_FALLBACK_TO_WAN=fallback,
    )
    routing = GuestRouting(settings, wg_iface=TUN_HOST, force_fake=False)
    with ExitStack() as stack:
        stack.enter_context(applied_rules(render_ruleset(ctx)))
        ns = stack.enter_context(guest_namespace())
        stack.enter_context(remote_namespace(TUN_NS, TUN_HOST, TUN_PEER, "10.66.66", "TUN"))
        stack.enter_context(remote_namespace(WAN_NS, WAN_HOST, WAN_PEER, "10.77.0", "WAN"))
        # The Pi's own route to the "internet" is via the WAN.
        sh("ip", "route", "replace", f"{TARGET}/32", "via", "10.77.0.2")
        stack.callback(sh, "ip", "route", "del", f"{TARGET}/32", check=False)
        in_ns(ns, ["ip", "link", "set", GUEST_VETH_NS, "address", authed_mac])
        add_authed_mac(authed_mac)
        stack.callback(routing.remove)
        routing.apply()
        yield ns, routing


def _drop_tunnel() -> None:
    """What `wg-quick down` does: the interface and its routes vanish."""
    sh("ip", "link", "del", TUN_HOST)


@pytest.mark.integration
def test_guest_traffic_exits_via_tunnel_pi_traffic_stays_on_wan(authed_mac):
    with _topology(authed_mac, fallback=False) as (ns, _):
        assert fetch(ns) == "TUN", "admitted guest must egress through the tunnel"
        assert fetch(None) == "WAN", "the Pi's own traffic must keep using the WAN"
        # Even when the Pi uses its AP address as source (portal, mDNS), it
        # is not a forwarded guest packet and must not enter the tunnel.
        assert fetch(None, source="192.168.50.1") == "WAN"


@pytest.mark.integration
def test_kill_switch_blocks_guest_when_tunnel_down(authed_mac):
    with _topology(authed_mac, fallback=False) as (ns, _):
        assert fetch(ns) == "TUN"
        _drop_tunnel()
        result = fetch(ns)
        assert result.startswith("FAIL"), f"guest leaked out of the WAN: {result!r}"
        assert fetch(None) == "WAN", "the Pi itself must stay online"


@pytest.mark.integration
def test_fallback_uses_wan_when_tunnel_down(authed_mac):
    with _topology(authed_mac, fallback=True) as (ns, _):
        assert fetch(ns) == "TUN"
        _drop_tunnel()
        assert fetch(ns) == "WAN"


@pytest.mark.integration
def test_ensure_restores_tunnel_route_after_bounce(authed_mac):
    with _topology(authed_mac, fallback=False) as (ns, routing):
        _drop_tunnel()
        assert fetch(ns).startswith("FAIL")
        make_link(TUN_NS, TUN_HOST, TUN_PEER, "10.66.66.1", "10.66.66.2")
        assert routing.ensure() is True
        assert fetch(ns) == "TUN"


@pytest.mark.integration
def test_remove_leaves_no_rule_or_table(authed_mac):
    with _topology(authed_mac, fallback=False) as (_, routing):
        routing.remove()
        assert f"lookup {TABLE}" not in sh("ip", "rule", "show").stdout
        assert sh("ip", "route", "show", "table", str(TABLE)).stdout.strip() == ""
