"""Host controls for the app: /admin/host, /admin/sharing, guest limit."""

from __future__ import annotations

import json
import subprocess
from uuid import uuid4

import pytest
import pytest_asyncio
from eth_account import Account
from httpx import ASGITransport, AsyncClient

from strata_host.host_config import (
    HostConfigError,
    HostConfigStore,
    Hotspot,
    validate_listing,
    validate_wifi,
)
from strata_host.main import create_app

from .conftest import _sign_start

TOKEN = "test-admin-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
HOST = "0x2222222222222222222222222222222222222222"


# --- validation -----------------------------------------------------------------


def test_listing_validation_accepts_and_normalises():
    out = validate_listing({"display_name": "  Ali's Wi-Fi ", "price_per_gb_wei": "0500",
                            "price_per_gb": "1.5", "max_guests": 3})
    assert out == {"HOST_DISPLAY_NAME": "Ali's Wi-Fi", "DEFAULT_PRICE_PER_GB_WEI": "500",
                   "DEFAULT_PRICE_PER_GB": 1.5, "MAX_GUESTS": 3}
    assert validate_listing({"max_guests": None}) == {"MAX_GUESTS": None}


@pytest.mark.parametrize("changes", [
    {"display_name": ""}, {"display_name": "x" * 41}, {"display_name": "a\nb"},
    {"price_per_gb_wei": "0"}, {"price_per_gb_wei": "-5"}, {"price_per_gb_wei": "1e18"},
    {"price_per_gb": "free"}, {"price_per_gb": -1},
    {"max_guests": 0}, {"max_guests": 201}, {"max_guests": True}, {"max_guests": "3"},
])
def test_listing_validation_rejects(changes):
    with pytest.raises(HostConfigError):
        validate_listing(changes)


def test_wifi_validation():
    validate_wifi("STRATA-Pi-01", "strata2026")
    validate_wifi("My Cafe Wi-Fi", "pass word 123")
    for ssid in ("", " lead", "trail ", "x" * 33, "bad\nname", "a'b", "a$b"):
        with pytest.raises(HostConfigError):
            validate_wifi(ssid, None)
    # Anything that could break out of hostapd.conf or the bash-sourced .env.
    for pw in ("short", "x" * 64, "abc'defgh", 'abc"defgh', "abc$defgh", "abc`defgh",
               "abc\\defgh", "abc;defgh", "abcdefgh\nssid=evil"):
        with pytest.raises(HostConfigError):
            validate_wifi(None, pw)


# --- saved overrides ---------------------------------------------------------------


def test_store_round_trip_and_never_saves_password(tmp_path):
    store = HostConfigStore(str(tmp_path / "host.json"))
    assert store.load() == {}
    store.save({"HOST_DISPLAY_NAME": "A", "DEFAULT_PRICE_PER_GB_WEI": "5"})
    store.save({"HOST_DISPLAY_NAME": "B"})
    assert store.load() == {"HOST_DISPLAY_NAME": "B", "DEFAULT_PRICE_PER_GB_WEI": "5"}
    # Unknown keys in the file (hand edits, old versions) are ignored.
    (tmp_path / "host.json").write_text(json.dumps({"WPA_PASSPHRASE": "x", "ADMIN_TOKEN": "y"}))
    assert store.load() == {}


# --- hotspot (real mode against temp files + fake systemctl) -----------------------


class FakeSystemctl:
    def __init__(self, active: bool = True):
        self.active = active
        self.calls: list[list[str]] = []

    def __call__(self, cmd):
        self.calls.append(cmd)
        if cmd[:2] == ["systemctl", "is-active"]:
            return subprocess.CompletedProcess(cmd, 0, "active\n" if self.active else "inactive\n", "")
        if cmd[1] == "stop":
            self.active = False
        if cmd[1] == "start":
            self.active = True
        return subprocess.CompletedProcess(cmd, 0, "", "")


def _hotspot(test_settings, tmp_path, runner):
    conf = tmp_path / "hostapd.conf"
    conf.write_text("interface=wlan0\nssid=STRATA-Pi-01\nwpa=2\nwpa_passphrase=strata2026\n")
    env = tmp_path / "ap.env"
    env.write_text("AP_IFACE=wlan0\nSSID=STRATA-Pi-01\nWPA_PASSPHRASE=strata2026\nCHANNEL=6\n")
    settings = test_settings.model_copy(update={"HOSTAPD_CONF_PATH": str(conf),
                                                "AP_ENV_PATH": str(env)})
    return Hotspot(settings, runner=runner, force_fake=False), conf, env


