#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/digitalsignage"

if [ "${EUID}" -ne 0 ]; then
  echo "Run this upgrade as root." >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}"
cp -R "${PROJECT_ROOT}/scripts" "${INSTALL_DIR}/"
cp -R "${PROJECT_ROOT}/web" "${INSTALL_DIR}/"
cp "${PROJECT_ROOT}/services/"*.service /etc/systemd/system/
cp "${PROJECT_ROOT}/services/"*.timer /etc/systemd/system/
chmod +x "${INSTALL_DIR}/scripts/"*.sh

systemctl daemon-reload
systemctl restart digitalsignage-kiosk.service || true

echo "Upgrade complete."
