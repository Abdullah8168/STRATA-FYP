#!/usr/bin/env bash
# Validate AP templates + scripts without Raspberry Pi hardware (Iteration 1).
# Safe on macOS / CI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "== STRATA AP config check =="

for f in \
  "${AP_DIR}/env.example" \
  "${AP_DIR}/templates/hostapd.conf.in" \
  "${AP_DIR}/templates/dnsmasq.conf.in" \
  "${AP_DIR}/scripts/setup_ap.sh" \
  "${AP_DIR}/scripts/teardown_ap.sh" \
  "${AP_DIR}/scripts/verify_ap.sh" \
  "${AP_DIR}/scripts/render_config.sh" \
  "${AP_DIR}/scripts/lib.sh"
do
  if [[ ! -f "${f}" ]]; then
    echo "missing: ${f}" >&2
    exit 1
  fi
done

OUT="$(mktemp -d)"
TMP_ENV="$(mktemp)"
cleanup() {
  rm -rf "${OUT}"
  rm -f "${TMP_ENV}"
}
trap cleanup EXIT

# Always validate against a known-good temp env (does not require committed secrets).
sed 's/^WPA_PASSPHRASE=.*/WPA_PASSPHRASE=ci-check-passphrase-ok/' \
  "${AP_DIR}/env.example" > "${TMP_ENV}"

# shellcheck disable=SC1090
set -a
# shellcheck disable=SC1091
source "${TMP_ENV}"
set +a

if [[ "${AP_ADDRESS}" != "192.168.50.1" ]]; then
  echo "warn: env.example AP_ADDRESS=${AP_ADDRESS} (project default is 192.168.50.1)"
fi

ap_require_passphrase
ap_render_file "${AP_DIR}/templates/hostapd.conf.in" "${OUT}/hostapd.conf"
ap_render_file "${AP_DIR}/templates/dnsmasq.conf.in" "${OUT}/dnsmasq.conf"

if grep -E '__[A-Z0-9_]+__' "${OUT}/hostapd.conf" "${OUT}/dnsmasq.conf"; then
  echo "error: unresolved placeholders" >&2
  exit 1
fi

# Confirm SSID and gateway landed in the right files.
grep -q "^ssid=${SSID}$" "${OUT}/hostapd.conf"
grep -q "dhcp-option=option:router,${AP_ADDRESS}" "${OUT}/dnsmasq.conf"
grep -q "interface=${AP_IFACE}" "${OUT}/hostapd.conf"
grep -q "interface=${AP_IFACE}" "${OUT}/dnsmasq.conf"

if command -v dnsmasq >/dev/null 2>&1; then
  if dnsmasq --test --conf-file="${OUT}/dnsmasq.conf" >/dev/null 2>&1; then
    echo "dnsmasq --test: OK"
  else
    echo "warn: dnsmasq --test failed on this host" >&2
  fi
else
  echo "dnsmasq: not installed here (required on the Pi)"
fi

if command -v hostapd >/dev/null 2>&1; then
  echo "hostapd: present on PATH"
else
  echo "hostapd: not installed here (required on the Pi)"
fi

echo "bash -n..."
bash -n "${SCRIPT_DIR}/lib.sh"
bash -n "${SCRIPT_DIR}/render_config.sh"
bash -n "${SCRIPT_DIR}/setup_ap.sh"
bash -n "${SCRIPT_DIR}/teardown_ap.sh"
bash -n "${SCRIPT_DIR}/verify_ap.sh"
bash -n "${SCRIPT_DIR}/check_ap.sh"

# If the developer already created .env, also try a full render (catch bad local values).
if [[ -f "${AP_DIR}/.env" ]]; then
  echo "also rendering with host_node/ap/.env ..."
  "${SCRIPT_DIR}/render_config.sh" "${OUT}/from-dotenv" >/dev/null
fi

echo "OK — AP templates and scripts passed offline checks"
