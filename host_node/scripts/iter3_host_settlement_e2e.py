#!/usr/bin/env python3
"""Iteration 3 — periodic micropayment + host-driven settlement E2E.

Runs the real host node app (listener, meter, PaymentService) against a real
local Hardhat chain, driving it over HTTP the way the Flutter app does:

  POST /session/start -> guest openSession on-chain -> listener admits
  -> periodic signed checkpoints + accrued cost -> POST /session/stop
  -> Case A: guest does nothing -> after the grace period the ROUTER sends
            closeSession; host is paid, guest refunded, on-chain.
  -> Case B: guest settles within the grace period -> router records
            closed_by_guest and sends nothing.

Prerequisites:
  Terminal A:  cd contracts && npx hardhat node
  Then:        host_node/.venv/bin/python host_node/scripts/iter3_host_settlement_e2e.py
"""

from __future__ import annotations

import asyncio
import sys
import time
from pathlib import Path
from uuid import uuid4

from eth_account import Account
from eth_account.messages import encode_defunct
from httpx import ASGITransport, AsyncClient
from web3 import Web3

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "host_node" / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from iter3_local_chain_e2e import (  # noqa: E402
    ARTIFACT_ESCROW,
    ARTIFACT_TOKEN,
    GUEST_KEY,
    HOST_KEY,
    RPC,
    _deploy,
    _load_abi,
    _must_connect,
)
from strata_host.config import Settings  # noqa: E402
from strata_host.main import create_app  # noqa: E402
from strata_host.session_crypto import build_session_start_message  # noqa: E402

QUOTA = 1024**3  # 1 GiB
DEPOSIT = Web3.to_wei(5, "ether")
GRACE = 3.0


def _send(w3: Web3, account, fn) -> dict:
    tx = fn.build_transaction(
        {
            "from": account.address,
            "nonce": w3.eth.get_transaction_count(account.address),
            "chainId": w3.eth.chain_id,
        }
    )
    signed = account.sign_transaction(tx)
    rcpt = w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(signed.raw_transaction))
    assert rcpt.status == 1, f"tx reverted: {fn.fn_name}"
    return rcpt


async def _wait_for(client: AsyncClient, session_id: str, predicate, what: str, timeout: float = 30):
    deadline = time.time() + timeout
    body = None
    while time.time() < deadline:
        body = (await client.get("/session/status", params={"session_id": session_id})).json()
        if predicate(body):
            return body
        await asyncio.sleep(0.3)
    raise SystemExit(f"FAIL: timed out waiting for {what}; last status={body}")


