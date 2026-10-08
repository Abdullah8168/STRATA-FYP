# Contributing to STRATA

## Repository layout

| Path | Role |
|------|------|
| `lib/` | Flutter guest/host client |
| `host_node/` | FastAPI host daemon (sessions, firewall, chat, chain listener) |
| `host_node/ap/` | **Iteration 1** Raspberry Pi `hostapd` + `dnsmasq` AP bring-up |
| `contracts/` | Solidity (`StrataToken`, `SessionEscrow`) + Hardhat |
| `justfile` | Common developer commands |
| `.github/workflows/` | CI (`firewall` fast tests, `ap-check`) |

## Developer setup (reproducible)

```bash
# Optional task runner
brew install just   # or see https://github.com/casey/just

# Flutter client
flutter pub get
flutter test

# Host node
cd host_node
python3.11 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
cp .env.example .env
pytest -q -m "not integration and not e2e"

# Contracts
cd contracts && npm install && npx hardhat test

# Iteration 1 AP templates (no Pi required)
just ap-check
```

On a Raspberry Pi, after `cp host_node/ap/env.example host_node/ap/.env` and
setting `WPA_PASSPHRASE`:

```bash
just ap-setup
just ap-verify
```

Full AP runbook: [`host_node/ap/README.md`](host_node/ap/README.md).

## Architecture rules

### Wireless AP vs host daemon

- **`host_node/ap/`** owns `hostapd` / `dnsmasq` and the guest subnet
  `192.168.50.0/24` (gateway `192.168.50.1`).
- **`strata-host`** binds HTTP on `:8080` and applies **nftables** using
  `GUEST_IFACE` / `WAN_IFACE`. It does not start the AP.
- Keep `AP_IFACE` (`host_node/ap/.env`) equal to `GUEST_IFACE` (`host_node/.env`).

### Single-owner firewall (Phase G)

The strata_authed nftables set has exactly one owner: `EnforcerService`.

- The captive portal, the chain listener, the metering loop, and the
  admin API all call `EnforcerService.admit/disconnect`.
- Nothing else imports `host_node/src/strata_host/firewall/nft_set.py`.
- A test (`tests/test_no_direct_nft_imports.py`) fails CI if a new file
  reaches into `nft_set.py` directly.

If you need to mutate the set from a new code path, route the call
through `EnforcerService` and pass an `origin` tag (`"portal"`,
`"chain"`, `"meter"`, `"admin"`). The audit logs will then answer "who
admitted this MAC" without you having to grep five log files.

### Single-loop discipline

`NftSet` binds itself to the asyncio loop that constructed it (the
FastAPI lifespan loop). Calling its async methods from a different loop
raises `LoopMismatchError`. Don't touch the kernel set from anywhere
that isn't the running app's event loop.

### Where state lives

| State                          | Owner                               |
|--------------------------------|-------------------------------------|
| Guest Wi-Fi AP (SSID/DHCP)     | `host_node/ap/` (hostapd/dnsmasq)   |
| Session lifecycle              | `SessionStore` (in `host_node`)     |
| nftables strata_authed set     | `EnforcerService`                   |
| Chain subscription + reconcile | `ChainListener`                     |
| Chatroom messages              | `ChatroomStore` (RAM + opt SQLite)  |
| Wallet keys                    | `WalletService` (Flutter, OS keychain) |

The Flutter app never talks to `nft` or to the chain for *authorization*
(it talks to the chain for *payment*). Admit/deny is the host node's
call.

## Running the tests

```bash
# host_node
cd host_node && pytest -q
# contracts
cd contracts && npx hardhat test
# flutter
flutter test
# AP templates (Iteration 1)
just ap-check
```

## Style

- Python: structlog for everything. Don't print() in production paths.
- Dart: prefer `dart format` defaults; nothing custom.
- Solidity: `npx hardhat compile && npx hardhat coverage` should be
  ≥ 95% branches.
- Never commit `host_node/ap/.env`, `host_node/.env`, or Wi-Fi passphrases.
