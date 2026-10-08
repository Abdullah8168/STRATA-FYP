"""Fast tests for the rendered nftables ruleset.

These don't require root — we just inspect the rendered string.
"""

from __future__ import annotations

import re

import pytest

from strata_host.firewall import NftContext, render_ruleset


def render(**overrides) -> str:
    base = NftContext(
        guest_iface="wlan0",
        wan_iface="eth0",
        wg_iface="wg0",
        portal_port=8080,
        ssh_port=22,
        wg_enabled=False,
    )
    return render_ruleset(NftContext(**{**base.__dict__, **overrides}))


def _section(text: str, start: str, end: str | None = None) -> str:
    """Slice a chain block out of the rendered ruleset for ordered checks.

    When ``end`` is None or the marker isn't found we slice to the end
    of the text — handy because forward is the last chain in the template.
    """
    a = text.index(start)
    if end is None:
        return text[a:]
    try:
        b = text.index(end, a + 1)
    except ValueError:
        return text[a:]
    return text[a:b]


def test_renders_with_strict_undefined_no_kabooms():
    # Just renders; Jinja's StrictUndefined is on so any missing var would
    # throw.
    out = render()
    assert "table inet strata" in out


def test_forward_chain_drops_invalid_state_first():
    out = render()
    fwd = _section(out, "chain forward")
    invalid_pos = fwd.index("ct state invalid drop")
    accept_pos = fwd.index("ct state { established, related } accept")
    assert invalid_pos < accept_pos, (
        "ct state invalid drop must come before the established/related "
        "fast-path so a malformed packet can't bypass it."
    )


def test_lan_isolation_runs_before_authed_accept():
    out = render()
    fwd = _section(out, "chain forward")
    lan_v4 = fwd.index("@strata_lan_v4")
    accept_idx = fwd.index("counter accept", lan_v4)
    assert lan_v4 < accept_idx, (
        "RFC1918 drops must come before the authed accept so a guest "
        "with a valid MAC still cannot pivot into the host LAN."
    )


def test_per_mac_meter_rule_is_50mbit():
    out = render()
    # 50 Mbit/s ≈ 6250 KB/s. The exact phrase is in the template.
    assert re.search(r"limit rate over 6250 kbytes/second", out), (
        "Per-MAC rate limiter must be set to the documented 50 Mbit/s."
    )
    # Declared as a dynamic set and filled per MAC by `update`; a standalone
    # `meter NAME { ... }` block is not valid nft syntax.
    assert "set strata_pmac" in out
    assert "update @strata_pmac { ether saddr limit rate over" in out
    assert "meter strata_pmac" not in out
    # Download direction too, keyed by the guest's IP.
    assert "set strata_pdown" in out
    assert "update @strata_pdown { ip daddr limit rate over 6250 kbytes/second }" in out


def test_guests_can_reach_mdns_before_paying():
    """Regression: the app discovers the host node via mDNS from the STRATA
    Wi-Fi before paying; dropping UDP 5353 hid the Pi from guests."""
    inp = _section(render(), "chain input", "chain forward")
    assert 'iifname "wlan0" udp dport 5353 accept' in inp
    assert 'iifname "eth0" udp dport 5353' not in inp


def test_caps_and_admission_run_before_established_fast_path():
    """Regression: with the limiter after `ct state established accept` it
    only saw each connection's first packet (measured: 24 Gbit/s through a
    "50 Mbit/s" cap), and removing a MAC left running downloads alive."""
    fwd = _section(render(), "chain forward")
    fast_path = fwd.index("ct state { established, related } accept")
    for rule in (
        'ether saddr != @strata_authed counter drop',
        "update @strata_pmac",
        "update @strata_pdown",
    ):
        assert fwd.index(rule) < fast_path, f"{rule!r} must come before the fast path"