def test_set_wifi_rewrites_configs_and_restarts(test_settings, tmp_path):
    runner = FakeSystemctl()
    hs, conf, env = _hotspot(test_settings, tmp_path, runner)
    hs.set_wifi("Cafe Net", "new pass 99")
    assert conf.read_text() == "interface=wlan0\nssid=Cafe Net\nwpa=2\nwpa_passphrase=new pass 99\n"
    env_text = env.read_text()
    assert "SSID='Cafe Net'" in env_text and "WPA_PASSPHRASE='new pass 99'" in env_text
    assert "CHANNEL=6" in env_text, "other settings untouched"
    assert ["systemctl", "restart", "strata-hostapd", "strata-dnsmasq"] in runner.calls
    # Sourced the way setup_ap.sh does it: values with spaces survive.
    out = subprocess.run(["bash", "-c", f"set -a; source '{env.as_posix()}'; echo \"$SSID|$WPA_PASSPHRASE\""],
                         capture_output=True, text=True)
    if out.returncode == 0:  # bash may be missing on some CI images
        assert out.stdout.strip() == "Cafe Net|new pass 99"


def test_set_wifi_password_only_keeps_name(test_settings, tmp_path):
    hs, conf, _ = _hotspot(test_settings, tmp_path, FakeSystemctl())
    hs.set_wifi(None, "another123")
    assert "ssid=STRATA-Pi-01\n" in conf.read_text()
    assert "wpa_passphrase=another123\n" in conf.read_text()


def test_set_wifi_while_sharing_off_does_not_restart(test_settings, tmp_path):
    runner = FakeSystemctl(active=False)
    hs, _, _ = _hotspot(test_settings, tmp_path, runner)
    hs.set_wifi("Quiet", None)
    assert not any(c[1] == "restart" for c in runner.calls)


def test_sharing_on_off(test_settings, tmp_path):
    runner = FakeSystemctl()
    hs, _, _ = _hotspot(test_settings, tmp_path, runner)
    hs.set_enabled(False)
    assert runner.calls[-1] == ["systemctl", "stop", "strata-hostapd"]
    assert hs.is_enabled() is False
    hs.set_enabled(True)
    assert runner.calls[-1] == ["systemctl", "start", "strata-hostapd", "strata-dnsmasq"]
    assert hs.is_enabled() is True


# --- API ---------------------------------------------------------------------------


@pytest_asyncio.fixture
async def admin_client(test_settings, tmp_path):
    settings = test_settings.model_copy(update={
        "ADMIN_TOKEN": TOKEN, "HOST_CONFIG_PATH": str(tmp_path / "host.json"),
    })
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        app.state.hotspot = Hotspot(settings, force_fake=True)
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://pi") as c:
            yield c, settings, tmp_path


async def test_admin_needs_the_token(admin_client):
    c, _, _ = admin_client
    assert (await c.get("/admin/host")).status_code == 401
    assert (await c.get("/admin/host", headers={"Authorization": "Bearer nope"})).status_code == 401
    assert (await c.put("/admin/host", json={"display_name": "x"})).status_code == 401
    assert (await c.post("/admin/sharing", json={"enabled": False})).status_code == 401


async def test_admin_disabled_without_token(client):
    assert (await client.get("/admin/host")).status_code == 503


async def test_get_host_doubles_as_pairing_check(admin_client):
    c, settings, _ = admin_client
    body = (await c.get("/admin/host", headers=AUTH)).json()
    assert body["display_name"] == settings.HOST_DISPLAY_NAME
    assert body["wifi_name"] == settings.HOST_SSID
    assert body["sharing_enabled"] is True
    assert body["max_guests"] is None
    assert body["host_wallet_address"] == HOST
    assert "wifi_password" not in body


async def test_update_listing_applies_now_and_persists(admin_client):
    c, _, tmp_path = admin_client
    r = await c.put("/admin/host", headers=AUTH, json={
        "display_name": "Abdullah's Pi", "price_per_gb_wei": "2000000000000000000",
        "price_per_gb": 1.0, "max_guests": 5})
    assert r.status_code == 200, r.text
    assert r.json()["wifi_restarted"] is False
    info = (await c.get("/host/info")).json()  # what guests see
    assert info["display_name"] == "Abdullah's Pi"
    assert info["price_per_gb_wei"] == "2000000000000000000"
    saved = json.loads((tmp_path / "host.json").read_text())
    assert saved == {"HOST_DISPLAY_NAME": "Abdullah's Pi",
                     "DEFAULT_PRICE_PER_GB_WEI": "2000000000000000000",
                     "DEFAULT_PRICE_PER_GB": 1.0, "MAX_GUESTS": 5}


