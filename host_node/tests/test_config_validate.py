"""Configuration fail-fast tests (Iteration 3)."""

from __future__ import annotations

import pytest
from eth_account import Account

from strata_host.config import Settings
from strata_host.config_validate import ConfigurationError, validate_settings
from strata_host.main import create_app


def test_chain_enabled_without_escrow_raises():
    settings = Settings(
        CHAIN_ENABLED=True,
        HOST_WALLET_ADDRESS="0x2222222222222222222222222222222222222222",
        SESSION_ESCROW_ADDRESS=None,
        STRATA_TOKEN_ADDRESS=None,
        HOST_SIGNING_PRIVATE_KEY=None,
    )
    with pytest.raises(ConfigurationError, match="SESSION_ESCROW_ADDRESS"):
        validate_settings(settings)


def test_wg_enabled_without_peer_raises():
    settings = Settings(
        CHAIN_ENABLED=False,
        WG_ENABLED=True,
        WG_PEER_PUBLIC_KEY=None,
        WG_PEER_ENDPOINT=None,
    )
    with pytest.raises(ConfigurationError, match="WG_PEER_PUBLIC_KEY"):
        validate_settings(settings)


@pytest.mark.parametrize("subnet", ["192.168.50.1/24", "not-a-subnet", "fd00::/64"])
def test_wg_enabled_rejects_bad_guest_subnet(subnet):
    settings = Settings(
        CHAIN_ENABLED=False,
        WG_ENABLED=True,
        WG_PEER_PUBLIC_KEY="peer",
        WG_PEER_ENDPOINT="203.0.113.5:51820",
        GUEST_SUBNET=subnet,
    )
    with pytest.raises(ConfigurationError, match="GUEST_SUBNET"):
        validate_settings(settings)


def test_wg_enabled_accepts_default_guest_subnet():
    validate_settings(
        Settings(
            CHAIN_ENABLED=False,
            WG_ENABLED=True,
            WG_PEER_PUBLIC_KEY="peer",
            WG_PEER_ENDPOINT="203.0.113.5:51820",
        )
    )


def test_signing_key_must_match_host_wallet():
    acct = Account.create()
    other = Account.create()
    settings = Settings(
        CHAIN_ENABLED=True,
        SESSION_ESCROW_ADDRESS="0x1111111111111111111111111111111111111111",
        STRATA_TOKEN_ADDRESS="0x2222222222222222222222222222222222222222",
        HOST_WALLET_ADDRESS=other.address,
        HOST_SIGNING_PRIVATE_KEY=acct.key.hex(),
        AMOY_WSS_URL="wss://example.invalid",
    )
    with pytest.raises(ConfigurationError, match="HOST_SIGNING_PRIVATE_KEY derives"):
        validate_settings(settings)


def test_valid_chain_config_passes():
    acct = Account.create()
    settings = Settings(
        CHAIN_ENABLED=True,
        SESSION_ESCROW_ADDRESS="0x1111111111111111111111111111111111111111",
        STRATA_TOKEN_ADDRESS="0x2222222222222222222222222222222222222222",
        HOST_WALLET_ADDRESS=acct.address,
        HOST_SIGNING_PRIVATE_KEY=acct.key.hex(),
        AMOY_WSS_URL="wss://example.invalid",
    )
    validate_settings(settings)  # must not raise


def test_create_app_rejects_broken_chain_config():
    settings = Settings(
        CHAIN_ENABLED=True,
        DEMO_MODE=True,
        MDNS_ENABLED=False,
        HOST_WALLET_ADDRESS="0x2222222222222222222222222222222222222222",
    )
    with pytest.raises(ConfigurationError):
        create_app(settings)
