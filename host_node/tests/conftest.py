from uuid import uuid4

import pytest
import pytest_asyncio
from eth_account import Account
from eth_account.messages import encode_defunct
from httpx import ASGITransport, AsyncClient

from strata_host.config import Settings
from strata_host.main import create_app
from strata_host.session_crypto import build_session_start_message

# Tests must not depend on a developer's local host_node/.env (e.g. one with
# CHAIN_ENABLED=true would make Settings() fail validation in unrelated tests).
Settings.model_config["env_file"] = None


@pytest.fixture
def guest_account():
    return Account.create()


@pytest.fixture
def test_settings() -> Settings:
    return Settings(
        DEMO_MODE=True,
        METER_TICK_SECONDS=0.05,
        SESSION_DEFAULT_TTL_SECONDS=3600,
        LOG_LEVEL="WARNING",
        CHAIN_ENABLED=False,
        # ASGI tests have no ARP table — allow the payload MAC.
        ALLOW_CLIENT_MAC=True,
        HOST_WALLET_ADDRESS="0x2222222222222222222222222222222222222222",
        HOST_DISPLAY_NAME="STRATA Test Host",
        HOST_SSID="STRATA-Test",
    )


@pytest.fixture
def chain_enabled_settings() -> Settings:
    # CHAIN_ENABLED without escrow addresses keeps the Phase A ChainService
    # stub while SessionStore still uses pending_payment. Production boots
    # must not use this combination — validate_settings rejects it.
    # Tests pass validate=False on create_app (see chain_app fixture).
    return Settings(
        DEMO_MODE=True,
        METER_TICK_SECONDS=0.05,
        SESSION_DEFAULT_TTL_SECONDS=3600,
        LOG_LEVEL="WARNING",
        CHAIN_ENABLED=True,
        ALLOW_CLIENT_MAC=True,
        HOST_WALLET_ADDRESS="0x2222222222222222222222222222222222222222",
        MDNS_ENABLED=False,
    )


@pytest_asyncio.fixture
async def app(test_settings: Settings):
    app = create_app(test_settings)
    async with app.router.lifespan_context(app):
        yield app


@pytest_asyncio.fixture
async def chain_app(chain_enabled_settings: Settings):
    app = create_app(chain_enabled_settings, validate=False)
    async with app.router.lifespan_context(app):
        yield app


@pytest_asyncio.fixture
async def client(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://testserver") as client:
        yield client


@pytest_asyncio.fixture
async def chain_client(chain_app):
    transport = ASGITransport(app=chain_app)
    async with AsyncClient(transport=transport, base_url="http://testserver") as client:
        yield client


def _sign_start(account, *, guest: str, host: str, mac: str, quota: int, nonce: str) -> str:
    msg = build_session_start_message(
        guest_wallet=guest,
        host_wallet=host,
        mac_address=mac,
        quota_bytes=quota,
        nonce=nonce,
    )
    signed = account.sign_message(encode_defunct(text=msg))
    sig = signed.signature.hex()
    return sig if sig.startswith("0x") else "0x" + sig


@pytest.fixture
def start_payload(guest_account) -> dict:
    nonce = str(uuid4())
    guest = guest_account.address
    host = "0x2222222222222222222222222222222222222222"
    mac = "aa:bb:cc:dd:ee:ff"
    quota = 10_000_000
    return {
        "guest_wallet_address": guest,
        "host_wallet_address": host,
        "mac_address": mac,
        "quota_bytes": quota,
        "guest_signature": _sign_start(
            guest_account, guest=guest, host=host, mac=mac, quota=quota, nonce=nonce
        ),
        "nonce": nonce,
        "price_per_gb_wei": "1000000000000000",
    }