async def test_saved_settings_survive_a_restart(test_settings, tmp_path):
    (tmp_path / "host.json").write_text(json.dumps(
        {"HOST_DISPLAY_NAME": "Saved Name", "MAX_GUESTS": 2, "HOST_SSID": "Saved-SSID"}))
    settings = test_settings.model_copy(update={"HOST_CONFIG_PATH": str(tmp_path / "host.json")})
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://pi") as c:
            info = (await c.get("/host/info")).json()
    assert info["display_name"] == "Saved Name" and info["ssid"] == "Saved-SSID"
    assert settings.MAX_GUESTS == 2


async def test_update_wifi_reports_restart_and_hides_password(admin_client):
    c, settings, tmp_path = admin_client
    r = await c.put("/admin/host", headers=AUTH,
                    json={"wifi_name": "Cafe-Net", "wifi_password": "supersecret1"})
    body = r.json()
    assert r.status_code == 200 and body["wifi_restarted"] is True
    assert body["wifi_name"] == "Cafe-Net" and settings.HOST_SSID == "Cafe-Net"
    assert "supersecret1" not in r.text
    assert "supersecret1" not in (tmp_path / "host.json").read_text()


async def test_bad_values_are_rejected_and_nothing_changes(admin_client):
    c, settings, tmp_path = admin_client
    before = settings.HOST_DISPLAY_NAME
    for bad in ({"display_name": ""}, {"wifi_password": "short"},
                {"wifi_name": "evil\nssid=x"}, {"price_per_gb_wei": "abc"},
                {"display_name": "ok", "max_guests": 0}):
        r = await c.put("/admin/host", headers=AUTH, json=bad)
        assert r.status_code == 422, (bad, r.text)
    r = await c.put("/admin/host", headers=AUTH, json={"admin_token": "x"})  # unknown field
    assert r.status_code == 422
    assert settings.HOST_DISPLAY_NAME == before
    assert not (tmp_path / "host.json").exists()


async def test_sharing_toggle(admin_client):
    c, _, _ = admin_client
    assert (await c.post("/admin/sharing", headers=AUTH, json={"enabled": False})).json() == {
        "sharing_enabled": False}
    assert (await c.get("/admin/host", headers=AUTH)).json()["sharing_enabled"] is False
    assert (await c.post("/admin/sharing", headers=AUTH, json={"enabled": True})).json() == {
        "sharing_enabled": True}


# --- guest limit -------------------------------------------------------------------


def _start(mac: str) -> dict:
    acct = Account.create()
    nonce, quota = str(uuid4()), 10_000_000
    return {
        "guest_wallet_address": acct.address, "host_wallet_address": HOST, "mac_address": mac,
        "quota_bytes": quota, "price_per_gb_wei": "1", "nonce": nonce,
        "guest_signature": _sign_start(acct, guest=acct.address, host=HOST, mac=mac,
                                       quota=quota, nonce=nonce),
    }


async def test_max_guests_blocks_extra_guests(admin_client):
    c, _, _ = admin_client
    await c.put("/admin/host", headers=AUTH, json={"max_guests": 1})
    assert (await c.post("/session/start", json=_start("aa:aa:aa:aa:aa:01"))).status_code == 200
    r = await c.post("/session/start", json=_start("aa:aa:aa:aa:aa:02"))
    assert r.status_code == 409 and r.json()["error"]["code"] == "HOST_FULL"
    # The guest already inside isn't counted against themselves.
    r = await c.post("/session/start", json=_start("aa:aa:aa:aa:aa:01"))
    assert r.json()["error"]["code"] == "MAC_ALREADY_ACTIVE"
    # Lifting the limit lets the second guest in.
    await c.put("/admin/host", headers=AUTH, json={"max_guests": None})
    assert (await c.post("/session/start", json=_start("aa:aa:aa:aa:aa:02"))).status_code == 200


async def test_no_limit_by_default(client):
    for i in range(5):
        r = await client.post("/session/start", json=_start(f"aa:aa:aa:aa:ab:0{i}"))
        assert r.status_code == 200, r.text
