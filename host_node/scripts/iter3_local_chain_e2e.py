#!/usr/bin/env python3
"""Iteration 3 — local Hardhat chain listener E2E (no Raspberry Pi).

Proves REAL on-chain SessionOpened events (not fabricated) drive:

  openSession → ChainListener (HTTP poll) → confirmations → authorize
  → stop + EIP-191 receipt → closeSession settlement

Prerequisites:
  Terminal A:  cd contracts && npx hardhat node
  Then:        PYTHONPATH=src python host_node/scripts/iter3_local_chain_e2e.py

Or use:        just iter3-local-demo
"""

from __future__ import annotations

import asyncio
import json
import sys
import time
from pathlib import Path
from uuid import uuid4

from eth_account import Account
from web3 import Web3

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "host_node" / "src"))

from strata_host.chain_real import ChainListener  # noqa: E402
from strata_host.enforcer import EnforcerService  # noqa: E402
from strata_host.firewall.nft_set import NftSet  # noqa: E402
from strata_host.models import StartSessionRequest  # noqa: E402
from strata_host.settlement import sign_settlement  # noqa: E402
from strata_host.store import SessionStore  # noqa: E402

RPC = "http://127.0.0.1:8545"
# Hardhat default accounts
DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
GUEST_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
HOST_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"

ARTIFACT_ESCROW = (
    ROOT / "contracts" / "artifacts" / "contracts" / "SessionEscrow.sol" / "SessionEscrow.json"
)
ARTIFACT_TOKEN = (
    ROOT / "contracts" / "artifacts" / "contracts" / "StrataToken.sol" / "StrataToken.json"
)


def _load_abi(path: Path) -> list:
    return json.loads(path.read_text())["abi"]


def _must_connect() -> Web3:
    w3 = Web3(Web3.HTTPProvider(RPC, request_kwargs={"timeout": 5}))
    if not w3.is_connected():
        raise SystemExit(
            f"Cannot reach {RPC}. Start Hardhat first:\n"
            "  cd contracts && npx hardhat node"
        )
    return w3


def _deploy(w3: Web3) -> tuple[str, str, Account, Account, Account]:
    deployer = Account.from_key(DEPLOYER_KEY)
    guest = Account.from_key(GUEST_KEY)
    host = Account.from_key(HOST_KEY)
    token_abi = _load_abi(ARTIFACT_TOKEN)
    escrow_abi = _load_abi(ARTIFACT_ESCROW)
    token_bin = json.loads(ARTIFACT_TOKEN.read_text())["bytecode"]
    escrow_bin = json.loads(ARTIFACT_ESCROW.read_text())["bytecode"]

    Token = w3.eth.contract(abi=token_abi, bytecode=token_bin)
    tx = Token.constructor(Web3.to_wei(10_000_000, "ether"), deployer.address).build_transaction(
        {
            "from": deployer.address,
            "nonce": w3.eth.get_transaction_count(deployer.address),
            "gas": 5_000_000,
            "gasPrice": w3.eth.gas_price,
            "chainId": w3.eth.chain_id,
        }
    )
    signed = deployer.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(signed.raw_transaction)
    rcpt = w3.eth.wait_for_transaction_receipt(h)
    token_addr = rcpt.contractAddress
    print(f"  StrataToken @ {token_addr}")

    Escrow = w3.eth.contract(abi=escrow_abi, bytecode=escrow_bin)
    tx = Escrow.constructor(token_addr, deployer.address).build_transaction(
        {
            "from": deployer.address,
            "nonce": w3.eth.get_transaction_count(deployer.address),
            "gas": 5_000_000,
            "gasPrice": w3.eth.gas_price,
            "chainId": w3.eth.chain_id,
        }
    )
    signed = deployer.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(signed.raw_transaction)
    rcpt = w3.eth.wait_for_transaction_receipt(h)
    escrow_addr = rcpt.contractAddress
    print(f"  SessionEscrow @ {escrow_addr}")
    return token_addr, escrow_addr, deployer, guest, host


