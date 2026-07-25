#!/usr/bin/env bash
set -euo pipefail

if ! /opt/digitalsignage/scripts/check-network.sh >/dev/null 2>&1; then
  echo "Network check failed." >&2
  exit 1
fi

if ! pgrep -f "chromium.*--kiosk" >/dev/null; then
  echo "Chromium kiosk process not found; restarting service." >&2
  systemctl restart digitalsignage-kiosk.service
fi
