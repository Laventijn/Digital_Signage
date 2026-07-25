#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/digitalsignage"
CONFIG_FILE="/etc/digitalsignage/digitalsignage.conf"

if [ "${EUID}" -ne 0 ]; then
  echo "Voer deze upgrade uit als root." >&2
  exit 1
fi

KIOSK_USER="bloemkool"
if [ -f "${CONFIG_FILE}" ]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y python3 python3-websocket
else
  echo "Waarschuwing: apt-get niet gevonden; installeer python3 en python3-websocket handmatig." >&2
fi

mkdir -p "${INSTALL_DIR}"
cp -R "${PROJECT_ROOT}/scripts" "${INSTALL_DIR}/"
cp -R "${PROJECT_ROOT}/web" "${INSTALL_DIR}/"
cp "${PROJECT_ROOT}/services/digitalsignage-healthcheck.service" /etc/systemd/system/
cp "${PROJECT_ROOT}/services/digitalsignage-healthcheck.timer" /etc/systemd/system/
chmod +x "${INSTALL_DIR}/scripts/"*.sh
chmod +x "${INSTALL_DIR}/scripts/refresh-presentation.py"

passwd_entry="$(getent passwd "${KIOSK_USER}" || true)"
if [ -z "${passwd_entry}" ]; then
  echo "Kioskgebruiker '${KIOSK_USER}' bestaat niet. User-units zijn niet bijgewerkt." >&2
else
  user_home="$(printf '%s' "${passwd_entry}" | cut -d: -f6)"
  user_uid="$(printf '%s' "${passwd_entry}" | cut -d: -f3)"
  user_unit_dir="${user_home}/.config/systemd/user"
  mkdir -p "${user_unit_dir}"
  cp "${PROJECT_ROOT}/services/digitalsignage-kiosk.service" "${user_unit_dir}/"
  cp "${PROJECT_ROOT}/services/digitalsignage-refresh.service" "${user_unit_dir}/"
  cp "${PROJECT_ROOT}/services/digitalsignage-refresh.timer" "${user_unit_dir}/"
  chown -R "${KIOSK_USER}:${KIOSK_USER}" "${user_home}/.config"

  user_runtime="/run/user/${user_uid}"
  user_bus="${user_runtime}/bus"
  if [ -S "${user_bus}" ]; then
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user daemon-reload
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user enable --now digitalsignage-kiosk.service
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user enable --now digitalsignage-refresh.timer
  else
    echo "Geen actieve usersessie gevonden voor '${KIOSK_USER}'; user-services zijn bijgewerkt maar niet gestart."
    echo "Start na aanmelden als '${KIOSK_USER}':"
    echo "  systemctl --user daemon-reload"
    echo "  systemctl --user enable --now digitalsignage-kiosk.service"
    echo "  systemctl --user enable --now digitalsignage-refresh.timer"
  fi
fi

systemctl daemon-reload

echo "Upgrade klaar."
