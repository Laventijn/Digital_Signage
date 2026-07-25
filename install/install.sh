#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/digitalsignage"
CONFIG_DIR="/etc/digitalsignage"
SERVICE_DIR="/etc/systemd/system"

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Run this installer as root." >&2
    exit 1
  fi
}

require_root

mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}"
cp -R "${PROJECT_ROOT}/scripts" "${INSTALL_DIR}/"
cp -R "${PROJECT_ROOT}/web" "${INSTALL_DIR}/"

if [ ! -f "${CONFIG_DIR}/digitalsignage.conf" ]; then
  cp "${PROJECT_ROOT}/config/digitalsignage.conf.example" "${CONFIG_DIR}/digitalsignage.conf"
fi

cp "${PROJECT_ROOT}/services/"*.service "${SERVICE_DIR}/"
cp "${PROJECT_ROOT}/services/"*.timer "${SERVICE_DIR}/"
chmod +x "${INSTALL_DIR}/scripts/"*.sh

systemctl daemon-reload
systemctl enable digitalsignage-kiosk.service
systemctl enable digitalsignage-healthcheck.timer

echo "Installation complete. Edit ${CONFIG_DIR}/digitalsignage.conf and start the services."