def _mine(w3: Web3, n: int) -> None:
    w3.provider.make_request("hardhat_mine", [hex(n)])


async def _run_case(
    *,
    label: str,
    confirmations: int,
    w3: Web3,
    token_addr: str,
    escrow_addr: str,
    deployer: Account,
    guest: Account,
    host: Account,
    token_abi: list,
    escrow_abi: list,
) -> None:
    print(f"\n=== Case: {label} (CHAIN_CONFIRMATIONS={confirmations}) ===")
    store = SessionStore(require_payment=True)
    enforcer = EnforcerService(NftSet(force_fake=True))
    await enforcer.start()

    nonce = uuid4()
    mac = "aa:bb:cc:dd:ee:f1"
    record = await store.create_session(
        StartSessionRequest(
            guest_wallet_address=guest.address,
            host_wallet_address=host.address,
            mac_address=mac,
            quota_bytes=5 * 1024 * 1024 * 1024,
            guest_signature="0x" + "ab" * 65,
            nonce=nonce,
            price_per_gb_wei="1000000000000000000",
        ),
        ttl_seconds=3600,
    )
    assert record.status == "pending_payment"
    session_ref = record.session_ref
    print(f"  local session pending_payment ref={session_ref}")

    listener = ChainListener(
        wss_url=RPC,
        session_escrow_address=escrow_addr,
        host_address=host.address,
        store=store,
        enforcer=enforcer,
        session_escrow_abi=escrow_abi,
        confirmations=confirmations,
    )
    listener._block_poll_seconds = 0.4
    await listener.start()
    await asyncio.sleep(0.8)  # let HTTP poll arm

    token = w3.eth.contract(address=token_addr, abi=token_abi)
    escrow = w3.eth.contract(address=escrow_addr, abi=escrow_abi)
    amount = Web3.to_wei(5, "ether")

    # Mint + approve + openSession (real txs)
    for build in (
        lambda: token.functions.mint(guest.address, Web3.to_wei(1000, "ether")).build_transaction(
            {
                "from": deployer.address,
                "nonce": w3.eth.get_transaction_count(deployer.address),
                "gas": 300_000,
                "gasPrice": w3.eth.gas_price,
                "chainId": w3.eth.chain_id,
            }
        ),
    ):
        signed = deployer.sign_transaction(build())
        w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(signed.raw_transaction))

    tx = token.functions.approve(escrow_addr, amount).build_transaction(
        {
            "from": guest.address,
            "nonce": w3.eth.get_transaction_count(guest.address),
            "gas": 100_000,
            "gasPrice": w3.eth.gas_price,
            "chainId": w3.eth.chain_id,
        }
    )
    signed = guest.sign_transaction(tx)
    w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(signed.raw_transaction))

    ref_bytes = bytes.fromhex(session_ref.removeprefix("0x"))
    tx = escrow.functions.openSession(host.address, amount, ref_bytes).build_transaction(
        {
            "from": guest.address,
            "nonce": w3.eth.get_transaction_count(guest.address),
            "gas": 400_000,
            "gasPrice": w3.eth.gas_price,
            "chainId": w3.eth.chain_id,
        }
    )
    signed = guest.sign_transaction(tx)
    open_rcpt = w3.eth.wait_for_transaction_receipt(
        w3.eth.send_raw_transaction(signed.raw_transaction)
    )
    print(f"  openSession tx={open_rcpt.transactionHash.hex()} block={open_rcpt.blockNumber}")

    if confirmations > 0:
        # Event should sit in pending until tip advances.
        deadline = time.time() + 8
        while time.time() < deadline:
            refreshed = await store.get_by_ref(session_ref)
            if refreshed and refreshed.status == "pending_payment" and listener._pending:
                print("  OK  event stashed pending confirmations")
                break
            if refreshed and refreshed.status == "active":
                break
            await asyncio.sleep(0.3)
        _mine(w3, confirmations + 1)
        print(f"  mined {confirmations + 1} blocks for promotion")

    # Wait for authorize
    deadline = time.time() + 20
    while time.time() < deadline:
        refreshed = await store.get_by_ref(session_ref)
        if refreshed and refreshed.status == "active":
            print(f"  OK  chain.session_authorized status=active mac_admitted={mac in enforcer.current_macs()}")
            break
        await asyncio.sleep(0.4)
    else:
        await listener.stop()
        await enforcer.stop()
        raise SystemExit(f"FAIL: session never became active ({label})")

    refreshed = await store.get_by_ref(session_ref)
    assert refreshed is not None
    chain_sid = refreshed.chain_session_id
    assert chain_sid is not None

    # Idempotent reconcile must not double-admit
    late = await listener.reconcile(lookback_blocks=64)
    print(f"  reconcile late_admits={late} (expect 0 — already active)")

    # Stop + host receipt + closeSession
    await store.stop_session(refreshed.session_id, reason="guest_stopped")
    consumed = 3 * 1024 * 1024 * 1024
    quota = 5 * 1024 * 1024 * 1024
    _rh, sig = sign_settlement(
        private_key_hex=host.key.hex(),
        chain_id=w3.eth.chain_id,
        escrow_address=escrow_addr,
        session_id=int(chain_sid),
        bytes_consumed=consumed,
        quota_bytes=quota,
    )
    tx = escrow.functions.closeSession(
        int(chain_sid), consumed, quota, bytes.fromhex(sig[2:])
    ).build_transaction(
        {
            "from": guest.address,
            "nonce": w3.eth.get_transaction_count(guest.address),
            "gas": 400_000,
            "gasPrice": w3.eth.gas_price,
            "chainId": w3.eth.chain_id,
        }
    )
    signed = guest.sign_transaction(tx)
    close_rcpt = w3.eth.wait_for_transaction_receipt(
        w3.eth.send_raw_transaction(signed.raw_transaction)
    )
    print(f"  OK  closeSession settled tx={close_rcpt.transactionHash.hex()}")

    await listener.stop()
    await enforcer.stop()
    print(f"=== PASS {label} ===")


