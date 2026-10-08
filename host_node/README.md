# STRATA Host Node

The STRATA host node is the FastAPI service that lives on the Raspberry Pi
**behind** the guest Wi-Fi access point. It owns the session lifecycle, runs a
demo (or Linux conntrack) meter, and (when chain mode is enabled) admits guest
MACs to the firewall when their on-chain payment is observed.

## Wireless AP (Iteration 1) — required on hardware

The host node **does not** configure `hostapd`. Bring up the AP first:

See **[`ap/README.md`](ap/README.md)** (`just ap-setup` / `just ap-verify`).

Defaults that must stay aligned:

| Setting | Value |
|---------|-------|
| Guest iface | `wlan0` (`GUEST_IFACE` == `AP_IFACE`) |
| Guest gateway | `192.168.50.1/24` |
| API | `0.0.0.0:8080` (reachable by guests as `http://192.168.50.1:8080`) |

## Iteration 2 — captive portal handshake & real metering

Guest path on the Pi (`CHAIN_ENABLED=false`, `DEMO_MODE=false`, `ALLOW_CLIENT_MAC=false`):

1. Guest joins the STRATA AP and is redirected to `GET /` (nftables).
2. `GET /portal/client` returns the ARP-resolved MAC for the guest IP.
3. Flutter (or `POST /portal/handshake`) EIP-191-signs the canonical
   `STRATA-SESSION-START` message **including that MAC**.
4. `POST /session/start` re-resolves MAC from ARP, verifies the signature
   recovers the claimed guest wallet, creates the session, and
   `EnforcerService.admit`s the MAC.
5. Metering reads `/proc/net/nf_conntrack` per MAC on each tick (interval
   accounting — not packet-real-time). Random demo bytes are **not** used
   when `DEMO_MODE=false`.

Lab/ASGI tests may set `ALLOW_CLIENT_MAC=true` when no ARP table exists.

**Hardware verification (on the Pi):**

```bash
sudo bash host_node/scripts/verify_iter2_pi.sh http://192.168.50.1:8080
```

Then complete the phone/Flutter manual steps printed by the script.

**Contracts:** `StrataToken` / `SessionEscrow` remain draft/compile-tested.
Live Amoy wiring is **Iteration 3** — keep `CHAIN_ENABLED=false` for Iter 2 demos.

## What Is Implemented

- FastAPI app with lifespan startup/shutdown
- In-memory `SessionStore` with lock protection (Phase E adds
  `pending_payment` status, sessionRef indexing, and `mark_paid`)
- Demo metering loop (`MeterService`) that periodically increments usage
- `EnforcerService` with queue-serialized admit/disconnect into the
  `strata_authed` nftables set (fake mode off-Linux / off-root)
- **Phase F** — `firewall/` package with the production-shape nftables
  ruleset (LAN isolation, per-MAC 50 Mbit/s rate limiting, conntrack
  hygiene, WAN drop counter) and a `WireGuardManager` that brings a
  wg0 exit tunnel up/down. Off-Linux / off-root the manager auto-falls
  into a "fake mode" so dev laptops still start cleanly.
- **Phase E** — `ChainListener` (web3.py async) that subscribes to
  `SessionEscrow.SessionOpened` events on Polygon Amoy and admits the
  matching MAC. When `CHAIN_ENABLED` is false, the Phase A `ChainService`
  stub takes its place and logs `chain.listener_disabled`.
- Structured logging with `structlog`
- Config via environment variables (`pydantic-settings`)
- Error envelopes for domain and internal failures
- Tests with `pytest`, `pytest-asyncio`, `httpx.AsyncClient` (covers both
  Phase A and Phase E flows + a unit test for the listener)
- Optional SQLite persistence for sessions / chatroom (off by default)
- LAN SOS chatroom WebSocket + mDNS discovery advertiser

## Project Structure

```text
host_node/
  pyproject.toml
  .env.example
  README.md
  ap/                     # Iteration 1 — hostapd + dnsmasq AP
    README.md
    env.example
    templates/
    scripts/
  src/strata_host/
    main.py
    config.py
    logging_setup.py
    models.py
    errors.py
    store.py
    meter.py
    enforcer.py
    chain.py            # Phase A no-op stub
    chain_real.py       # Phase E web3.py listener
    firewall/           # Phase F
      __init__.py
      strata.nft.j2     # Phase B + F nftables ruleset
      nft_renderer.py
      wireguard.py
      wireguard.conf.j2
      netns.py
      README.md
    captive_portal/     # deprecation shim → strata_host.firewall
      __init__.py
      nft_loader.py
    routes/
      health.py
      sessions.py
      metering.py
  tests/
    conftest.py
    test_health.py
    test_sessions.py
    test_chain_real.py
    test_metering.py
    firewall/                       # Phase F fast tests
      test_strata_nft_render.py
      test_strata_nft_syntax.py
      test_wireguard_render.py
      integration/                  # Phase F slow tests (Linux + root)
        conftest.py
        test_isolation.py
        test_rate_limit.py
        test_unsolicited_drop.py
```

