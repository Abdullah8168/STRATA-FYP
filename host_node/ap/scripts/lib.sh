#!/usr/bin/env bash
# Shared helpers for STRATA AP scripts (Iteration 1).
# shellcheck shell=bash

set -euo pipefail

ap_load_env() {
  local ap_dir="$1"
  local env_file="${ap_dir}/.env"
  if [[ ! -f "${env_file}" ]]; then
    echo "error: missing ${env_file}" >&2
    echo "       cp ${ap_dir}/env.example ${env_file}  && edit secrets" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1091
  source "${env_file}"
  set +a

  : "${AP_IFACE:=wlan0}"
  : "${WAN_IFACE:=eth0}"
  : "${SSID:=STRATA-Pi-01}"
  : "${WPA_PASSPHRASE:?WPA_PASSPHRASE must be set in .env}"
  : "${COUNTRY_CODE:=PK}"
  : "${HW_MODE:=g}"
  : "${CHANNEL:=6}"
  : "${AP_ADDRESS:=192.168.50.1}"
  : "${AP_PREFIX:=24}"
  : "${DHCP_RANGE_START:=192.168.50.50}"
  : "${DHCP_RANGE_END:=192.168.50.200}"
  : "${DHCP_LEASE:=12h}"
  : "${UPSTREAM_DNS_1:=1.1.1.1}"
  : "${UPSTREAM_DNS_2:=8.8.8.8}"
  : "${GENERATED_DIR:=/etc/strata/ap}"
  : "${ENABLE_LAB_NAT:=false}"
}

ap_require_passphrase() {
  if [[ "${WPA_PASSPHRASE}" == "CHANGE_ME_DEV_ONLY" ]]; then
    echo "error: WPA_PASSPHRASE is still the placeholder CHANGE_ME_DEV_ONLY" >&2
    echo "       edit host_node/ap/.env and set a real 8–63 char passphrase" >&2
    return 1
  fi
  local len=${#WPA_PASSPHRASE}
  if (( len < 8 || len > 63 )); then
    echo "error: WPA_PASSPHRASE length must be 8–63 (got ${len})" >&2
    return 1
  fi
}

ap_iface_exists() {
  local iface="$1"
  if [[ ! -d "/sys/class/net/${iface}" ]]; then
    echo "error: wireless/AP interface '${iface}' not found under /sys/class/net" >&2
    echo "       available interfaces:" >&2
    ls /sys/class/net >&2 || true
    echo "       set AP_IFACE in host_node/ap/.env to match your NIC" >&2
    return 1
  fi
}

# Substitute __KEY__ placeholders. Never prints the passphrase.
ap_render_file() {
  local template="$1"
  local output="$2"
  local tmp
  tmp="$(mktemp)"
  # Escape replacement strings for sed (& and \).
  _esc() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

  sed \
    -e "s/__AP_IFACE__/$(_esc "${AP_IFACE}")/g" \
    -e "s/__SSID__/$(_esc "${SSID}")/g" \
    -e "s/__WPA_PASSPHRASE__/$(_esc "${WPA_PASSPHRASE}")/g" \
    -e "s/__COUNTRY_CODE__/$(_esc "${COUNTRY_CODE}")/g" \
    -e "s/__HW_MODE__/$(_esc "${HW_MODE}")/g" \
    -e "s/__CHANNEL__/$(_esc "${CHANNEL}")/g" \
    -e "s/__AP_ADDRESS__/$(_esc "${AP_ADDRESS}")/g" \
    -e "s/__DHCP_RANGE_START__/$(_esc "${DHCP_RANGE_START}")/g" \
    -e "s/__DHCP_RANGE_END__/$(_esc "${DHCP_RANGE_END}")/g" \
    -e "s/__DHCP_LEASE__/$(_esc "${DHCP_LEASE}")/g" \
    -e "s/__UPSTREAM_DNS_1__/$(_esc "${UPSTREAM_DNS_1}")/g" \
    -e "s/__UPSTREAM_DNS_2__/$(_esc "${UPSTREAM_DNS_2}")/g" \
    "${template}" > "${tmp}"

  mkdir -p "$(dirname "${output}")"
  # hostapd.conf contains the passphrase — mode 600
  if [[ "$(basename "${output}")" == hostapd.conf ]]; then
    install -m 600 "${tmp}" "${output}"
  else
    install -m 644 "${tmp}" "${output}"
  fi
  rm -f "${tmp}"
}
