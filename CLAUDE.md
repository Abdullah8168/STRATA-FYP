# STRATA — notes for Claude

STRATA: Flutter guest/host app (`lib/`), Python host node for the Raspberry Pi
(`host_node/`), Solidity contracts (`contracts/`). See `README.md` for the
architecture and `SETUP_AFTER_UNZIP.txt` for first-time setup.

## Running the app as a GUEST of the Pi (most common task)

The app MUST be started with the payment (chain) settings. A plain
`flutter run` starts it in "no payment" mode: it skips the payment and opens
the session screen, which shows "DISCONNECTED" with no internet, because the
Pi only admits a device after a real on-chain payment.

- Windows: `run_guest_laptop.bat`
- macOS / Linux: `sh run_guest_laptop.sh`
- Phone: install `build/app/outputs/flutter-apk/app-release.apk`, or build it
  with the same `--dart-define`s as in `run_guest_laptop.sh`.

Do not change the `--dart-define` values in those scripts: they point at the
Pi (`192.168.50.1:8080`, `/rpc` relay) and the demo contracts on the local
Hardhat chain (chain id 31337).

Steps to tell the user:
1. Start the app while the laptop is on its **normal Wi-Fi** (login needs internet).
2. Log in, then in Wallet **import the test wallet**:
   `test test test test test test test test test test test junk`
   (a new app-created wallet has no test money, so payment fails).
3. **Keep Chrome open** (the web build forgets the login when Chrome closes),
   switch Wi-Fi to `STRATA-Pi-01` (password `strata2026`).
4. Nearby Hosts → STRATA Pi (demo) → package → Confirm Payment; wait until all
   payment steps are green. After use: Disconnect → Settle on-chain.

Don't pay from two devices with the same wallet at the same moment.

## The Pi side (only on the laptop wired to the Pi)

The local blockchain runs on the laptop that is wired to the Pi by Ethernet
(Windows Internet Connection Sharing). That laptop runs `START_STRATA.bat`,
which needs the Pi's SSH key in `%USERPROFILE%\.ssh\strata_pi`. A guest
laptop does NOT run this and does not need the key. If payments fail with
"getChainId failed" / RPC errors, the Ethernet link or the blockchain/tunnel
windows on that laptop are down — not a bug in the app.

## Tests

- App: `flutter analyze`, `flutter test`
- Host node: `cd host_node && python -m pytest -q` (venv: see `SETUP_AFTER_UNZIP.txt`)

## Rules

- Work locally only: do not commit or push.
- Don't modify `contracts/` (owned by another team member).