async def _run_case(label: str, *, guest_settles: bool, w3, token, escrow, deployer, guest, host, settings):
    print(f"\n=== Case {label} ===")
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        app.state.chain._block_poll_seconds = 0.3
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://pi") as client:
            mac = "aa:bb:cc:dd:ee:" + ("b1" if guest_settles else "a1")
            nonce = str(uuid4())
            msg = build_session_start_message(
                guest_wallet=guest.address, host_wallet=host.address,
                mac_address=mac, quota_bytes=QUOTA, nonce=nonce,
            )
            sig = guest.sign_message(encode_defunct(text=msg)).signature.hex()
            resp = await client.post("/session/start", json={
                "guest_wallet_address": guest.address,
                "host_wallet_address": host.address,
                "mac_address": mac,
                "quota_bytes": QUOTA,
                "price_per_gb_wei": str(DEPOSIT),
                "nonce": nonce,
                "guest_signature": sig if sig.startswith("0x") else "0x" + sig,
            })
            assert resp.status_code in (200, 201), resp.text
            started = resp.json()
            sid, ref = started["session_id"], started["session_ref"]
            print(f"  session {sid} status={started['status']}")

            # Guest pays into escrow, exactly like the app.
            _send(w3, deployer, token.functions.mint(guest.address, Web3.to_wei(100, "ether")))
            _send(w3, guest, token.functions.approve(escrow.address, DEPOSIT))
            _send(w3, guest, escrow.functions.openSession(host.address, DEPOSIT, bytes.fromhex(ref[2:])))
            active = await _wait_for(client, sid, lambda b: b["status"] == "active", "listener admit")
            chain_sid = active["chain_session_id"]
            print(f"  OK  admitted after on-chain openSession (escrow session #{chain_sid})")

            # 1. periodic checkpoints + running cost
            b = await _wait_for(
                client, sid,
                lambda b: (b.get("checkpoint_bytes") or 0) > 0 and int(b.get("accrued_payment_wei") or 0) > 0,
                "periodic checkpoint",
            )
            first_cp = b["checkpoint_bytes"]
            b = await _wait_for(client, sid, lambda b: b["checkpoint_bytes"] > first_cp, "a later checkpoint")
            rec = app.state.store._sessions[__import__("uuid").UUID(sid)]
            print(f"  OK  checkpoints advance: {first_cp} -> {b['checkpoint_bytes']} bytes "
                  f"({rec.checkpoint_count} signed), accrued={int(b['accrued_payment_wei'])/1e18:.6f} STRT")
            assert "checkpoint_sig" not in b, "checkpoint signatures must not reach the guest"

            # Checkpoint signature is one the escrow would accept.
            onchain_hash = escrow.functions.receiptHash(chain_sid, rec.checkpoint_bytes, QUOTA).call()
            signer = Account.recover_message(encode_defunct(primitive=onchain_hash), signature=rec.checkpoint_sig)
            assert signer == host.address, f"checkpoint signed by {signer}, expected host"
            print("  OK  checkpoint signature verifies against the contract's receiptHash")

            host_before = token.functions.balanceOf(host.address).call()
            guest_before = token.functions.balanceOf(guest.address).call()

            stopped = (await client.post("/session/stop", json={"session_id": sid, "reason": "client_disconnect"})).json()
            used = stopped["settlement_bytes_consumed"]
            expected_pay = DEPOSIT * used // QUOTA
            print(f"  stopped: final receipt for {used} bytes -> host should get {expected_pay/1e18:.6f} STRT")

            if guest_settles:
                _send(w3, guest, escrow.functions.closeSession(
                    chain_sid, used, QUOTA, bytes.fromhex(stopped["host_settlement_sig"][2:])))
                print("  guest called closeSession inside the grace period")
                b = await _wait_for(client, sid, lambda b: b["settlement_status"] is not None,
                                    "router to notice", timeout=GRACE + 15)
                assert b["settlement_status"] == "closed_by_guest", b
                assert b["settlement_tx_hash"] is None, "router must not send its own tx"
                print("  OK  router recorded closed_by_guest and sent no transaction")
            else:
                t0 = time.time()
                b = await _wait_for(client, sid, lambda b: b["settlement_status"] is not None,
                                    "router settlement", timeout=GRACE + 30)
                assert b["settlement_status"] == "settled", b
                waited = time.time() - t0
                assert waited >= GRACE - 0.5, f"settled after {waited:.1f}s, before the grace period"
                rcpt = w3.eth.get_transaction_receipt(b["settlement_tx_hash"])
                tx = w3.eth.get_transaction(b["settlement_tx_hash"])
                assert rcpt.status == 1 and tx["from"] == host.address
                print(f"  OK  router sent closeSession itself after {waited:.1f}s "
                      f"(grace {GRACE}s) tx={b['settlement_tx_hash'][:18]}... from host wallet")

            session = escrow.functions.sessions(chain_sid).call()
            assert session[4] is True, "escrow session must be closed"
            host_gain = token.functions.balanceOf(host.address).call() - host_before
            guest_refund = token.functions.balanceOf(guest.address).call() - guest_before
            assert host_gain == expected_pay, (host_gain, expected_pay)
            assert guest_refund == DEPOSIT - expected_pay, (guest_refund, DEPOSIT - expected_pay)
            print(f"  OK  on-chain: host +{host_gain/1e18:.6f} STRT, guest refunded {guest_refund/1e18:.6f} STRT")
    print(f"=== PASS {label} ===")


async def main() -> None:
    print("STRATA Iteration 3 - host settlement E2E (real Hardhat chain)")
    w3 = _must_connect()
    if not ARTIFACT_TOKEN.exists():
        raise SystemExit("Compile contracts first: cd contracts && npx hardhat compile")
    token_addr, escrow_addr, deployer, _, _ = _deploy(w3)
    # Host = Hardhat account #2, guest = #1 (fresh wallets, not the deployer).
    host, guest = Account.from_key(HOST_KEY), Account.from_key(GUEST_KEY)
    token = w3.eth.contract(address=token_addr, abi=_load_abi(ARTIFACT_TOKEN))
    escrow = w3.eth.contract(address=escrow_addr, abi=_load_abi(ARTIFACT_ESCROW))

    Settings.model_config["env_file"] = None  # ignore host_node/.env
    settings = Settings(
        CHAIN_ENABLED=True,
        CHAIN_RPC_URL=RPC,
        CHAIN_ID=w3.eth.chain_id,
        SESSION_ESCROW_ADDRESS=escrow_addr,
        STRATA_TOKEN_ADDRESS=token_addr,
        HOST_WALLET_ADDRESS=host.address,
        HOST_SIGNING_PRIVATE_KEY=HOST_KEY,
        DEMO_MODE=True,  # 0 confirmations; laptop meter adds synthetic bytes
        ALLOW_CLIENT_MAC=True,
        MDNS_ENABLED=False,
        METER_TICK_SECONDS=0.2,
        SETTLEMENT_CHECKPOINT_SECONDS=0.5,
        SETTLE_POLL_SECONDS=0.5,
        SETTLE_GRACE_SECONDS=GRACE,
        LOG_LEVEL="WARNING",
    )
    common = dict(w3=w3, token=token, escrow=escrow, deployer=deployer, guest=guest,
                  host=host, settings=settings)
    await _run_case("A: guest walks away, router settles", guest_settles=False, **common)
    await _run_case("B: guest settles first", guest_settles=True, **common)
    print("\nALL HOST SETTLEMENT E2E CASES PASSED")


if __name__ == "__main__":
    asyncio.run(main())
