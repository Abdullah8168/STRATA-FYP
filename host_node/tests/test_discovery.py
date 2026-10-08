"""mDNS advertisement: which address and chain the host node announces."""

from __future__ import annotations

import subprocess

from strata_host import discovery

IP_OUT = "3: wlan0    inet 192.168.50.1/24 brd 192.168.50.255 scope global wlan0\\       valid_lft forever\n"


def test_guest_iface_address_is_parsed(monkeypatch):
    monkeypatch.setattr(
        discovery.subprocess, "run",
        lambda cmd, **kw: subprocess.CompletedProcess(cmd, 0, IP_OUT, ""),
    )
    assert discovery._get_iface_ipv4("wlan0") == "192.168.50.1"


def test_missing_iface_returns_none(monkeypatch):
    monkeypatch.setattr(
        discovery.subprocess, "run",
        lambda cmd, **kw: subprocess.CompletedProcess(cmd, 1, "", "Device not found"),
    )
    assert discovery._get_iface_ipv4("wlan9") is None


def test_ip_binary_missing_returns_none(monkeypatch):
    def boom(cmd, **kw):
        raise FileNotFoundError("ip")

    monkeypatch.setattr(discovery.subprocess, "run", boom)
    assert discovery._get_iface_ipv4("wlan0") is None


async def test_advertises_guest_address_and_configured_chain(test_settings, monkeypatch):
    """Guests must be pointed at the AP address (not the WAN one), and the
    TXT chain_id must be the chain the host actually listens on."""
    captured = {}

    class FakeInfo:
        def __init__(self, **kw):
            captured.update(kw)

    class FakeZc:
        def __init__(self, **kw): ...
        async def async_register_service(self, info): ...
        async def async_unregister_service(self, info): ...
        async def async_close(self): ...

    import zeroconf.asyncio as zc_asyncio

    monkeypatch.setattr(zc_asyncio, "AsyncServiceInfo", FakeInfo)
    monkeypatch.setattr(zc_asyncio, "AsyncZeroconf", FakeZc)
    monkeypatch.setattr(discovery, "_get_iface_ipv4", lambda iface: "192.168.50.1")
    monkeypatch.setattr(discovery, "_get_local_ipv4", lambda: "192.168.137.189")

    settings = test_settings.model_copy(update={"MDNS_ENABLED": True, "CHAIN_ID": 31337})
    adv = discovery.DiscoveryAdvertiser(settings)
    await adv.start()
    await adv.stop()

    import socket

    assert captured["addresses"] == [socket.inet_aton("192.168.50.1")]
    assert captured["properties"]["chain_id"] == b"31337"
