import asyncio
import sys

from httpx import ASGITransport, AsyncClient

from strata_host.main import create_app


async def test_health_ok(client):
    response = await client.get("/health")
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ok"
    assert payload["service"] == "strata-host-node"
    assert "uptime_seconds" in payload
    assert payload["demo_mode"] is True


async def test_health_omits_wireguard_when_disabled(client):
    payload = (await client.get("/health")).json()
    assert payload["wireguard"] is None


async def test_health_reports_wireguard_when_enabled(test_settings, monkeypatch):
    """Full lifespan with WG on: bring-up, routing apply, watchdog and
    teardown all run (in fake mode off-Linux / off-root)."""
    monkeypatch.setenv("STRATA_WG_FAKE", "true")
    settings = test_settings.model_copy(
        update={
            "WG_ENABLED": True,
            "WG_PEER_PUBLIC_KEY": "peer",
            "WG_PEER_ENDPOINT": "203.0.113.5:51820",
            "WG_ROUTE_CHECK_SECONDS": 0.01,
        }
    )
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        await asyncio.sleep(0.05)  # let the route watchdog tick a few times
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://testserver") as c:
            payload = (await c.get("/health")).json()
    assert payload["wireguard"] == {
        "mode": "fake",
        "tunnel_up": False,
        "rule_installed": False,
        "tunnel_route_installed": False,
        "kill_switch": True,
        "latest_handshake_age_seconds": None,
    }


async def test_version_ok(client):
    response = await client.get("/version")
    assert response.status_code == 200
    payload = response.json()
    assert payload["service"] == "strata-host-node"
    assert payload["version"] == "0.1.0"
    assert payload["python"] == sys.version.split()[0]

