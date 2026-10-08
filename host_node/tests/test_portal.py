"""Captive portal GET / landing page."""

from __future__ import annotations

from fastapi.testclient import TestClient

from strata_host.config import Settings
from strata_host.main import create_app


def test_root_returns_html_captive_portal() -> None:
    settings = Settings(HOST_WALLET_ADDRESS="0xabcdef1234567890abcdef1234567890abcd")
    app = create_app(settings)
    with TestClient(app) as client:
        response = client.get("/")
    assert response.status_code == 200
    ct = response.headers.get("content-type", "")
    assert "text/html" in ct
    body = response.text
    assert "STRATA" in body
    assert "peer-to-peer" in body.lower()
    assert settings.HOST_WALLET_ADDRESS in body
    assert "strata://onboard?" in body
    assert "portal_ip=testserver" in body or "portal_ip=" in body
    assert "data:image/svg+xml;base64," in body


def test_root_shows_not_configured_when_no_wallet() -> None:
    settings = Settings(HOST_WALLET_ADDRESS=None)
    app = create_app(settings)
    with TestClient(app) as client:
        response = client.get("/")
    assert response.status_code == 200
    assert "Not configured yet" in response.text
    assert "0x0000000000000000000000000000000000000000" in response.text
