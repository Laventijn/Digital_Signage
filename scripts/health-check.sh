#!/usr/bin/env bash
set -Eeuo pipefail

if ! /opt/digitalsignage/scripts/check-network.sh >/dev/null 2>&1; then
  echo "Netwerkcontrole mislukt." >&2
  exit 1
fi

if ! pgrep -f "/usr/bin/chromium.*--kiosk" >/dev/null; then
  echo "Chromium-kioskproces niet gevonden; controleer de user-service digitalsignage-kiosk.service." >&2
  exit 1
fi
