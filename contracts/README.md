# STRATA Contracts (Phase E)

This workspace holds the Solidity contracts that make on-chain payment the
authoritative trigger for admitting a guest's MAC to the host node firewall.

Two contracts:

- **`StrataToken.sol`** — ERC-20 (`STRT`, 18 decimals) with a rate-limited
  public faucet (1000 STRT / 24h) and an owner-gated `mint`.
- **`SessionEscrow.sol`** — escrow for a single Wi-Fi session. The guest
  approves and calls `openSession`, the host node listens for the
  `SessionOpened` event filtered by `host`, and admits the MAC. At the end
  of the session anyone can submit a host-signed receipt to settle.

Target chain: **Polygon Amoy** (chainId `80002`). No mainnet deployment is in
scope.

---

## Quickstart

```bash
cd contracts
npm install
cp .env.example .env       # then fill DEPLOYER_PRIVATE_KEY + POLYGONSCAN_API_KEY
npx hardhat compile
npx hardhat test
npx hardhat coverage
```

To deploy to Amoy:

```bash
npx hardhat run scripts/deploy.ts --network amoy
```

Outputs `deployments/amoy.json` and ABI snapshots in `abi/`. The script
prints the next steps you need to run for Flutter + host node wire-up.

To verify on Amoyscan (optional):

```bash
npx hardhat run scripts/verify.ts --network amoy
```

To run the end-to-end demo (open → close, on testnet or local hardhat):

```bash
# Local — fastest
npm run demo:local

# Against the deployed contracts on Amoy (needs deployments/amoy.json)
npm run demo:amoy
```

---

## Deploy → Wire-up handshake

Phase E only finishes when both the Flutter app and the Python host node
know the deployed addresses. After running `scripts/deploy.ts`:

1. **Flutter** — open `lib/core/constants/chain_config.dart` and set:

   ```dart
   static const String? strataTokenContract  = "0x...";
   static const String? sessionEscrowContract = "0x...";
   ```

2. **Host node** — add to `host_node/.env`:

   ```dotenv
   CHAIN_ENABLED=true
   STRATA_TOKEN_ADDRESS=0x...
   SESSION_ESCROW_ADDRESS=0x...
   AMOY_WSS_URL=wss://polygon-amoy-bor-rpc.publicnode.com
   HOST_WALLET_ADDRESS=0x...   # the host EOA the Flutter app pays to
   ```

3. (optional) Verify on Amoyscan and double-check both addresses match
   `deployments/amoy.json`.

Once those three are set, restart `strata-host`. You should see:

```
chain.listener_started  wss=wss://...  escrow=0x...  host=0x...
```

When the Flutter app finishes its on-chain `openSession`, the host node
will log `chain.session_authorized` and admit the MAC.

---

## Receipt format (off-chain ↔ on-chain contract)

The host signs an EIP-191 personal_sign over:

```
keccak256(abi.encode(
  "STRATA-SESSION-RECEIPT-V1",
  chainId,
  sessionEscrowAddress,
  sessionId,
  bytesConsumed,
  quotaBytes
))
```

Both `chainId` and the contract address are hashed in, so the same
signature cannot be replayed across chains or against a sibling escrow
contract. `SessionEscrow.receiptHash(sessionId, bytesConsumed, quotaBytes)`
returns the inner `keccak256(...)` for off-chain signers to use.

---

## Out of scope (post-FYP)

The following deliberately *do not* exist in this phase:

- Streaming / per-second micropayments.
- L2 payment channels.
- Upgradeable proxies (UUPS / Transparent).
- Slashing or staking economics.
- A reputation / rating contract.
- Multi-host or multi-guest sessions.
- Mainnet deployment of any kind.
