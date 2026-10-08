"""Unit tests for neighbour MAC lookup (no Linux required)."""

import json

from strata_host.neighbour import is_valid_mac, lookup_mac_for_ip, normalize_mac


def test_normalize_and_validate_mac():
    assert normalize_mac("AA:BB:CC:DD:EE:FF") == "aa:bb:cc:dd:ee:ff"
    assert is_valid_mac("aa:bb:cc:dd:ee:ff")
    assert not is_valid_mac("")
    assert not is_valid_mac("not-a-mac")


def test_lookup_mac_for_ip_parses_neigh_json(monkeypatch):
    import strata_host.neighbour as neighbour

    monkeypatch.setattr(neighbour.sys, "platform", "linux")

    class _Proc:
        returncode = 0
        stdout = json.dumps(
            [
                {"dst": "192.168.50.10", "lladdr": "AA:BB:CC:DD:EE:01"},
                {"dst": "192.168.50.11", "lladdr": "11:22:33:44:55:66"},
            ]
        )

    def fake_run(*_a, **_k):
        return _Proc()

    mac = lookup_mac_for_ip("192.168.50.10", "wlan0", runner=fake_run)
    assert mac == "aa:bb:cc:dd:ee:01"
    assert lookup_mac_for_ip("192.168.50.99", "wlan0", runner=fake_run) is None