async def main() -> None:
    print("STRATA Iteration 3 — local Hardhat listener E2E")
    w3 = _must_connect()
    print(f"connected chainId={w3.eth.chain_id} tip={w3.eth.block_number}")

    # Prefer artifacts from compile; deploy fresh each run so we own the escrow.
    if not ARTIFACT_TOKEN.exists():
        raise SystemExit("Compile contracts first: cd contracts && npx hardhat compile")

    token_abi = _load_abi(ARTIFACT_TOKEN)
    escrow_abi = _load_abi(ARTIFACT_ESCROW)
    print("\n→ Deploying fresh contracts on localhost…")
    token_addr, escrow_addr, deployer, guest, host = _deploy(w3)

    await _run_case(
        label="zero_confirmations",
        confirmations=0,
        w3=w3,
        token_addr=token_addr,
        escrow_addr=escrow_addr,
        deployer=deployer,
        guest=guest,
        host=host,
        token_abi=token_abi,
        escrow_abi=escrow_abi,
    )
    await _run_case(
        label="confirmations_gt_0",
        confirmations=2,
        w3=w3,
        token_addr=token_addr,
        escrow_addr=escrow_addr,
        deployer=deployer,
        guest=guest,
        host=host,
        token_abi=token_abi,
        escrow_abi=escrow_abi,
    )
    print("\nALL LOCAL CHAIN E2E CASES PASSED")
    print("Amoy: set DEPLOYER_PRIVATE_KEY in contracts/.env then: just deploy-amoy")


if __name__ == "__main__":
    asyncio.run(main())
