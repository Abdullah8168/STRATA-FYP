#!/bin/sh
# ----------------------------------------------------------------------
# STRATA - run the app on a Mac / Linux laptop as a GUEST of the Pi
# (STRATA-Pi-01). Same as run_guest_laptop.bat, for macOS.
#
# Run from Terminal:   sh run_guest_laptop.sh
#
# Needs Flutter + Chrome on this laptop (flutter pub get done once).
# 1. Run this while the laptop is on normal Wi-Fi, log in (email code)
#    and import the test wallet:
#      test test test test test test test test test test test junk
# 2. Keep Chrome open, switch Wi-Fi to STRATA-Pi-01 (password strata2026)
#    and pay from Nearby Hosts (Confirm Payment).
# ----------------------------------------------------------------------
cd "$(dirname "$0")" || exit 1
flutter run -d chrome --web-port 5566 \
  --dart-define=HOST_API_URL=http://192.168.50.1:8080 \
  --dart-define=RPC_URL=http://192.168.50.1:8080/rpc \
  --dart-define=CHAIN_ID=31337 \
  --dart-define=STRATA_TOKEN=0x5FbDB2315678afecb367f032d93F642f64180aa3 \
  --dart-define=SESSION_ESCROW=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
