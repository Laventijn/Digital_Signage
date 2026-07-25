#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/digitalsignage"
CONFIG_FILE="/etc/digitalsignage/digitalsignage.conf"
CONFIG_DEFAULTS=(
  "REFRESH_SECONDS=300"
  "RESOURCE_LOG_RETENTION_DAYS=3"
)

active_config_has_key() {
  local key="$1"
  local file="$2"
  awk -F= -v key="${key}" '
    /^[[:space:]]*#/ { next }
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" { found=1 }
    END { exit found ? 0 : 1 }
  ' "${file}"
}

read_config_value() {
  local key="$1"
  local file="$2"
  awk -F= -v key="${key}" '
    /^[[:space:]]*#/ { next }
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value=$0
      sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/^'\''|'\''$/, "", value)
      print value
      exit
    }
  ' "${file}"
}

append_missing_config_defaults() {
  local file="$1"
  local default_entry key backup_file missing=0

  [ -f "${file}" ] || return 0

  for default_entry in "${CONFIG_DEFAULTS[@]}"; do
    key="${default_entry%%=*}"
    if ! active_config_has_key "${key}" "${file}"; then
      missing=1
    fi
  done

  [ "${missing}" -eq 1 ] || return 0

  backup_file="${file}.backup.$(date '+%Y%m%d-%H%M%S')"
  cp -p "${file}" "${backup_file}"
  echo "Backup gemaakt: ${backup_file}"

  for default_entry in "${CONFIG_DEFAULTS[@]}"; do
    key="${default_entry%%=*}"
    if ! active_config_has_key "${key}" "${file}"; then
      printf '\n%s\n' "${default_entry}" >> "${file}"
      echo "Configuratievariabele toegevoegd: ${key}"
    fi
  done
}

if [ "${DIGITALSIGNAGE_TEST_CONFIG_MERGE:-}" = "1" ]; then
  append_missing_config_defaults "${1:?configbestand ontbreekt}"
  exit 0
fi

if [ "${EUID}" -ne 0 ]; then
  echo "Voer deze upgrade uit als root." >&2
  exit 1
fi

KIOSK_USER="bloemkool"
REFRESH_SECONDS="300"
append_missing_config_defaults "${CONFIG_FILE}"
if [ -f "${CONFIG_FILE}" ]; then
  configured_kiosk_user="$(read_config_value KIOSK_USER "${CONFIG_FILE}")"
  if [ -n "${configured_kiosk_user}" ]; then
    KIOSK_USER="${configured_kiosk_user}"
  fi
  configured_refresh_seconds="$(read_config_value REFRESH_SECONDS "${CONFIG_FILE}")"
  if [ -n "${configured_refresh_seconds}" ]; then
    REFRESH_SECONDS="${configured_refresh_seconds}"
  fi
fi

if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y python3 python3-websocket
else
  echo "Waarschuwing: apt-get niet gevonden; installeer python3 en python3-websocket handmatig." >&2
fi

install_project_files() {
  local script_file
  install -d -m 0755 "${INSTALL_DIR}/scripts"
  while IFS= read -r -d '' script_file; do
    install -m 0755 "${script_file}" "${INSTALL_DIR}/scripts/$(basename "${script_file}")"
  done < <(find "${PROJECT_ROOT}/scripts" -maxdepth 1 -type f -print0)
  cp -R "${PROJECT_ROOT}/web" "${INSTALL_DIR}/"
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

mkdir -p "${INSTALL_DIR}"
install_project_files
cp "${PROJECT_ROOT}/services/digitalsignage-healthcheck.service" /etc/systemd/system/
cp "${PROJECT_ROOT}/services/digitalsignage-healthcheck.timer" /etc/systemd/system/

passwd_entry="$(getent passwd "${KIOSK_USER}" || true)"
if [ -z "${passwd_entry}" ]; then
  echo "Kioskgebruiker '${KIOSK_USER}' bestaat niet. User-units zijn niet bijgewerkt." >&2
else
  # Bepaal de kiosk-homefolder en primaire groep uit de systeemaccountdatabase.
  # Zo herstelt een upgrade ook oudere installaties zonder hardcoded homepad.
  user_home="$(printf '%s' "${passwd_entry}" | cut -d: -f6)"
  user_uid="$(printf '%s' "${passwd_entry}" | cut -d: -f3)"
  user_gid="$(printf '%s' "${passwd_entry}" | cut -d: -f4)"
  user_group="$(getent group "${user_gid}" | cut -d: -f1 || true)"
  if [ -z "${user_group}" ]; then
    echo "Primaire groep voor kioskgebruiker '${KIOSK_USER}' niet gevonden. User-units zijn niet bijgewerkt." >&2
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

  # Maak de gebruikersstatusmap voordat user-services opnieuw geladen of gestart
  # worden. De resource-logservice schrijft hier swap.log; deze stap herstelt
  # oudere installaties en voorkomt status=226/NAMESPACE.
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
    echo "Geen actieve usersessie gevonden voor '${KIOSK_USER}'; user-services zijn bijgewerkt maar niet gestart."
    echo "Start na aanmelden als '${KIOSK_USER}':"
    echo "  systemctl --user daemon-reload"
    echo "  systemctl --user enable --now digitalsignage-kiosk.service"
    echo "  systemctl --user enable --now digitalsignage-refresh.timer"
    echo "  systemctl --user enable --now digitalsignage-resource-log.timer"
  fi
fi

systemctl daemon-reload
systemctl disable --now digitalsignage-healthcheck.timer 2>/dev/null || true

echo "Upgrade klaar."
