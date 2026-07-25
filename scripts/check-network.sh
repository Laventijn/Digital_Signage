#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/digitalsignage/digitalsignage.conf}"

if [ -f "${CONFIG_FILE}" ]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

NETWORK_CHECK_HOST="${NETWORK_CHECK_HOST:-1.1.1.1}"
NETWORK_CHECK_TIMEOUT="${NETWORK_CHECK_TIMEOUT:-3}"

ping -c 1 -W "${NETWORK_CHECK_TIMEOUT}" "${NETWORK_CHECK_HOST}" >/dev/null
