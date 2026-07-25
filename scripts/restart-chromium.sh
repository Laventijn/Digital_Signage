#!/usr/bin/env bash
set -Eeuo pipefail

pkill -f "/usr/bin/chromium.*--kiosk" 2>/dev/null || true
systemctl --user restart digitalsignage-kiosk.service