## Setup

1. Create and activate a virtual environment:

   ```bash
   python3.11 -m venv .venv
   source .venv/bin/activate
   ```

2. Install package + dev dependencies:

   ```bash
   pip install -e ".[dev]"
   ```

3. Create local env file:

   ```bash
   cp .env.example .env
   ```

4. Start API:

   ```bash
   strata-host
   ```

   Or:

   ```bash
   uvicorn strata_host.main:app --host 0.0.0.0 --port 8080
   ```

## Environment Variables

- `HOST` (default `0.0.0.0`)
- `PORT` (default `8080`)
- `LOG_LEVEL` (default `INFO`)
- `DEMO_MODE` (default `true`)
- `SESSION_DEFAULT_TTL_SECONDS` (default `3600`)
- `METER_TICK_SECONDS` (default `2.0`)
- `ALLOWED_ORIGINS` (JSON list, default `["*"]`)

**Phase E — on-chain settlement:**

- `CHAIN_ENABLED` (default `false`) — master switch.
- `AMOY_WSS_URL` (default `wss://polygon-amoy-bor-rpc.publicnode.com`)
- `SESSION_ESCROW_ADDRESS` — set after `cd contracts && npm run deploy:amoy`.
- `STRATA_TOKEN_ADDRESS` — same.
- `HOST_WALLET_ADDRESS` — the host EOA the Flutter app pays. The chain
  listener filters `SessionOpened` events server-side by this `host` topic.

When `CHAIN_ENABLED=true` and both addresses are set:

1. Sessions created via `POST /session/start` start in status
   `pending_payment` (no MAC admit yet).
2. The chain listener subscribes to Polygon Amoy via WSS and waits for
   `SessionOpened(_, _, host=HOST_WALLET_ADDRESS, ...)`.
3. On a matching event, it calls `EnforcerService.admit(mac)` and flips
   the local session to `active`.

Look for these log lines:

- `chain.listener_started`     – listener is up
- `chain.subscription_active`  – WSS subscription is live
- `chain.session_authorized`   – guest paid → MAC admitted
- `chain.subscription_failed`  – transient WSS error (auto-reconnects with
  exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s)

## API Contract

- `GET /health`
- `GET /version`
- `POST /session/start`
- `POST /session/stop`
- `GET /session/status?session_id=<uuid>` or `?mac_address=<mac>`
- `POST /session/{session_id}/payment` — Phase E hint: `{ "tx_hash": "0x..." }`
- `GET /metering/{mac}`

`/session/start` body (Phase E):

```json
{
  "guest_wallet_address": "0x...",
  "host_wallet_address":  "0x...",
  "mac_address":          "aa:bb:cc:dd:ee:ff",
  "quota_bytes":          5368709120,
  "price_per_gb_wei":     "1000000000000000",
  "nonce":                "11111111-2222-4333-8444-555555555555",
  "guest_signature":      "0xabc123",
  "tx_hash":              null
}
```

`/session/start` response (Phase E):

```json
{
  "session_id":     "...",
  "status":         "pending_payment",
  "session_ref":    "0x000000000000000000000000000000004f...",
  "tx_hash":        null,
  "chain_session_id": null,
  ...
}
```

The Flutter app passes `session_ref` to `SessionEscrow.openSession(...)`.
The chain listener uses the same ref to match the `SessionOpened` event
back to a local session.

## Phase F — Firewall & Egress Tunnel

The `strata_host.firewall` package owns the real nftables ruleset and the
WireGuard exit tunnel. The captive portal's old import path
(`strata_host.captive_portal.nft_loader`) is now a shim that emits a
`DeprecationWarning` and re-exports the new public API.

### What the ruleset enforces

| Layer       | Rule                                            | Why |
|-------------|-------------------------------------------------|-----|
| forward     | `ct state invalid drop`                         | drop bad/forged packets pre-fast-path |
| forward     | `ct state {established, related} accept`        | fast path for return traffic |
| forward     | `ip[v6] daddr @strata_lan_v[46] drop`           | LAN isolation — even authed guests can't pivot |
| forward     | per-guest dynamic sets `strata_pmac` (up) + `strata_pdown` (down) @ 6250 KB/s drop | 50 Mbit/s ceiling per guest, each way |
| forward     | `oifname { wan, wg0 } accept` (authed only)     | egress allowlist |
| forward     | `iifname wan ct state new drop`                 | unsolicited inbound counter |
| postrouting | `oifname wg0 masquerade` (when WG_ENABLED=true) | route through team VPS |
| postrouting | `oifname wan masquerade`                        | residential fallback (always on) |
| input       | `icmp echo-request limit rate 20/second`        | defeat ping-flood CPU pinning |

### Required system packages

On the Pi (and on any Linux dev box that wants to run the integration
tests):

```bash
sudo apt-get install -y nftables wireguard-tools iproute2 iperf3
```

`iperf3` and `nc` are only needed for the integration tests.

