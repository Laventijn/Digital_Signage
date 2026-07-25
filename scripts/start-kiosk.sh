#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/digitalsignage/digitalsignage.conf}"

if [ -f "${CONFIG_FILE}" ]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

SIGNAGE_URL="${SIGNAGE_URL:-https://example.org}"
OFFLINE_URL="${OFFLINE_URL:-file:///opt/digitalsignage/web/offline/index.html}"
CHROMIUM_BIN="${CHROMIUM_BIN:-chromium-browser}"
DISPLAY_ID="${DISPLAY_ID:-:0}"

export DISPLAY="${DISPLAY_ID}"

URL="${SIGNAGE_URL}"
if ! /opt/digitalsignage/scripts/check-network.sh >/dev/null 2>&1; then
  URL="${OFFLINE_URL}"
fi

exec "${CHROMIUM_BIN}" \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --autoplay-policy=no-user-gesture-required \
  "${URL}"