def test_wg_enabled_adds_wg0_masquerade():
    out = render(wg_enabled=True)
    post = _section(out, "chain postrouting", "    chain ")
    assert 'oifname "wg0"' in post, "WG masquerade clause missing when enabled"


def test_wg_kill_switch_forbids_guest_wan_egress():
    """WG on, no fallback: guests may only leave through wg0."""
    out = render(wg_enabled=True, wg_fallback_to_wan=False)
    post = _section(out, "chain postrouting", "    chain ")
    fwd = _section(out, "chain forward")
    assert 'oifname "eth0" ether saddr @strata_authed masquerade' not in post
    assert 'oifname { "wg0" }' in fwd
    assert '"eth0", "wg0"' not in fwd
    assert fwd.count('oifname { "wg0" }') == 1  # the authed-egress accept


def test_wg_fallback_allows_both_egresses():
    out = render(wg_enabled=True, wg_fallback_to_wan=True)
    post = _section(out, "chain postrouting", "    chain ")
    fwd = _section(out, "chain forward")
    assert 'oifname "eth0" ether saddr @strata_authed masquerade' in post
    assert 'oifname "wg0" ether saddr @strata_authed masquerade' in post
    assert fwd.count('oifname { "eth0", "wg0" }') == 1


def test_wg_disabled_guests_use_wan_only():
    fwd = _section(render(wg_enabled=False), "chain forward")
    assert fwd.count('oifname { "eth0" }') == 1


def test_wg_enabled_clamps_mss_into_tunnel():
    fwd = _section(render(wg_enabled=True), "chain forward")
    clamp = 'oifname "wg0" tcp flags syn tcp option maxseg size set rt mtu'
    assert clamp in fwd
    assert fwd.index(clamp) < fwd.index("counter accept"), (
        "MSS clamp must run before the accept verdict ends evaluation"
    )
    assert "maxseg" not in render(wg_enabled=False)


def test_wg_disabled_omits_wg0_masquerade():
    out = render(wg_enabled=False)
    post = _section(out, "chain postrouting", "    chain ")
    assert 'oifname "wg0" ether saddr @strata_authed masquerade' not in post
    # Fallback still present.
    assert 'oifname "eth0" ether saddr @strata_authed masquerade' in post


def test_custom_interface_names_propagate():
    out = render(guest_iface="wlan1", wan_iface="enp0s3")
    assert 'iifname "wlan1"' in out
    assert 'oifname "enp0s3"' in out
    # Defaults should NOT appear when overridden.
    assert 'iifname "wlan0"' not in out


def test_unsolicited_inbound_drop_present():
    out = render()
    fwd = _section(out, "chain forward")
    assert re.search(r'iifname "eth0" ct state new counter drop', fwd), (
        "Phase F adds an explicit drop counter for new inbound flows on "
        "the WAN side."
    )


def test_input_chain_rate_limits_ping():
    out = render()
    inp = _section(out, "chain input", "chain forward")
    assert "icmp type echo-request limit rate 20/second accept" in inp
    assert "icmpv6 type echo-request limit rate 20/second accept" in inp


def test_lan_v6_set_includes_link_local_and_ula():
    out = render()
    assert "fc00::/7" in out
    assert "fe80::/10" in out


def test_render_accepts_settings_object():
    """render_ruleset should accept either an NftContext or a Settings."""
    from strata_host.config import Settings

    s = Settings(GUEST_IFACE="ap0", WAN_IFACE="wan0", WG_ENABLED=True)
    out = render_ruleset(s)
    assert 'iifname "ap0"' in out
    assert 'iifname "wan0"' in out
    assert 'oifname "wg0"' in out  # because WG_ENABLED=True
    # Kill switch is the default, so wan0 is not a guest egress.
    assert 'oifname "wan0"' not in out

    s = Settings(GUEST_IFACE="ap0", WAN_IFACE="wan0", WG_ENABLED=True, WG_FALLBACK_TO_WAN=True)
    assert 'oifname "wan0"' in render_ruleset(s)
