# Amoy deployment & funding (Iteration 3)

## Prerequisites

1. Copy `contracts/.env.example` → `contracts/.env`
2. Set `DEPLOYER_PRIVATE_KEY` (funded with Amoy MATIC from https://faucet.polygon.technology)
3. Optional: `POLYGONSCAN_API_KEY` for verification

**Never commit `.env` or private keys.**

## Deploy

```bash
just deploy-amoy
# writes contracts/deployments/amoy.json + contracts/abi/
just sync-abi
just print-deploy-env network=amoy
```

## Host configuration

```text
CHAIN_ENABLED=true
CHAIN_ID=80002
CHAIN_RPC_URL=wss://polygon-amoy-bor-rpc.publicnode.com
# or leave CHAIN_RPC_URL empty and set AMOY_WSS_URL
STRATA_TOKEN_ADDRESS=<from amoy.json>
SESSION_ESCROW_ADDRESS=<from amoy.json>
HOST_WALLET_ADDRESS=<host EOA>
HOST_SIGNING_PRIVATE_KEY=<same EOA>
CHAIN_CONFIRMATIONS=3   # DEMO_MODE=true forces 0
```

Mismatch between signing key and `HOST_WALLET_ADDRESS` → host **refuses to boot**.

## Flutter

```bash
flutter run \
  --dart-define=STRATA_TOKEN=0x... \
  --dart-define=SESSION_ESCROW=0x... \
  --dart-define=CHAIN_ID=80002 \
  --dart-define=RPC_URL=https://rpc-amoy.polygon.technology
```

## Funding guests

- MATIC: Polygon faucet
- STRT: Wallet screen → **Claim test STRT** (calls on-chain `faucet()`, demo-only), or:

```bash
cd contracts
TARGET=0xGuest AMOUNT=1000 npx hardhat run scripts/faucet.ts --network amoy
```

## Local Hardhat (no Amoy key required)

```bash
# Terminal 1
cd contracts && npx hardhat node

# Terminal 2
just iter3-local-demo
```

This runs real `openSession` txs against HTTP `http://127.0.0.1:8545` and proves
ChainListener HTTP polling + `_promote_pending` + settlement.

## Reconciliation

```bash
just reconcile base_url=http://127.0.0.1:8080 token=local-dev-token
```

Lookback-based `reconcile()` is sufficient for the FYP; persistent
`lastProcessedBlock` is optional technical debt (see host_node README).
