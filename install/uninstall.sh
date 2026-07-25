#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Run this uninstaller as root." >&2
  exit 1
fi

systemctl disable --now digitalsignage-kiosk.service 2>/dev/null || true
systemctl disable --now digitalsignage-healthcheck.timer 2>/dev/null || true

rm -f /etc/systemd/system/digitalsignage-kiosk.service
rm -f /etc/systemd/system/digitalsignage-healthcheck.service
rm -f /etc/systemd/system/digitalsignage-healthcheck.timer
rm -rf /opt/digitalsignage

systemctl daemon-reload

echo "Uninstalled. Configuration in /etc/digitalsignage was left in place."
