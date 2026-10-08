# STRATA Iteration 3 — Demo Topology (fill in after deploy; never put private keys here)

| Field | Value |
|-------|-------|
| Pi IP (guest gateway) | `192.168.50.1` |
| SSID | `STRATA-Pi-01` (or `HOST_SSID` / AP SSID) |
| Pi host wallet | `HOST_WALLET_ADDRESS` from host `.env` |
| STRATA token address | from `contracts/deployments/<network>.json` → `strataToken` |
| SessionEscrow address | from `contracts/deployments/<network>.json` → `sessionEscrow` |
| Chain ID | `80002` (Amoy) or `31337` (Hardhat) |
| RPC | `https://rpc-amoy.polygon.technology` (or Hardhat `http://127.0.0.1:8545`) |
| WSS | `wss://polygon-amoy-bor-rpc.publicnode.com` (host `AMOY_WSS_URL`) |
| WG VPS IP | *(operator)* egress public IP of the WireGuard VPS |
| WG endpoint | `WG_PEER_ENDPOINT` e.g. `vps.example.com:51820` |
| Flutter API URL | mDNS / captive pin / `http://192.168.50.1:8080` |

## Payment model (Iteration 3)

**SessionEscrow** (lock funds → active session → usage-based settlement → close):

1. Guest `approve` STRT → `openSession(host, amount, sessionRef)`
2. Host `ChainListener` sees `SessionOpened` → confirmations → admit MAC
3. Real metering (conntrack) while active
4. Guest/host stop → host EIP-191 receipt → guest `closeSession` → proportional settle

This is **not** an L2 streaming payment channel.

## Quick start

```bash
# Local Hardhat (no Amoy key needed) — proves real SessionOpened → listener
cd contracts && npx hardhat node   # terminal 1
just iter3-local-demo              # terminal 2

# Amoy (requires contracts/.env DEPLOYER_PRIVATE_KEY)
just deploy-amoy && just sync-abi && just print-deploy-env network=amoy
# see docs/AMOY_SETUP.md
```

## Admin reconcile

With `ADMIN_TOKEN` set:

```bash
curl -X POST http://192.168.50.1:8080/admin/reconcile \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```
