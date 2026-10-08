# Periodic micropayments — router side (Iteration 3)

## How payment works

```text
guest app                       router (host_node)                     SessionEscrow
─────────                       ──────────────────                     ─────────────
openSession(deposit) ───────────────────────────────────────────────▶ lock deposit
                                listener sees SessionOpened ◀────────── event
                                admit guest, start metering
                                every 60 s: sign checkpoint receipt
                                  (usage so far; kept on the router)
                                  guest sees accrued_payment_wei
session ends ──────────────────▶ sign final receipt → given to guest
closeSession(final receipt) ─── within 120 s grace ─────────────────▶ pay host, refund guest
            …or the guest does nothing:
                                after grace: router sends closeSession ▶ pay host, refund guest
```

- **Periodic checkpoints** (`SETTLEMENT_CHECKPOINT_SECONDS`, default 60):
  the router signs a receipt for the bytes used so far. It is exactly the
  receipt `closeSession` accepts. The guest sees the running cost
  (`accrued_payment_wei`, `checkpoint_bytes`, `checkpoint_at` in
  `GET /session/status`); the checkpoint signatures are **not** sent to the
  guest, because the contract has no receipt nonce and a guest holding a
  stream of receipts could settle with the oldest, cheapest one.
- **Router-driven settlement** (`HOST_AUTO_SETTLE`, default on): the guest has
  `SETTLE_GRACE_SECONDS` (120) to settle from the app. After that the router
  submits `closeSession` itself from the host wallet, so the host is paid even
  if the guest walks away. It checks on-chain first (no double close), never
  sends a second transaction while one is pending, retries up to
  `SETTLE_MAX_ATTEMPTS`, and with `PERSIST_SESSIONS=true` resumes after a
  reboot. States (`settlement_status`): `settled`, `closed_by_guest`, `failed`.
- **Dispute guard**: sessions running longer than `SESSION_MAX_AGE_SECONDS`
  (23 h) are stopped and settled before the guest may `disputeSession` (24 h),
  which would refund them everything.
- **Metering fixes** this relies on: the host node enables
  `net.ipv4.ip_forward` and `net.netfilter.nf_conntrack_acct` at startup, and
  the meter keeps bytes from connections that have closed. On a Pi random
  demo bytes are never added, even with `DEMO_MODE=true`.

The host wallet (`HOST_WALLET_ADDRESS`) needs native gas (POL on Amoy) to
send `closeSession`.

### Limits of the current contract

`SessionEscrow` locks once and settles once, so value moves on-chain only at
the end; checkpoints are the periodic part. Real periodic on-chain transfers
(and closing the old-receipt hole) need a contract change owned by the
contracts work: a `claim(sessionId, cumulativeBytes, quota, sig)` that pays
the host the increment since the last claim and rejects non-increasing
`cumulativeBytes`.

---

## Manual test

### Test 1 — local chain, no Pi (≈ 2 min)

Real contracts on a local Hardhat chain, real host node code, driven over HTTP
like the Flutter app.

```bash
# terminal 1
cd contracts && npx hardhat node
# terminal 2 (repo root)
STRATA_NFT_FAKE=true STRATA_WG_FAKE=true host_node/.venv/bin/python host_node/scripts/iter3_host_settlement_e2e.py
```

On Windows use `host_node\.venv\Scripts\python.exe`. If `npx hardhat` is not
found, run `node node_modules/hardhat/internal/cli/bootstrap.js node` inside
`contracts/`.

Expected ending: `ALL HOST SETTLEMENT E2E CASES PASSED`, with

```text
=== Case A: guest walks away, router settles ===
  OK  checkpoints advance: … (N signed), accrued=… STRT
  OK  checkpoint signature verifies against the contract's receiptHash
  OK  router sent closeSession itself after 3.xs (grace 3.0s) … from host wallet
  OK  on-chain: host +X STRT, guest refunded 5-X STRT
=== Case B: guest settles first ===
  OK  router recorded closed_by_guest and sent no transaction
```

### Test 2 — on the Pi (metering + forwarding)

```bash
cd host_node && sudo .venv/bin/strata-host        # as root
```

| # | Check | Expect |
|---|-------|--------|
| 1 | startup log | `kernel.prereq_ok` for `net.ipv4.ip_forward` and `net.netfilter.nf_conntrack_acct` |
| 2 | `sysctl net.ipv4.ip_forward net.netfilter.nf_conntrack_acct` | both `= 1` |
| 3 | admitted phone downloads a known file (e.g. 50 MB), then `curl localhost:8080/session/status?mac_address=<mac>` | `bytes_used` ≈ file size (slightly more for headers), and it does **not** drop when the download finishes |
| 4 | leave the phone idle for a minute | `bytes_used` barely moves (no random demo bytes) |

### Test 3 — on the Pi with the full app flow (Amoy or local chain)

Pay for a session from the app, browse for a couple of minutes, then:

| # | Do | Expect |
|---|----|--------|
| 1 | `curl localhost:8080/session/status?mac_address=<mac>` | `checkpoint_bytes` and `accrued_payment_wei` rising every ~60 s |
| 2 | `curl localhost:8080/host/sessions` | `checkpoint_count` rising |
| 3 | stop the session in the app but **don't** press settle; wait ~2.5 min | `settlement_status: "settled"`, `settlement_tx_hash` set; the tx on the explorer is from the host wallet |
| 4 | another session: stop **and** settle from the app within 2 min | `settlement_status: "closed_by_guest"`, no router tx |
