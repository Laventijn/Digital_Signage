#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/digitalsignage/digitalsignage.conf"

if [ "${EUID}" -ne 0 ]; then
  echo "Voer deze uninstaller uit als root." >&2
  exit 1
fi

KIOSK_USER="bloemkool"
if [ -f "${CONFIG_FILE}" ]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

passwd_entry="$(getent passwd "${KIOSK_USER}" || true)"
if [ -n "${passwd_entry}" ]; then
  user_home="$(printf '%s' "${passwd_entry}" | cut -d: -f6)"
  user_uid="$(printf '%s' "${passwd_entry}" | cut -d: -f3)"
  user_runtime="/run/user/${user_uid}"
  user_bus="${user_runtime}/bus"
  if [ -S "${user_bus}" ]; then
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user disable --now digitalsignage-resource-log.timer 2>/dev/null || true
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user disable --now digitalsignage-refresh.timer 2>/dev/null || true
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user disable --now digitalsignage-kiosk.service 2>/dev/null || true
  fi
  rm -f "${user_home}/.config/systemd/user/digitalsignage-kiosk.service"
  rm -f "${user_home}/.config/systemd/user/digitalsignage-refresh.service"
  rm -f "${user_home}/.config/systemd/user/digitalsignage-refresh.timer"
  rm -f "${user_home}/.config/systemd/user/digitalsignage-resource-log.service"
  rm -f "${user_home}/.config/systemd/user/digitalsignage-resource-log.timer"
  chown -R "${KIOSK_USER}:${KIOSK_USER}" "${user_home}/.config" 2>/dev/null || true
  if [ -S "${user_bus}" ]; then
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user daemon-reload 2>/dev/null || true
  fi
fi

systemctl disable --now digitalsignage-kiosk.service 2>/dev/null || true
systemctl disable --now digitalsignage-healthcheck.timer 2>/dev/null || true

rm -f /etc/systemd/system/digitalsignage-kiosk.service
rm -f /etc/systemd/system/digitalsignage-healthcheck.service
rm -f /etc/systemd/system/digitalsignage-healthcheck.timer
rm -rf /opt/digitalsignage

systemctl daemon-reload

echo "Verwijderd. Configuratie in /etc/digitalsignage en swaplogs blijven staan."
echo "Een ICT-medewerker kan het log handmatig verwijderen met:"
echo "  rm -f ~/.local/state/digitalsignage/swap.log ~/.local/state/digitalsignage/swap.log.1"
