# STRATA: Decentralized Peer-to-Peer Bandwidth Sharing

**STRATA** is a decentralized platform that enables individuals and businesses to share their unused internet bandwidth with nearby users. By leveraging blockchain technology for secure micropayments and VPN tunneling for privacy, STRATA transforms ordinary routers into secure, income-generating bandwidth nodes.

---

## 🌐 Project Overview

In many modern environments, high-speed internet remains underutilized while travelers, students, and remote workers struggle with expensive or insecure public connectivity. STRATA bridges this gap by creating a secure peer-to-peer marketplace for network capacity.

### Key Features
* **Decentralized Sharing:** Securely sell excess bandwidth or buy affordable connectivity on-demand.
* **Blockchain Micropayments:** Automated, transparent transaction processing using smart contracts.
* **Privacy-First Networking:** All guest traffic is encrypted and routed through a secure **WireGuard VPN tunnel**.
* **Network Isolation:** Guest devices are isolated from the host's private network via strict firewall rules.
* **Emergency Local Chat:** A LAN-based communication channel that functions even during internet outages.
* **Low-Cost Host Nodes:** Optimized to run on accessible hardware like the **Raspberry Pi**.

---

## 🏗️ System Architecture

The STRATA ecosystem consists of three primary software layers plus a
**Raspberry Pi wireless AP** (Iteration 1 ops layer):

1. **Guest Mobile Application:** Cross-platform Flutter app for discovery,
   session management, and a non-custodial wallet.
2. **Host Node:** Python FastAPI daemon (`host_node/`) on the Pi. It owns
   sessions, metering, firewall admit/deny (`nftables`), optional chain
   listening, and the LAN SOS chatroom. It **assumes** a guest Wi-Fi AP
   already exists on `GUEST_IFACE` — it does **not** start `hostapd`.
3. **Security & Payment Layer:** Polygon (Amoy) smart contracts for session
   escrow, plus WireGuard for optional egress privacy. Guest isolation uses
   **nftables** (not legacy `iptables` alone).

### Host networking layout (Iteration 1)

| Role | Default | Notes |
|------|---------|-------|
| Guest AP interface | `wlan0` (`AP_IFACE` / `GUEST_IFACE`) | Configurable via `host_node/ap/.env` and `host_node/.env` |
| WAN / uplink | `eth0` (`WAN_IFACE`) | Management + later guest egress |
| Guest subnet | `192.168.50.0/24` | Gateway `192.168.50.1` |
| Host API URL | `http://192.168.50.1:8080` | Flutter `HOST_API_URL` default |

Reproducible AP bring-up (`hostapd` + `dnsmasq`) lives in
[`host_node/ap/`](host_node/ap/README.md):

```bash
just ap-check      # offline validation (any machine)
just ap-setup      # on the Pi (sudo) — requires host_node/ap/.env
just ap-verify     # on the Pi (sudo)
```

```
  [ISP / modem] ── eth0 ── Raspberry Pi ── wlan0 AP (192.168.50.1)
                              │                 │
                         host_node:8080    guests (DHCP .50–.200)
```

---

## 🔄 User Flow

Based on the STRATA system design, the application follows a streamlined process for both roles:

### For Hosts
1.  **Login/Signup:** Secure authentication via Email/Phone + OTP.
2.  **Onboarding:** Enter ISP details, SSID, and GPS location.
3.  **Setup:** Set data for sale, price per GB, and maximum concurrent users.
4.  **Dashboard:** Activate sharing and monitor real-time earnings and bandwidth usage.

### For Guests
1.  **Discovery:** Automatically scan and discover nearby STRATA networks via map or list view.
2.  **Purchase:** Select a host based on price/rating and choose a data quota.
3.  **Payment:** Initiate a micropayment via the built-in cryptocurrency wallet.
4.  **Connectivity:** Securely authenticate and access the internet through the encrypted tunnel.

---

## 🛠️ Technical Requirements

### Host Node (Raspberry Pi)
* **Hardware:** Raspberry Pi 3/4/5 (or comparable) with a Wi-Fi radio that supports **AP mode**.
* **OS:** Raspberry Pi OS Bookworm (Debian 12+) recommended.
* **AP stack (Iteration 1):** `hostapd` + `dnsmasq` via [`host_node/ap/`](host_node/ap/README.md).
* **Host daemon:** Python 3.11+, `strata-host` (FastAPI).
* **Firewall:** `nftables` ruleset rendered by `strata_host.firewall` (applied when the host node starts on Linux as root).
* **Optional:** WireGuard tools for the exit tunnel (later configuration).

### Mobile App
* **Framework:** Flutter (iOS/Android).
* **Features:** Integrated cryptocurrency wallet and real-time session monitoring.

