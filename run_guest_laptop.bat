@echo off
REM ----------------------------------------------------------------------
REM STRATA - run the app on a laptop as a GUEST of the Pi (STRATA-Pi-01).
REM
REM Needs Flutter on this laptop (flutter pub get done once).
REM 1. Run this while the laptop is on normal Wi-Fi, log in (email code)
REM    and import the test wallet:
REM      test test test test test test test test test test test junk
REM 2. Then switch this laptop's Wi-Fi to STRATA-Pi-01 (password strata2026)
REM    and pay from Nearby Hosts. The app talks to the Pi directly at
REM    192.168.50.1, so the Pi can see this laptop's Wi-Fi MAC and admit it.
REM ----------------------------------------------------------------------
cd /d "%~dp0"
flutter run -d chrome --web-port 5566 ^
  --dart-define=HOST_API_URL=http://192.168.50.1:8080 ^
  --dart-define=RPC_URL=http://192.168.50.1:8080/rpc ^
  --dart-define=CHAIN_ID=31337 ^
  --dart-define=STRATA_TOKEN=0x5FbDB2315678afecb367f032d93F642f64180aa3 ^
  --dart-define=SESSION_ESCROW=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
