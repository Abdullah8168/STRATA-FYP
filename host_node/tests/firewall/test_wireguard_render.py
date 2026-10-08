"""Fast tests for the WireGuard config renderer + manager fake mode."""

from __future__ import annotations

from strata_host.config import Settings
from strata_host.firewall.wireguard import WireGuardManager


def _settings(**overrides) -> Settings:
    base = dict(
        WG_ENABLED=True,
        WG_PRIVATE_KEY_PATH="/tmp/strata-wg-test.key",
        WG_LISTEN_PORT=51820,
        WG_PEER_PUBLIC_KEY="fakePeerPubKey",
        WG_PEER_ENDPOINT="203.0.113.5:51820",
        WG_PEER_ALLOWED_IPS="0.0.0.0/0,::/0",
        WG_ADDRESS="10.66.66.1/24",
    )
    base.update(overrides)
    return Settings(**base)


def test_render_includes_interface_section():
    mgr = WireGuardManager(_settings(), force_fake=True)
    rendered = mgr.render_config(private_key="FAKE_PRIVATE")

    assert "[Interface]" in rendered
    assert "PrivateKey = FAKE_PRIVATE" in rendered
    assert "Address = 10.66.66.1/24" in rendered
    assert "ListenPort = 51820" in rendered


def test_render_disables_wg_quick_routes():
    """wg-quick must not install a full-tunnel route for the whole Pi;
    wg_routing steers only guest traffic into the tunnel."""
    mgr = WireGuardManager(_settings(), force_fake=True)
    rendered = mgr.render_config(private_key="FAKE_PRIVATE")
    interface = rendered.split("[Peer]")[0]
    assert "Table = off" in interface


def test_render_includes_peer_when_pubkey_set():
    mgr = WireGuardManager(_settings(), force_fake=True)
    rendered = mgr.render_config(private_key="FAKE_PRIVATE")

    assert "[Peer]" in rendered
    assert "PublicKey = fakePeerPubKey" in rendered
    assert "Endpoint = 203.0.113.5:51820" in rendered
    assert "AllowedIPs = 0.0.0.0/0,::/0" in rendered
    assert "PersistentKeepalive = 25" in rendered


def test_render_omits_peer_when_pubkey_unset():
    mgr = WireGuardManager(
        _settings(WG_PEER_PUBLIC_KEY=None, WG_PEER_ENDPOINT=None),
        force_fake=True,
    )
    rendered = mgr.render_config(private_key="FAKE_PRIVATE")

    assert "[Interface]" in rendered
    assert "[Peer]" not in rendered
    assert "PublicKey" not in rendered


def test_fake_mode_keypair_is_synthetic():
    mgr = WireGuardManager(_settings(), force_fake=True)
    priv, pub = mgr.ensure_keypair()
    assert priv == "FAKE_PRIVATE_KEY"
    assert pub == "FAKE_PUBLIC_KEY"


def test_fake_mode_bring_up_is_no_op():
    mgr = WireGuardManager(_settings(), force_fake=True)
    # Should not raise, should not touch the system.
    mgr.bring_up()
    mgr.bring_down()
    assert mgr.is_up() is False