### Developer machine (no Pi required for app/contracts)
* Flutter SDK ≥ 3.0, Dart ≥ 3.0
* Python 3.11+ for `host_node` unit tests / local API (`STRATA_NFT_FAKE=true`)
* Node.js for `contracts/` (Hardhat)
* Optional: [`just`](https://github.com/casey/just) for repo task recipes

---

## 🚀 Running the Flutter Frontend

The `lib/` directory contains the Flutter client. Parts of the guest/host UX still use **demo data** (e.g. dummy nearby hosts); wallet and host REST/WebSocket paths can target a real LAN Pi.

### Prerequisites
* Flutter SDK ≥ 3.0.0 (install from [flutter.dev](https://flutter.dev/docs/get-started/install))
* Dart SDK ≥ 3.0.0 (bundled with Flutter)
* A connected device or emulator (Android, iOS, web, or desktop)

### Quick Start
```bash
# Install dependencies
flutter pub get

# Run on your default device
flutter run

# Run on a specific device (e.g., Chrome)
flutter run -d chrome
```

### App Screens & Navigation
The app launches with a **Splash Screen** and then presents a **Role Selection** screen:

| Role | Flow |
|------|------|
| **Host** | Login/OTP → Onboarding (ISP/SSID/GPS) → Setup (price, quota, users) → Dashboard |
| **Guest** | Login/OTP → Location Permission → Nearby Hosts → Select Host → Quota → Payment → Dashboard |
| **Both** | Emergency Chatroom (LAN-based, accessible from sidebar) |

### Design
- **Colors:** Black (`#0A0A0A`) + Teal (`#00BFA5`) backgrounds, white text.
- **Sidebar:** Cursor/Gemini-style left sidebar — permanent on wide screens (>800 px), swipe Drawer on mobile.
- **State:** Mixed — demo Wi-Fi cards remain, whilst wallet + host REST/WebSocket flows can target a real LAN Pi via `HOST_API_URL` + mDNS discovery.

---

## 📈 Project Roadmap
* [x] Development of the Guest Mobile App UI (Flutter).
* [x] Implementation of the Host Node Daemon (Python) — Phase A scaffold + captive portal (Phases A & B).
* [x] Non-custodial Ethereum wallet inside the Flutter app (Phase D).
* [x] STRATA ERC-20 token + SessionEscrow + on-chain settlement (Phase E / Iteration 3).
* [x] Biometric / device-PIN gated sensitive wallet actions + settings toggle (Phase H).
* [x] Iteration 3: ChainListener confirmations (`_promote_pending`), settlement receipts, ABI sync, config fail-fast.
* [ ] Conduct large-scale user trials for performance data.

**Iteration 3 payment model:** SessionEscrow — lock funds → active session → usage-based settlement → `closeSession` (not an L2 streaming channel).

- Topology: [`docs/DEMO_TOPOLOGY.md`](docs/DEMO_TOPOLOGY.md)
- Amoy setup: [`docs/AMOY_SETUP.md`](docs/AMOY_SETUP.md)
- WireGuard VPS: [`docs/WIREGUARD_VPS.md`](docs/WIREGUARD_VPS.md)
- Chatroom: [`docs/CHATROOM.md`](docs/CHATROOM.md)
- Local chain demo (no Pi): `just iter3-local-demo` (start `npx hardhat node` first)

---

## 🔐 Design decisions — Phase D (non-custodial wallet)

Phase D ships a real non-custodial Ethereum wallet inside the Flutter app and
wires it into the existing OTP / wallet / payment screens. The wallet targets
**Polygon Amoy** (chain id `80002`) for read-only balance display; on-chain
spend is deferred to Phase E. Below are the non-obvious design choices.

### Storage write only after confirmation
`WalletService.createWallet` generates a fresh BIP-39 mnemonic and derives the
account-0 key on `m/44'/60'/0'/0/0`, but **does not persist** the mnemonic.
The mnemonic is surfaced once via the show-mnemonic screen, then verified via
the confirm-mnemonic screen, and only then does
`AppProvider.commitWalletAfterConfirmation` invoke `persistMnemonic`. This
guarantees that any wallet ever found in `flutter_secure_storage` has been
acknowledged by the user (no half-baked wallets that the user can no longer
recover because they never wrote the phrase down).

### `flutter_secure_storage` configuration
- Android: `encryptedSharedPreferences: true`, requires `minSdkVersion 23`
  (set in `android/app/build.gradle.kts`).
- iOS: `KeychainAccessibility.first_unlock_this_device` so the keystore is
  unlocked transparently after the device boots, without the wallet being
  syncable to other devices.
- Storage key is versioned: `strata.wallet.mnemonic.v1`. Phase G will migrate
  to `.v2` if/when we add a per-wallet PIN-derived KEK.
- Tests use `SecureWalletStorage.forTesting(Map)` for an in-memory backing.

### EIP-191 personal_sign for session start
Session-start authorization is signed with `signPersonalMessageToUint8List`
(EIP-191 `personal_sign`). The canonical message string lives in a single
top-level constant (`strataSessionStartMessageTemplate` in
`wallet_service.dart`) so the host node and the app cannot drift on the
serialization rules.

```
STRATA-SESSION-START
guest:0x…
host:0x…
mac:aa:bb:cc:dd:ee:ff
quota:5368709120
nonce:<uuid v4>
```

The MAC field is currently sent as an empty string from the app — the host
node fills it server-side from the ARP table for the source IP (Phase F will
revisit if we ever expose the LAN MAC to the app).

### Web platform short-circuit
`flutter_secure_storage` falls back to `localStorage` on web, which is **not**
a secure place for a recovery phrase. `main.dart` short-circuits on `kIsWeb`
and shows an explanatory splash. Phase G will revisit (likely with a hardware
wallet bridge).

### Logging hygiene
The mnemonic and `EthPrivateKey` are never passed to `debugPrint`/`print`/
`log`. The `WalletService` keeps key material on local variables only,
returning `WalletCredentials` objects that the provider stores in memory for
the active session.

### Reinstall caveat (release builds)
A release iOS/Android build's wallet survives an app reinstall **only** if
the user has iCloud Keychain or Google account-level keystore backup
enabled. The Profile screen documents this caveat next to the "Backup
wallet" CTA.

### Acceptance checklist
| # | Criterion | Satisfied by |
|---|-----------|---|
| 1 | `flutter pub get` + `flutter test` pass on macOS without a device | `pubspec.yaml`, `test/**`, run on dev machine |
| 2 | Fresh-install flow: role → OTP → "Set up your wallet" → mnemonic shown → confirm 3 words → role landing | `lib/screens/auth/otp_screen.dart`, `lib/screens/wallet/wallet_create_intro_screen.dart`, `wallet_show_mnemonic_screen.dart`, `wallet_confirm_mnemonic_screen.dart` |
| 3 | After app restart, wallet is loaded silently | `lib/providers/app_provider.dart::initWallet` (called from constructor) |
| 4 | Wallet screen shows real address + Polygon Amoy MATIC, refreshes on pull | `lib/screens/wallet_screen.dart`, `lib/services/chain_client.dart`, `AppProvider.refreshWalletBalances` |
| 5 | Payment screen signs the canonical session-start message and POSTs to host node | `lib/screens/guest/payment_screen.dart`, `lib/services/wallet_service.dart::signSessionStart`, `lib/services/host_api_service.dart` |
| 6 | Profile → Backup wallet reveals the same mnemonic | `lib/screens/profile_screen.dart`, `lib/screens/wallet/wallet_backup_screen.dart`, `WalletService.revealMnemonic` |
| 7 | No mnemonic / private key in logs (`rg "(debugPrint|print|log)\s*\(.*\b(mnemonic|privateKey)\b"`) | Code review + grep returns 0 hits |
| 8 | Wallet survives reinstall only with platform keychain backup | Caveat documented next to Backup wallet CTA in `profile_screen.dart` and in this README |

---

## ⛓️ Phase E — On-Chain Settlement

Phase E moves session payments from a signed-message hint to an
authoritative on-chain transfer. Two new Solidity contracts and a real
chain listener replace the Phase A stubs:

- **`StrataToken`** (`contracts/contracts/StrataToken.sol`) — ERC-20 (`STRT`)
  with rate-limited public faucet, owner mint, and pause that gates both
  faucet and transfers.
- **`SessionEscrow`** (`contracts/contracts/SessionEscrow.sol`) —
  `openSession` locks STRT into escrow and emits `SessionOpened`.
  `closeSession` settles a host-signed receipt proportionally
  (`payment = amount * min(consumed, quota) / quota`). `disputeSession`
  is a 24-hour escape hatch for the guest. Receipt hash binds chainId
  AND contract address against replay.

The host node ships a real `ChainListener` (`host_node/src/strata_host/chain_real.py`)
that subscribes to `SessionOpened` events on Polygon Amoy filtered by
`HOST_WALLET_ADDRESS`. When `CHAIN_ENABLED=true`, sessions start in
`pending_payment` and are NOT metered until the listener admits the MAC
and flips the status to `active`.

The Flutter `payment_screen.dart` now:

1. Calls `POST /session/start` → `pending_payment` + `session_ref`.
2. ERC-20 `approve(SessionEscrow, amount)`.
3. `SessionEscrow.openSession(host, amount, sessionRef)`.
4. `POST /session/{id}/payment` with the tx hash (observability hint).
5. Polls `GET /session/status` every 2s until `active` (60s timeout).

### Quickstart

```bash
# 1) Compile + test contracts.
cd contracts
npm install
npx hardhat test
npx hardhat coverage

# 2) Deploy to Polygon Amoy.
cp .env.example .env       # fill DEPLOYER_PRIVATE_KEY + POLYGONSCAN_API_KEY
npx hardhat run scripts/deploy.ts --network amoy

# 3) Wire the printed addresses into:
#    - lib/core/constants/chain_config.dart  (or pass --dart-define=...)
#    - host_node/.env                         (CHAIN_ENABLED, ESCROW, etc.)

# 4) Verify on Amoyscan (optional).
npx hardhat run scripts/verify.ts --network amoy

# 5) Run the host node + the Flutter app.
cd ../host_node && pip install -e ".[dev]" && strata-host
flutter run --dart-define=STRATA_TOKEN=0x... --dart-define=SESSION_ESCROW=0x...
```

### Acceptance checklist

| # | Criterion | Satisfied by |
|---|-----------|---|
| 1 | `cd contracts && npm install && npx hardhat compile` produces zero non-OZ warnings | `contracts/contracts/*.sol`, `hardhat.config.ts` (Solidity 0.8.24, viaIR, optimizer 200 runs) |
| 2 | `npx hardhat test` green at ≥95% coverage; `npx hardhat coverage` prints report | `contracts/test/StrataToken.test.ts`, `contracts/test/SessionEscrow.test.ts` |
| 3 | `npx hardhat run scripts/deploy.ts --network amoy` deploys both, prints addresses, writes `deployments/amoy.json` + `abi/*.json` | `contracts/scripts/deploy.ts` |
| 4 | `npx hardhat run scripts/verify.ts --network amoy` succeeds OR prints "set POLYGONSCAN_API_KEY" and exits non-zero | `contracts/scripts/verify.ts` |
| 5 | `npx hardhat run scripts/e2e_demo.ts --network amoy` produces a successful open → close on testnet with expected balances | `contracts/scripts/e2e_demo.ts` |
| 6 | `cd host_node && pip install -e ".[dev]" && pytest -q` green; new tests for `chain_real.py` cover admit-on-event end-to-end (via fabricated event) | `host_node/tests/test_chain_real.py`, `host_node/tests/test_sessions.py` |
| 7 | `CHAIN_ENABLED=true` + addresses → start logs `chain.listener_started`; on a real on-chain `openSession`, logs `chain.session_authorized` and admits the MAC | `host_node/src/strata_host/chain_real.py`, `host_node/src/strata_host/main.py` |
| 8 | Flutter `payment_screen.dart` completes a real pay-and-connect cycle against Amoy + a running host node on the LAN | `lib/screens/guest/payment_screen.dart`, `lib/services/chain_client.dart` (`approveToken`, `openSession`), `AppProvider.executeOnChainOpenSession` + `waitForSessionActive` |

### Field-name alignment with the host node

Phase A's `/session/start` body used `guest_wallet` and `requested_quota_bytes`.
Phase E aligns them to `guest_wallet_address`, `host_wallet_address`,
`quota_bytes` (matching what the Flutter app already sends and what the
on-chain receipt encodes). The host node tests were updated alongside.

### Out of scope (post-FYP / not Iteration 3)

- Streaming / per-second micropayments.
- Layer-2 payment channels (Iteration 3 uses **SessionEscrow** lock → settle).
- Upgradeable proxies (UUPS / Transparent).
- Slashing / staking economics.
- A reputation / rating contract.
- Multi-host or multi-guest sessions.
- Mainnet deployment.

---

## Phase G — Final Integration

After Phases A–F left STRATA as a set of well-isolated components, Phase G
turns them into a single cohesive system, replaces the lingering mocks, and
ships the SOS chatroom that was 100% UI-only before.

### Architecture diagram

```
                                                                   
                  +------------------+        +-----------------+
                  |  Polygon Amoy    |        |  WireGuard VPS  |
                  |  StrataToken +   |        |  (egress tunnel)|
                  |  SessionEscrow   |        +--------+--------+
                  +------------------+                 ^
                       ^         ^                     |
                       | Seam 2  | Seam 3              | Phase F
                       | (RPC +  | (WSS subscribe +    |
                       |  ABIs)  |  reconcile +        |
                       v         v  reorg)             |
              +-------------------------------+        |
              |       host_node (FastAPI)     |        |
              |                               |        |
              |  +-----------------------+    |        |
              |  | EnforcerService       |----+--------+
              |  |  (single owner of     |    |
              |  |   strata_authed set)  |    |
              |  +----+------+------+----+    |
              |       |      |      |         |
              |       v      v      v         |
              | Portal  Chain  Meter          |
              | route   listen  loop          |
              |                               |
              |  ChatroomManager  Discovery   |
              |   /ws/chatroom    (mDNS)      |
              +-------|--------|------|-------+
                      | Seam 1 | Seam 5
                      | (Dio + | (WS +
                      |  mDNS) |  reconnect)
                      v        v
              +-------------------------------+
              |     Flutter app (guest/host)  |
              |                               |
              |  HostApiService  ChatroomSvc  |
              |  HostDiscoveryService         |
              |  ChainClient (ABI assets)     |
              |  WalletService (BIP-39)       |
              +-------------------------------+
```

The five seams in the prompt map onto the arrows above:

1. **App ↔ Host (HTTP)** — Dio-backed `HostApiService` with mDNS
   discovery, typed errors, request-id tracing, and a `watchStatus`
   stream.
2. **App ↔ Blockchain** — ABIs as Flutter assets in `lib/assets/abi/`
   with a `_AbiCache` lazy loader and a `dart run scripts/sync_abi.dart`
   sync target.
3. **Host ↔ Blockchain** — `ChainListener.reconcile()` runs once at
   startup and admits MACs for any `SessionOpened` event emitted while
   the listener was offline; new events wait `CHAIN_CONFIRMATIONS=3`
   blocks before admitting.
4. **Host ↔ Firewall** — `EnforcerService` is the single owner of the
   `strata_authed` nft set, behind an `asyncio.Queue`. Every
   admit/disconnect logs an `origin` tag (`portal | chain | meter |
   admin`). `tests/test_no_direct_nft_imports.py` keeps that property
   true at CI time.
5. **App ↔ App (chatroom)** — real WebSocket server at
   `/ws/chatroom`, RAM-only by default with optional SQLite
   persistence; `ChatroomService` reconnects with exponential backoff
   1s → 30s and falls back to the LAN gateway IP when discovery is
   empty so SOS still works without DNS.

### End-to-End Quickstart

From a fresh checkout against a local Hardhat node:

```bash
# Terminal 1 — local chain
cd contracts && npx hardhat node

# Terminal 2 — deploy contracts
cd contracts && npx hardhat run scripts/deploy.ts --network localhost
# Note the printed StrataToken + SessionEscrow addresses.

# Terminal 3 — host_node (chain mode + fake nft so it runs on macOS)
cd host_node
cp .env.example .env
# Set CHAIN_ENABLED=true and paste the addresses from terminal 2.
DEMO_MODE=true CHAIN_ENABLED=true STRATA_NFT_FAKE=true \
  STRATA_WG_FAKE=true MDNS_ENABLED=true ADMIN_TOKEN=local-dev \
  uvicorn strata_host.main:app --host 0.0.0.0 --port 8080

# Terminal 4 — Flutter app
dart run scripts/sync_abi.dart                # copy ABIs into lib/assets/abi/
flutter run -d chrome \
  --dart-define=STRATA_TOKEN=0x...            \
  --dart-define=SESSION_ESCROW=0x...          \
  --dart-define=CHAIN_ID=31337                \
  --dart-define=RPC_URL=http://127.0.0.1:8545 \
  --dart-define=HOST_API_URL=http://127.0.0.1:8080 \
  --dart-define=STRATA_ADMIN_TOKEN=local-dev-token
# STRATA_ADMIN_TOKEN is optional; match host_node ADMIN_TOKEN for live firewall MACs in My Hosting.
# CHAIN_RPC_URL is accepted as an alias for RPC_URL.```

A top-level `justfile` exposes the same commands as `just host-run-chain`,
`just deploy-localhost`, `just flutter-run`, `just sync-abi`, `just
nft-show`, `just down`.

### Acceptance criteria mapping

| # | Criterion | Files | Validate with |
|---|-----------|-------|---------------|
| 1 | Quickstart end-to-end runs from a fresh checkout | `README.md`, `justfile`, `host_node/.env.example` | follow the four-terminal flow above |
| 2 | Captive portal flow + Flutter flow leave the same `strata_authed` state and emit the same `SessionOpened` event | `host_node/src/strata_host/enforcer.py`, `host_node/src/strata_host/firewall/nft_set.py`, `host_node/src/strata_host/routes/sessions.py`, `host_node/src/strata_host/chain_real.py` | `pytest host_node/tests/test_enforcer_queue.py host_node/tests/test_chain_real.py` |
| 3 | Killing + restarting host_node mid-session reconciles late `SessionOpened` events without re-payment | `host_node/src/strata_host/chain_real.py::reconcile`, `host_node/src/strata_host/main.py` (lifespan calls `reconcile()` before live subscription) | `pytest host_node/tests/test_chain_reorg.py::test_force_confirm_bypasses_gating_for_reconcile` |
| 4 | Exactly one importer of `nft_set.py` in `host_node/`; CI fails otherwise | `host_node/src/strata_host/firewall/nft_set.py`, `host_node/tests/test_no_direct_nft_imports.py` | `pytest host_node/tests/test_no_direct_nft_imports.py` |
| 5 | Two guests on same Pi chat in real time, even with WAN unplugged; SOS works for unauthenticated guest from the captive portal | `host_node/src/strata_host/chatroom/{server,store,models}.py`, `lib/services/chatroom_service.dart`, `lib/screens/chatroom/chatroom_screen.dart` | `pytest host_node/tests/test_chatroom.py` (server side); manual: open two browser tabs at `flutter run -d chrome --web-port 9000`, navigate to `/chatroom` |
| 6 | Disconnecting the Pi mid-chat triggers the reconnect UI; reconnecting re-loads history | `lib/services/chatroom_service.dart::_scheduleReconnect`, `lib/screens/chatroom/chatroom_screen.dart::_connectionBanner` | manual: kill `uvicorn`, watch the yellow "Reconnecting in Xs…" banner; restart, history is fetched on reconnect |
| 7 | E2E pytest green when invoked manually | `host_node/tests/e2e/test_full_flow.py` | `cd host_node && pytest -m e2e tests/e2e` (after running `npx hardhat node` + `deploy.ts`) |
| 8 | A 2-block reorg drops the pending event, never admits the guest, fires `chain.reorg_dropped` | `host_node/src/strata_host/chain_real.py::drop_reorged`, `host_node/tests/test_chain_reorg.py::test_drop_reorged_evicts_pending_event` | `pytest host_node/tests/test_chain_reorg.py` |
| 9 | Guest dashboard "remaining data" gauge updates from streamed host metering, not client-side decrement | `lib/providers/app_provider.dart::startSessionMonitor` + `_onSessionStatus`; `lib/screens/guest/guest_dashboard_screen.dart::initState`; `lib/services/host_api_service.dart::watchStatus` | run app, observe `remainingData` mutating in response to `/session/status` polls |
| 10 | Killing internet on Pi while a session is active surfaces a clear error within 10s and prevents new sessions | `lib/services/host_api_service.dart::_toException` + retry policy; `ChatroomService` reconnect banner; `MeterService` continues server-side | manual: `sudo iptables -A OUTPUT -j DROP` on the Pi and watch the red banner appear |

### Design decisions — Phase G

- **Single-owner firewall (`EnforcerService` queue)**: every admit/disconnect
  is serialized through one `asyncio.Queue` consumer. The captive portal,
  the chain listener, the metering loop, and the admin API all hand the
  same `EnforcerService` an `origin` tag rather than calling `nft` themselves.
  This makes "who admitted this MAC?" answerable from one log stream and
  prevents the `nft add element ` + in-memory mirror update from being
  raced by a concurrent disconnect. A grep-based test
  (`tests/test_no_direct_nft_imports.py`) keeps the discipline honest.

- **3-confirmation reorg policy on Amoy**: pay-and-connect events go into
  a `_pending` dict keyed on `(block_number, log_index)` and only admit
  the MAC after `current_block - event.block_number >= 3`. A reorg
  watchdog can call `drop_reorged({(block, log_index), ...})` to evict
  events whose tx no longer exists; the `chain.reorg_dropped` log is the
  audit trail. `DEMO_MODE` forces confirmations to `0` so the panel demo
  feels snappy. `reconcile()` uses `force_confirm=True` because by
  definition it's looking at historical blocks where the reorg risk has
  already passed.

- **mDNS over UPnP**: STRATA hosts advertise `_strata._tcp.local.` with
  TXT records carrying the wallet address and SessionEscrow contract.
  We chose mDNS over UPnP because UPnP requires a router that publishes
  IGD services (most Pakistani ISPs don't), and because mDNS is the same
  protocol AirDrop/Bonjour use — already present on every guest's phone.
  The Flutter `HostDiscoveryService` caches results for 30s so a screen
  rebuild doesn't flood the network.

- **Polling over SSE for `/session/status`**: a `Stream<SessionStatus>`
  that polls every 2s rather than a server-sent-events stream. Polling
  is trivially cancellable, doesn't require keep-alive plumbing on the
  Pi, and survives the Flutter web build (where SSE has tooling rough
  edges). 2 seconds is a reasonable trade between meter freshness and
  request volume on a battery-powered Pi.

- **SQLite persistence for chatroom (off by default)**: `CHATROOM_PERSIST=true`
  mirrors writes to `/var/lib/strata/chatroom.sqlite` so messages survive
  a Pi reboot. Off by default because (a) the data is sensitive
  (emergency context, locations), (b) the path is system-owned and the
  default `strata-host` may not have write access without operator
  intervention, and (c) the chatroom is *intended* to be ephemeral — the
  emergency value is the room being there now, not a forensic record of
  what was said three days ago. Reads always come from RAM either way.

### Files added in Phase G

- `host_node/src/strata_host/firewall/nft_set.py` — single-owner kernel set wrapper.
- `host_node/src/strata_host/enforcer.py` — queue + origin-tagged.
- `host_node/src/strata_host/discovery.py` — zeroconf advertiser.
- `host_node/src/strata_host/chatroom/{__init__,models,store,server}.py` — WebSocket chatroom + REST helpers.
- `host_node/src/strata_host/routes/admin.py` — `/admin/reconcile`, `/admin/firewall/state`.
- `host_node/tests/test_no_direct_nft_imports.py`, `test_enforcer_queue.py`, `test_chatroom.py`, `test_chain_reorg.py`, `test_admin_endpoints.py`, `tests/e2e/test_full_flow.py`.
- `lib/services/host_discovery_service.dart`, `lib/services/chatroom_service.dart`.
- `lib/services/host_api_service.dart` (rewritten on Dio).
- `lib/services/chain_client.dart` (ABIs externalised to `lib/assets/abi/`).
- `lib/screens/chatroom/chatroom_screen.dart` (rewritten on `ChatroomService`).
- `scripts/sync_abi.dart`, `justfile`, `CONTRIBUTING.md`.

### Out of scope — Phase G (post-FYP)

- Push notifications (foreground only).
- iOS/Android background reconnection for the chatroom socket.
- Multi-host roaming (a guest moving between two STRATA APs mid-session).
- Chatroom message encryption.
- Federated chatrooms across multiple Pis on the same SSID.
- An **on-chain** reputation / rating registry (Phase H uses **Firestore** only for FYP demos).

---

## Phase H — App restoration & completion (Flutter client)

Flutter-only pass to align **wallet, host REST metering, LAN discovery, ratings, biometric gates, onboarding, and release packaging** without touching **`host_node/`** or **`contracts/`**.

### Shipped

- **Session history (`sqflite`):** `lib/services/session_history_service.dart` records starts/stops (`rate_rs_per_gb` column v2 migration), `lib/screens/guest/session_history_screen.dart` renders history + Amoyscan deeplinks, `lib/widgets/sidebar.dart` shows the latest rows under **Recent sessions**.
- **Ratings (`cloud_firestore` + fallback):** `lib/services/rating_service.dart` keeps Firestore + in-memory parity for tests/offline demos; **`guest_dashboard_screen.dart`**, **`select_host_screen.dart`**, **`nearby_hosts_screen.dart`** consume it.
- **Biometric gate (`local_auth` + dialogs):** `lib/utils/biometric_prompt.dart` + `lib/core/settings/strata_secure_settings.dart`; wired into **`payment_screen.dart`** and **`wallet_backup_screen.dart`**, toggle on **`guest/settings_screen.dart`**.
- **Coach marks:** carousel on **`role_selection_screen.dart`**, mnemonic tip on **`wallet_show_mnemonic_screen.dart`** via secure-storage flags.
- **`ErrorView`:** `lib/widgets/error_view.dart` centralises UX for transport, chain, wallet, chat disconnect, and timeout failures.
- **Live wiring deltas:** OTP uses `walletService.hasWallet()`, dashboard listens to **`HostApiService.watchStatus`** with sqflite metering updates + revoked routing, LAN tiles call **`GET /host/info`**, chatroom prefers **`AppProvider.connectedHostBaseUrl`**, `AppRoutes.guestSessions` + router hookup.
- **Android release posture:** `com.strata.app` application id (Kotlin package remains `com.example.strata`), R8 **`minifyEnabled` + `shrinkResources`**, signing via **`android/key.properties`** (example provided). **iOS** plist adds location/local-network/Bonjour keys + **STRATA Demo** CFBundleDisplayName.
- **Branding automation:** run `dart run scripts/gen_branding_placeholder.dart` then **`dart run flutter_launcher_icons`** / **`dart run flutter_native_splash:create`** — replace generated art under `lib/assets/branding/` before submission.

### Release builds

```bash
flutter build apk --release \
  --dart-define=STRATA_TOKEN=0xYourStrataToken \
  --dart-define=SESSION_ESCROW=0xYourEscrow \
  --dart-define=HOST_API_URL=http://192.168.50.1:8080

flutter build ipa --release \
  --dart-define=STRATA_TOKEN=0xYourStrataToken \
  --dart-define=SESSION_ESCROW=0xYourEscrow
```

`flutter analyze` still reports historical `prefer_const_*` **info** lints in untouched screens; **`flutter analyze --no-fatal-infos`** is green alongside `flutter test`.

### Acceptance criteria → files

| # | Criterion | Files / notes |
|---|-----------|---------------|
| 1 | Analyzer + tests | `flutter analyze --no-fatal-infos`, `flutter test` |
| 2 | OTP wallet branch | `lib/screens/auth/otp_screen.dart` |
| 3 | Payment + biometrics | `lib/screens/guest/payment_screen.dart` |
| 4 | Dashboard metering + history | `lib/screens/guest/guest_dashboard_screen.dart`, `session_history_service.dart` |
| 5 | LAN host + `/host/info` | `lib/screens/guest/nearby_hosts_screen.dart`, `lib/services/host_api_service.dart` |
| 6 | Chatroom host URL | `lib/screens/chatroom/chatroom_screen.dart`, `app_provider.dart` (`connectedHostBaseUrl`) |
| 7 | Ratings | `rating_service.dart`, guest screens |
| 8 | Session history route | `lib/navigation/app_router.dart`, `app_routes.dart`, `session_history_screen.dart` |
| 9 | Icons + splash | `pubspec.yaml`, `scripts/gen_branding_placeholder.dart`, generated platform assets |
|10 | Android signing story | `android/app/build.gradle.kts`, `android/key.properties.example` |

### Design decisions — Phase H

- **Firestore ratings:** fastest path to sortable aggregates for demos; on-chain reviews remain post-FYP.
- **Client-side session DB:** mirrors host telemetry for UX only; the Pi is still authoritative for enforcement.

### Placeholder branding

All PNGs generated by `scripts/gen_branding_placeholder.dart` are **non-final** teal/black geometry — swap in production artwork referenced by marketing.

---

## Phase I — Hardening & production polish (Flutter client — **in progress**)

Phase I closes demo-day gaps **in `lib/` and platform manifests only**. `host_node/` and `contracts/` remain untouched per scope.

### Shipped in this milestone

| Area | What changed |
|------|----------------|
| **P0.1 Session persistence** | `lib/services/session_state_store.dart` — JSON in secure storage. `SessionModel` `toJson`/`fromJson`. `AppProvider` restores after `GET /session/status`; splash routes to `/guest/dashboard` when active. Persist on demo `startGuestSession`, after successful payment (`persistActiveGuestSession`), clear on dashboard terminal stop + provider metering stop. |
| **P0.3 Deep links** | `lib/services/deep_link_service.dart` + Android `intent-filter` (`strata` / `onboard`) + iOS `CFBundleURLTypes`. Splash consumes cold-start link; `_LifecycleShell` routes warm links via `GoRouter`. `HostDiscoveryService.setCaptivePortalPin` pins the portal host. |
| **P0.4 Crashlytics + logs** | `main.dart` — `FlutterError.onError` + `PlatformDispatcher.instance.onError`, `PackageInfo` + `chain_id` keys. `LogService` ring buffer (`lib/services/log_service.dart`). `AppProvider.refreshWalletBalances` sets `wallet_address` (last 6) + `host_base_url`. |
| **Connectivity / lifecycle** | `connectivity_plus` listener + transient “back online”; `onAppPaused` stops session monitor / `onAppResumed` re-fetches (host API skeleton for full chat reconnect ([`P1.10`] follow-up)). |
| **Chain / ABI** | `lib/assets/abi/*.json` extended with `faucet`, `allowance`, `closeSession`, `disputeSession`. `ChainClient`: `WrongNetworkException` (rpc `chainId`), `claimFaucet`, gas estimate constant, receipt verification helpers, tx send/verify split for open session. |

### Manual checks (P0)

1. **Session restore:** Start a paid or demo session → force-stop the app → relaunch → splash should resume **Guest dashboard** if host still reports `active`.  
2. **Deep link:** Open `strata://onboard?portal_ip=192.168.x.x&portal_port=8080&host_address=0x...` → app pins host URL and lands on `/role` (or `/guest/nearby` if already signed in).

### Still outstanding (remaining Phase I backlog)

Payment pre-flight panel (+ `url_launcher` CTAs), Help/FAQ screen + `HelpButton`, Firebase **Analytics** event matrix, pending-payment retry UX + `PendingPaymentStore` wiring, unlimited-approve UX, dashboard “End session” + on-chain settle UI, `disputeSession` flows in UI, FCM registration + handlers, WorkManager heartbeat, verified-host Firestore shim, localization wiring beyond ARB scaffolding, legal screens + privacy audit items, Skeletonizer swaps, destructive confirmations, README acceptance table for every criterion — plus the **requested new `flutter_test` files**.

### Design decisions — Phase I

- **In-memory log ring buffer capped at 200 lines** keeps “Copy diagnostics” payloads small enough for email without unbounded RAM growth.  
- **Session snapshot includes `host_base_url` + persisted host wallet** so a cold boot can hit the correct Pi without repeating discovery.  
- **Deep link vs restore:** Captive-portal cold link sets `_deepLinkConsumedThisColdBoot` so we do not overwrite the user’s onboarding route with stale dashboard restore during the same boot.

---

## 👥 Contributors
* **Abdul Rehman** (221-0785)
* **Laila Tariq** (221-1574)
* **Abdullah Tahir** (211-0708)
* **Supervised by:** Mr. Shehreyar Rashid

**Institution:** National University of Computer and Emerging Sciences, Islamabad.  
**Session:** 2022-2026.

---
*Generated for the STRATA Final Year Project Prototype, June 2026.*
