"""Phase G — admin endpoint tests."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from strata_host.config import Settings
from strata_host.main import create_app


@pytest.fixture
def admin_disabled_client():
    settings = Settings(
        DEMO_MODE=True,
        CHAIN_ENABLED=False,
        MDNS_ENABLED=False,
        ADMIN_TOKEN=None,
    )
    with TestClient(create_app(settings)) as client:
        yield client


@pytest.fixture
def admin_enabled_client():
    settings = Settings(
        DEMO_MODE=True,
        CHAIN_ENABLED=False,
        MDNS_ENABLED=False,
        ADMIN_TOKEN="super-secret",
    )
    with TestClient(create_app(settings)) as client:
        yield client


def test_admin_disabled_returns_503(admin_disabled_client):
    resp = admin_disabled_client.get(
        "/admin/firewall/state",
        headers={"Authorization": "Bearer anything"},
    )
    assert resp.status_code == 503


def test_admin_requires_correct_token(admin_enabled_client):
    resp = admin_enabled_client.get(
        "/admin/firewall/state",
        headers={"Authorization": "Bearer wrong-token"},
    )
    assert resp.status_code == 401


def test_firewall_state_returns_admitted_macs(admin_enabled_client):
    # No sessions yet — current_macs should be empty.
    resp = admin_enabled_client.get(
        "/admin/firewall/state",
        headers={"Authorization": "Bearer super-secret"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["count"] == 0
    assert body["authed_macs"] == []


def test_reconcile_returns_409_when_chain_disabled(admin_enabled_client):
    # The default ChainService stub has no reconcile() method.
    resp = admin_enabled_client.post(
        "/admin/reconcile",
        headers={"Authorization": "Bearer super-secret"},
    )
    assert resp.status_code == 409
    assert resp.json()["detail"]["code"] == "CHAIN_DISABLED"
