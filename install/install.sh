#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/digitalsignage"
CONFIG_DIR="/etc/digitalsignage"
SERVICE_DIR="/etc/systemd/system"
CONFIG_FILE="${CONFIG_DIR}/digitalsignage.conf"

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Voer deze installer uit als root." >&2
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Vereist commando ontbreekt: $1" >&2
    exit 1
  fi
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y python3 python3-websocket
  else
    echo "Waarschuwing: apt-get niet gevonden; installeer python3 en python3-websocket handmatig." >&2
  fi
}

load_config() {
  KIOSK_USER="bloemkool"
  REFRESH_SECONDS="300"
  if [ -f "${CONFIG_FILE}" ]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
  fi
}

refresh_interval() {
  case "${REFRESH_SECONDS:-}" in
    ''|*[!0-9]*|0) printf '300' ;;
    *) printf '%s' "${REFRESH_SECONDS}" ;;
  esac
}

write_refresh_timer() {
  local timer_file="$1"
  local interval
  interval="$(refresh_interval)"
  cat > "${timer_file}" <<EOF
[Unit]
Description=Digital Signage periodieke presentatie-refresh

[Timer]
OnBootSec=${interval}s
OnUnitActiveSec=${interval}s
AccuracySec=30s
Unit=digitalsignage-refresh.service

[Install]
WantedBy=timers.target
EOF
}

install_project_files() {
  local script_file
  install -d -m 0755 "${INSTALL_DIR}/scripts"
  while IFS= read -r -d '' script_file; do
    install -m 0755 "${script_file}" "${INSTALL_DIR}/scripts/$(basename "${script_file}")"
  done < <(find "${PROJECT_ROOT}/scripts" -maxdepth 1 -type f -print0)
  cp -R "${PROJECT_ROOT}/web" "${INSTALL_DIR}/"
}

install_user_units() {
  local passwd_entry user_home user_uid user_gid user_group user_runtime user_bus user_unit_dir user_state_dir

  # Bepaal de kiosk-homefolder en primaire groep uit de systeemaccountdatabase.
  # Zo wordt geen enkele homefolder of UID/GID hardcoded.
  passwd_entry="$(getent passwd "${KIOSK_USER}" || true)"
  if [ -z "${passwd_entry}" ]; then
    echo "Kioskgebruiker '${KIOSK_USER}' bestaat niet. Maak de gebruiker aan of pas KIOSK_USER aan." >&2
    exit 1
  fi
  user_home="$(printf '%s' "${passwd_entry}" | cut -d: -f6)"
  user_uid="$(printf '%s' "${passwd_entry}" | cut -d: -f3)"
  user_gid="$(printf '%s' "${passwd_entry}" | cut -d: -f4)"
  user_group="$(getent group "${user_gid}" | cut -d: -f1 || true)"
  if [ -z "${user_group}" ]; then
    echo "Primaire groep voor kioskgebruiker '${KIOSK_USER}' niet gevonden." >&2
    exit 1
  fi

  user_unit_dir="${user_home}/.config/systemd/user"
  mkdir -p "${user_unit_dir}"
  cp "${PROJECT_ROOT}/services/digitalsignage-kiosk.service" "${user_unit_dir}/"
  cp "${PROJECT_ROOT}/services/digitalsignage-refresh.service" "${user_unit_dir}/"
  cp "${PROJECT_ROOT}/services/digitalsignage-resource-log.service" "${user_unit_dir}/"
  cp "${PROJECT_ROOT}/services/digitalsignage-resource-log.timer" "${user_unit_dir}/"
  write_refresh_timer "${user_unit_dir}/digitalsignage-refresh.timer"
  chown -R "${KIOSK_USER}:${KIOSK_USER}" "${user_home}/.config"

  # Maak de gebruikersstatusmap voordat user-services starten. De resource-
  # logservice gebruikt deze map voor swap.log; zonder bestaande map kan
  # systemd sandboxing falen met status=226/NAMESPACE.
  user_state_dir="${user_home}/.local/state/digitalsignage"
  install -d -m 0755 -o "${KIOSK_USER}" -g "${user_group}" "${user_state_dir}"

  user_runtime="/run/user/${user_uid}"
  user_bus="${user_runtime}/bus"
  if [ -S "${user_bus}" ]; then
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user daemon-reload
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user enable --now digitalsignage-kiosk.service
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user enable --now digitalsignage-refresh.timer
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user restart digitalsignage-refresh.timer
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user enable --now digitalsignage-resource-log.timer
  else
    echo "Geen actieve usersessie gevonden voor '${KIOSK_USER}'; user-services zijn geinstalleerd maar niet gestart."
    echo "Start na aanmelden als '${KIOSK_USER}':"
    echo "  systemctl --user daemon-reload"
    echo "  systemctl --user enable --now digitalsignage-kiosk.service"
    echo "  systemctl --user enable --now digitalsignage-refresh.timer"
    echo "  systemctl --user enable --now digitalsignage-resource-log.timer"
  fi
}

require_root
require_command cp
require_command find
require_command getent
require_command install
require_command mkdir
require_command runuser
require_command systemctl
install_packages

mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}"
install_project_files

if [ ! -f "${CONFIG_FILE}" ]; then
  cp "${PROJECT_ROOT}/config/digitalsignage.conf.example" "${CONFIG_FILE}"
fi

load_config
cp "${PROJECT_ROOT}/services/digitalsignage-healthcheck.service" "${SERVICE_DIR}/"
cp "${PROJECT_ROOT}/services/digitalsignage-healthcheck.timer" "${SERVICE_DIR}/"
install_user_units

systemctl daemon-reload
systemctl disable --now digitalsignage-healthcheck.timer 2>/dev/null || true

echo "Installatie klaar. Controleer ${CONFIG_FILE} en start de kioskservices waar nodig."
