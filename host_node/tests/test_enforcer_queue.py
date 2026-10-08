"""Phase G — EnforcerService queue + origin tagging tests."""

from __future__ import annotations

import pytest

from strata_host.enforcer import EnforcerService
from strata_host.firewall.nft_set import NftSet


@pytest.mark.asyncio
async def test_admit_disconnect_via_queue_uses_fake_nftset():
    enforcer = EnforcerService(NftSet(force_fake=True))
    await enforcer.start()
    try:
        await enforcer.admit("aa:bb:cc:dd:ee:01", origin="chain")
        await enforcer.admit("aa:bb:cc:dd:ee:02", origin="portal")
        assert enforcer.current_macs() == [
            "aa:bb:cc:dd:ee:01",
            "aa:bb:cc:dd:ee:02",
        ]
        await enforcer.disconnect("aa:bb:cc:dd:ee:01", origin="meter")
        assert enforcer.current_macs() == ["aa:bb:cc:dd:ee:02"]
    finally:
        await enforcer.stop()


@pytest.mark.asyncio
async def test_fast_path_when_not_started():
    """EnforcerService must work without calling start() so legacy tests
    that construct it directly stay green."""
    enforcer = EnforcerService(NftSet(force_fake=True))
    await enforcer.admit("aa:bb:cc:dd:ee:03", origin="test")
    assert "aa:bb:cc:dd:ee:03" in enforcer.current_macs()
    await enforcer.disconnect("aa:bb:cc:dd:ee:03", origin="test")
    assert "aa:bb:cc:dd:ee:03" not in enforcer.current_macs()


@pytest.mark.asyncio
async def test_admits_from_different_origins_serialize():
    enforcer = EnforcerService(NftSet(force_fake=True))
    await enforcer.start()
    try:
        # Fire a bunch concurrently — they must all land in the in-memory
        # mirror without losing any.
        import asyncio

        await asyncio.gather(
            *[
                enforcer.admit(f"aa:bb:cc:dd:ee:{i:02x}", origin="chain")
                for i in range(8)
            ]
        )
        macs = enforcer.current_macs()
        assert len(macs) == 8
    finally:
        await enforcer.stop()
