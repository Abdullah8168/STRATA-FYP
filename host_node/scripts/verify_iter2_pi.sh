#!/usr/bin/env bash
# Iteration 2 — physical Raspberry Pi E2E verification checklist (run ON the Pi).
#
# Prerequisites:
#   - Iteration 1 AP is up (just ap-setup / strata-hostapd active)
#   - host_node/.env has:
#       DEMO_MODE=false
#       ALLOW_CLIENT_MAC=false
#       CHAIN_ENABLED=false
#       HOST_WALLET_ADDRESS=0x…   # real host EOA
#       GUEST_IFACE=<AP_IFACE>
#   - strata-host running as root (or with nft + nf_conntrack readable)
#   - Phone on the STRATA SSID
#
# Usage:
#   sudo bash host_node/scripts/verify_iter2_pi.sh [BASE_URL]
#   BASE_URL default: http://192.168.50.1:8080

set -euo pipefail

BASE="${1:-http://192.168.50.1:8080}"
fail=0
ok() { echo "  OK  $*"; }
bad() { echo "  FAIL $*"; fail=1; }
section() { echo; echo "== $* =="; }

section "1. Host health"
if curl -sf "$BASE/health" | grep -q '"status":"ok"'; then
  ok "GET /health"
  curl -sf "$BASE/health" | tee /tmp/strata_health.json
  if grep -q '"demo_mode":false' /tmp/strata_health.json; then
    ok "DEMO_MODE=false"
  else
    bad "DEMO_MODE is not false — real metering will not be authoritative"
  fi
else
  bad "GET /health failed against $BASE"
fi

section "2. Host info"
if curl -sf "$BASE/host/info" | tee /tmp/strata_host_info.json | grep -q wallet_address; then
  ok "GET /host/info"
else
  bad "GET /host/info"
fi

section "3. Portal + client identity (run from the Pi; for phone MAC use phone browser)"
if curl -sf "$BASE/portal/client" | tee /tmp/strata_portal_client.json >/dev/null; then
  ok "GET /portal/client reachable"
  echo "  Note: when curling FROM the Pi, mac_address is often null."
  echo "  From the guest phone browser open $BASE/ and confirm MAC is shown,"
  echo "  or: curl $BASE/portal/client from the phone (Termux / Shortcuts)."
else
  bad "GET /portal/client"
fi

section "4. Captive portal HTML"
if curl -sf "$BASE/" | grep -qi STRATA; then
  ok "GET / returns portal HTML"
else
  bad "GET / portal HTML"
fi

section "5. nftables (root)"
if command -v nft >/dev/null 2>&1; then
  if nft list set inet strata strata_authed >/dev/null 2>&1; then
    ok "strata_authed set exists"
    nft list set inet strata strata_authed || true
  else
    bad "strata_authed set missing — is strata-host running as root on Linux?"
  fi
else
  bad "nft not installed"
fi

section "6. Neighbour table on guest iface"
IFACE="$(grep -E '^GUEST_IFACE=' /etc/strata/ap/network.env 2>/dev/null | cut -d= -f2 || true)"
IFACE="${IFACE:-wlan0}"
if ip -json neigh show dev "$IFACE" 2>/dev/null | head -c 200 | grep -q .; then
  ok "ip neigh on $IFACE has entries (guest phones should appear here)"
  ip neigh show dev "$IFACE" || true
else
  bad "no neighbours on $IFACE — connect a phone to the AP first"
fi

section "7. Manual steps (phone + Flutter) — cannot be fully automated here"
cat <<'EOF'
  a) Phone joins STRATA SSID; note DHCP IP (Settings → Wi‑Fi details).
  b) Open http://192.168.50.1/ (or any http:// site) → portal should appear.
  c) Confirm portal shows your phone MAC (matches `ip neigh`).
  d) Open STRATA app (HOST_API_URL / deep link / mDNS) → Live host card.
  e) Create/unlock wallet → select live host → quota → Pay.
  f) Expect POST /session/start 200; `nft list set inet strata strata_authed`
     contains the phone MAC.
  g) Browse https://example.com from the phone.
  h) Watch host logs for meter.mode linux_traffic_reader=true and rising
     bytes_used on GET /session/status?session_id=…
  i) Stop session from app; MAC leaves strata_authed; HTTP redirect returns.

  Negative checks:
  - Tampered signature → 401 INVALID_SIGNATURE
  - Wrong host wallet → 422 HOST_WALLET_MISMATCH
  - Phone not on AP (no ARP) → 422 MAC_UNRESOLVED
EOF

echo
if (( fail != 0 )); then
  echo "VERIFY_ITER2: FAILED (see FAIL lines above)"
  exit 1
fi
echo "VERIFY_ITER2: automated Pi checks passed — finish phone/Flutter steps above."
