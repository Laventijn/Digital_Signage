#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/digitalsignage/digitalsignage.conf}"

read_config_value() {
  local key="$1"
  local file="$2"
  [ -f "${file}" ] || return 0
  awk -F= -v key="${key}" '
    /^[[:space:]]*#/ { next }
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value=$0
      sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/^'\''|'\''$/, "", value)
      print value
      exit
    }
  ' "${file}"
}

NETWORK_CHECK_HOST="$(read_config_value NETWORK_CHECK_HOST "${CONFIG_FILE}")"
NETWORK_CHECK_TIMEOUT="$(read_config_value NETWORK_CHECK_TIMEOUT "${CONFIG_FILE}")"
NETWORK_CHECK_HOST="${NETWORK_CHECK_HOST:-1.1.1.1}"
NETWORK_CHECK_TIMEOUT="${NETWORK_CHECK_TIMEOUT:-3}"

ping -c 1 -W "${NETWORK_CHECK_TIMEOUT}" "${NETWORK_CHECK_HOST}" >/dev/null
