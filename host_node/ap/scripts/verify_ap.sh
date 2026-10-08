#!/usr/bin/env bash
# Verify STRATA AP health on the Raspberry Pi after setup_ap.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

fail=0
ok() { echo "  OK  $*"; }
bad() { echo "  FAIL $*"; fail=1; }

if [[ -f "${AP_DIR}/.env" ]]; then
  ap_load_env "${AP_DIR}"
elif [[ -f /etc/strata/ap/network.env ]]; then
  # shellcheck disable=SC1091
  source /etc/strata/ap/network.env
  : "${AP_IFACE:=wlan0}"
  : "${AP_ADDRESS:=192.168.50.1}"
  : "${GENERATED_DIR:=/etc/strata/ap}"
  : "${SSID:=unknown}"
else
  echo "error: no host_node/ap/.env or /etc/strata/ap/network.env" >&2
  exit 1
fi

echo "== STRATA AP verify =="

if [[ -d "/sys/class/net/${AP_IFACE}" ]]; then
  ok "interface ${AP_IFACE} exists"
else
  bad "interface ${AP_IFACE} missing"
fi

if ip -4 addr show dev "${AP_IFACE}" 2>/dev/null | grep -q "${AP_ADDRESS}"; then
  ok "${AP_IFACE} has ${AP_ADDRESS}"
else
  bad "${AP_IFACE} does not have ${AP_ADDRESS}"
fi

if systemctl is-active --quiet strata-hostapd.service 2>/dev/null; then
  ok "strata-hostapd.service active"
else
  bad "strata-hostapd.service not active"
  systemctl status strata-hostapd.service --no-pager -l 2>/dev/null | head -20 || true
fi

if systemctl is-active --quiet strata-dnsmasq.service 2>/dev/null; then
  ok "strata-dnsmasq.service active"
else
  bad "strata-dnsmasq.service not active"
  systemctl status strata-dnsmasq.service --no-pager -l 2>/dev/null | head -20 || true
fi

if command -v iw >/dev/null 2>&1; then
  if iw dev "${AP_IFACE}" info 2>/dev/null | grep -qi 'type AP'; then
    ok "iw reports ${AP_IFACE} type AP"
  else
    bad "iw does not report AP mode on ${AP_IFACE}"
    iw dev "${AP_IFACE}" info 2>/dev/null || true
  fi
else
  echo "  skip iw (not installed)"
fi

if [[ -f "${GENERATED_DIR:-/etc/strata/ap}/hostapd.conf" ]]; then
  ok "generated hostapd.conf present"
  # Do not print passphrase lines.
  grep -E '^(interface|ssid|channel|hw_mode)=' "${GENERATED_DIR}/hostapd.conf" || true
else
  bad "missing ${GENERATED_DIR:-/etc/strata/ap}/hostapd.conf"
fi

echo
echo "Manual client checks (hardware — run from a phone/laptop):"
echo "  1. Join SSID '${SSID}' with the passphrase from host_node/ap/.env"
echo "  2. Confirm DHCP lease in ${DHCP_RANGE_START:-\?}–${DHCP_RANGE_END:-\?}"
echo "  3. ping ${AP_ADDRESS}"
echo "  4. After host_node is running: curl -s http://${AP_ADDRESS}:8080/health"
echo
if (( fail != 0 )); then
  echo "VERIFY FAILED"
  exit 1
fi
echo "VERIFY PASSED (service-level). Complete client association on hardware."