### WireGuard keypair

The keypair lives at `WG_PRIVATE_KEY_PATH` (default
`/etc/strata/wg0.key`). On first start the host node generates a fresh
keypair, writes the private half with mode `0o600`, and prints the
public key under the `wg.keypair_loaded` log line. **Hand the printed
public key to the team operator** — they need it to allow your peer on
the team VPS, and they'll hand back a `WG_PEER_PUBLIC_KEY` and
`WG_PEER_ENDPOINT` for you to drop into `.env`.

### Flipping WG_ENABLED on

1. `WG_ENABLED=true`
2. Set `WG_PEER_PUBLIC_KEY` and `WG_PEER_ENDPOINT` from the operator.
3. Restart `strata-host`.
4. Verify with:
   ```bash
   sudo wg show wg0
   sudo nft list ruleset | grep wg0
   ```
   The ruleset should now show the `oifname "wg0" masquerade` clause.
5. From a guest device after auth, `curl -s https://api.ipify.org`
   should return the team VPS's public IP, NOT the Pi's residential IP.

To roll back: `WG_ENABLED=false` + restart. Egress falls back to
`WAN_IFACE`.

### Running the integration tests on the Pi

The fast tests are part of the default `pytest -q` and run anywhere.
The integration tests need real netns + nft + iperf3, so they're
gated:

```bash
sudo pytest -q -m integration host_node/tests/firewall/integration
```

Off-Linux or off-root, the suite auto-skips with a clear reason.

### Design decisions — Phase F

- **subprocess over pyroute2.** `nft_set.py` (Phase B) already shells
  out to `nft`, and `wg-quick`/`ip` are the canonical operator-facing
  tools. Failure modes (rc + stderr) match what an admin sees at the
  shell, which beats deciphering pyroute2 exceptions when something
  goes sideways at 2am.
- **Dynamic-set rate limiting over `hashlimit`.** Per-guest buckets live
  in dynamic sets filled by `update @set { key limit rate over … }`
  (a standalone `meter NAME { … }` declaration is not valid nft and made
  the whole ruleset fail to load). Upload is keyed by MAC, download by
  IP (the destination MAC isn't known in the forward hook). The rules
  sit *before* the established fast-path; after it they only ever saw a
  connection's first packet. The 30 s timeout reclaims idle buckets.
- **Kill switch by default when WireGuard is on.** Guests are
  policy-routed into wg0 and may only leave through it; if the tunnel
  drops they are blocked rather than leaking out of the residential IP.
  `WG_FALLBACK_TO_WAN=true` restores the old "fall back to wan_iface"
  behaviour. See `docs/WIREGUARD_VPS.md`.
- **No DNS filtering yet.** Tracked as a post-FYP TODO; the right
  next step is `dnscrypt-proxy` plus a blocklist (`oisd`, `stevenblack`),
  not an in-firewall regex matcher.
- **No XDP/BPF metering.** Out of scope; nft rate limiting handles 50 Mbit/s
  per MAC at the kind of guest counts a single Pi serves without
  measurable CPU impact.

## Run Tests

Fast suite (no root, no Linux required):

```bash
pytest -q
# or scope to firewall:
pytest -q -m "not integration" tests/firewall
```

Integration suite (Linux + root + nft + iperf3 + nc):

```bash
sudo pytest -q -m integration tests/firewall/integration
```

After the integration suite finishes, `ip netns list` should be empty —
the harness tears down its veth pair and namespace on every test exit
even when the test fails.

## Iteration 3 — SessionEscrow payment model

**Official payment model:** lock funds → active session → usage-based
settlement → `closeSession`. This is **not** an L2 streaming channel.

With `CHAIN_ENABLED=true` (and addresses + signing key set — the process
**refuses to boot** if misconfigured):

1. `POST /session/start` creates `pending_payment` (no nft admit yet).
2. Guest `approve` + `SessionEscrow.openSession(sessionRef)`.
3. `ChainListener` receives `SessionOpened`, waits `CHAIN_CONFIRMATIONS`
   blocks (a live block-watcher calls `_promote_pending`), then
   `mark_paid` + `EnforcerService.admit`.
4. Metering runs; stop signs an EIP-191 usage receipt when
   `HOST_SIGNING_PRIVATE_KEY` is set.
5. Guest submits `closeSession` with that receipt.

**Startup reconcile:** `ChainListener.reconcile()` scans recent blocks on
boot. Operators can also `POST /admin/reconcile` with `ADMIN_TOKEN`.

**Checkpointing:** the FYP prototype uses `reconcile(lookback_blocks=1024)`
instead of a persistent `lastProcessedBlock`. Long outages beyond the
lookback window need a manual reconcile with a larger lookback or a
redeploy — documented limitation, not a silent failure.

### WireGuard rollback

If the exit tunnel misbehaves: set `WG_ENABLED=false` and restart the
host node. Postrouting returns to normal WAN masquerade. Do not leave
`WG_ENABLED=true` without `WG_PEER_*` — boot validation rejects that.
