#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/digitalsignage"
CONFIG_DIR="/etc/digitalsignage"
CONFIG_FILE="${CONFIG_DIR}/digitalsignage.conf"
CONFIG_DEFAULTS=(
  "CONTENT_MODE=\"presentation\""
  "CONTENT_URL=\"\""
  "SCREENSHOT_CACHE_ENABLED=true"
  "SCREENSHOT_CACHE_REFRESH_SECONDS=900"
  "SCREENSHOT_CAPTURE_WIDTH=1920"
  "SCREENSHOT_CAPTURE_HEIGHT=1080"
  "SCREENSHOT_CAPTURE_DEBUG_PORT=9333"
  "SCREENSHOT_STABLE_GAP_MS=400"
  "SCREENSHOT_CHANGE_POLL_MS=500"
  "SCREENSHOT_TRANSITION_WAIT_MS=750"
  "SCREENSHOT_MAX_SLIDES=100"
  "SCREENSHOT_MAX_CAPTURE_SECONDS=900"
  "SCREENSHOT_MAX_CONSECUTIVE_FAILURES=10"
  "SCREENSHOT_DEBUG_STABILITY=false"
  "SCREENSHOT_SINGLE_SLIDE_CONFIRM_SECONDS=15"
  "SCREENSHOT_IMAGE_DIFFERENCE_PERCENT=2"
  "SCREENSHOT_CACHE_KEEP_VERSIONS=2"
  "OFFLINE_WATERMARK_TEXT=\"Offline modus\""
  "WEBSITE_OFFLINE_CAPTURE_MODE=\"latest\""
  "HEALTH_CHECK_SECONDS=15"
  "OFFLINE_AFTER_SECONDS=45"
  "CONNECTIVITY_TIMEOUT_SECONDS=5"
)

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
    apt-get install -y curl python3 python3-websocket
  else
    echo "Waarschuwing: apt-get niet gevonden; installeer curl, python3 en python3-websocket handmatig." >&2
  fi
}

load_config() {
  KIOSK_USER="bloemkool"
  REFRESH_SECONDS="300"
  HEALTH_CHECK_SECONDS="60"
  SCREENSHOT_CACHE_REFRESH_SECONDS="900"
  if [ -f "${CONFIG_FILE}" ]; then
    configured_kiosk_user="$(read_config_value KIOSK_USER "${CONFIG_FILE}")"
    configured_refresh_seconds="$(read_config_value REFRESH_SECONDS "${CONFIG_FILE}")"
    configured_health_seconds="$(read_config_value HEALTH_CHECK_SECONDS "${CONFIG_FILE}")"
    configured_screenshot_seconds="$(read_config_value SCREENSHOT_CACHE_REFRESH_SECONDS "${CONFIG_FILE}")"
    [ -n "${configured_kiosk_user}" ] && KIOSK_USER="${configured_kiosk_user}"
    [ -n "${configured_refresh_seconds}" ] && REFRESH_SECONDS="${configured_refresh_seconds}"
    [ -n "${configured_health_seconds}" ] && HEALTH_CHECK_SECONDS="${configured_health_seconds}"
    [ -n "${configured_screenshot_seconds}" ] && SCREENSHOT_CACHE_REFRESH_SECONDS="${configured_screenshot_seconds}"
  fi
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

active_config_has_key() {
  local key="$1"
  local file="$2"
  awk -F= -v key="${key}" '
    /^[[:space:]]*#/ { next }
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" { found=1 }
    END { exit found ? 0 : 1 }
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

refresh_interval() {
  case "${REFRESH_SECONDS:-}" in
    ''|*[!0-9]*|0) printf '300' ;;
    *) printf '%s' "${REFRESH_SECONDS}" ;;
  esac
}

health_interval() {
  case "${HEALTH_CHECK_SECONDS:-}" in
    ''|*[!0-9]*|0) printf '60' ;;
    *) printf '%s' "${HEALTH_CHECK_SECONDS}" ;;
  esac
}

screenshot_interval() {
  case "${SCREENSHOT_CACHE_REFRESH_SECONDS:-}" in
    ''|*[!0-9]*|0) printf '900' ;;
    *) printf '%s' "${SCREENSHOT_CACHE_REFRESH_SECONDS}" ;;
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

write_health_timer_dropin() {
  local dropin_dir="$1"
  local interval
  interval="$(health_interval)"
  install -d -m 0755 "${dropin_dir}"
  cat > "${dropin_dir}/interval.conf" <<EOF
[Timer]
OnBootSec=
OnActiveSec=2min
OnUnitInactiveSec=${interval}s
EOF
}

write_screenshot_timer() {
  local timer_file="$1"
  local interval
  interval="$(screenshot_interval)"
  cat > "${timer_file}" <<EOF
[Unit]
Description=Digital Signage periodieke screenshotcache

[Timer]
OnBootSec=
OnActiveSec=
OnUnitActiveSec=
OnUnitInactiveSec=
OnBootSec=${interval}s
OnUnitInactiveSec=${interval}s
AccuracySec=60s
Unit=digitalsignage-screenshot-cache.service

[Install]
WantedBy=timers.target
EOF
}

write_screenshot_timer_dropin() {
  local dropin_dir="$1"
  local interval
  interval="$(screenshot_interval)"
  install -d -m 0755 "${dropin_dir}"
  cat > "${dropin_dir}/interval.conf" <<EOF
[Timer]
OnBootSec=
OnActiveSec=
OnUnitActiveSec=
OnUnitInactiveSec=
OnBootSec=${interval}s
OnUnitInactiveSec=${interval}s
EOF
}

install_project_files() {
  local script_file
  install -d -m 0755 "${INSTALL_DIR}/scripts"
  while IFS= read -r -d '' script_file; do
    install -m 0755 "${script_file}" "${INSTALL_DIR}/scripts/$(basename "${script_file}")"
  done < <(find "${PROJECT_ROOT}/scripts" -maxdepth 1 -type f -print0)
  install -d -m 0755 "${INSTALL_DIR}/assets/wallpapers"
  install -m 0644 "${PROJECT_ROOT}/assets/wallpapers/digitalsignage-background.png" "${INSTALL_DIR}/assets/wallpapers/digitalsignage-background.png"
  install -d -m 0755 "${INSTALL_DIR}/offline"
  install -m 0644 "${PROJECT_ROOT}/assets/offline/index.html" "${INSTALL_DIR}/offline/index.html"
  install -m 0644 "${PROJECT_ROOT}/assets/offline/offline.css" "${INSTALL_DIR}/offline/offline.css"
  cp -R "${PROJECT_ROOT}/web" "${INSTALL_DIR}/"
  install -d -m 0755 "${INSTALL_DIR}/screenshot-player"
  install -m 0644 "${PROJECT_ROOT}/assets/screenshot-player/index.html" "${INSTALL_DIR}/screenshot-player/index.html"
  install -m 0644 "${PROJECT_ROOT}/assets/screenshot-player/player.css" "${INSTALL_DIR}/screenshot-player/player.css"
  install -m 0644 "${PROJECT_ROOT}/assets/screenshot-player/player.js" "${INSTALL_DIR}/screenshot-player/player.js"
}

configure_desktop_background() {
  # De desktopachtergrond wordt ingesteld voordat services starten. Daardoor is
  # de vaste achtergrond al beschikbaar wanneer Chromium later opstart of kort
  # opnieuw start.
  "${INSTALL_DIR}/scripts/configure-desktop-background.sh"
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
  cp "${PROJECT_ROOT}/services/digitalsignage-health.service" "${user_unit_dir}/"
  cp "${PROJECT_ROOT}/services/digitalsignage-health.timer" "${user_unit_dir}/"
  cp "${PROJECT_ROOT}/services/digitalsignage-screenshot-cache.service" "${user_unit_dir}/"
  write_refresh_timer "${user_unit_dir}/digitalsignage-refresh.timer"
  write_health_timer_dropin "${user_unit_dir}/digitalsignage-health.timer.d"
  write_screenshot_timer "${user_unit_dir}/digitalsignage-screenshot-cache.timer"
  write_screenshot_timer_dropin "${user_unit_dir}/digitalsignage-screenshot-cache.timer.d"
  chown -R "${KIOSK_USER}:${user_group}" "${user_home}/.config"

  # Maak de gebruikersstatusmap voordat user-services starten. Resource-logging
  # en health-check schrijven hier hun state en logs; zonder bestaande map kan
  # systemd sandboxing falen met status=226/NAMESPACE.
  user_state_dir="${user_home}/.local/state/digitalsignage"
  user_cache_dir="${user_home}/.local/share/digitalsignage/screenshot-cache"
  install -d -m 0755 -o "${KIOSK_USER}" -g "${user_group}" "${user_state_dir}"
  install -d -m 0755 -o "${KIOSK_USER}" -g "${user_group}" "${user_cache_dir}" "${user_cache_dir}/versions" "${user_cache_dir}/work"

  user_runtime="/run/user/${user_uid}"
  user_bus="${user_runtime}/bus"
  if [ -S "${user_bus}" ]; then
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user daemon-reload
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user enable --now digitalsignage-kiosk.service
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user enable --now digitalsignage-refresh.timer
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user restart digitalsignage-refresh.timer
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user enable --now digitalsignage-resource-log.timer
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user enable --now digitalsignage-health.timer
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user restart digitalsignage-health.timer
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user enable --now digitalsignage-screenshot-cache.timer
    runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${user_runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" systemctl --user restart digitalsignage-screenshot-cache.timer
  else
    echo "Geen actieve usersessie gevonden voor '${KIOSK_USER}'; user-services zijn geinstalleerd maar niet gestart."
    echo "Start na aanmelden als '${KIOSK_USER}':"
    echo "  systemctl --user daemon-reload"
    echo "  systemctl --user enable --now digitalsignage-kiosk.service"
    echo "  systemctl --user enable --now digitalsignage-refresh.timer"
    echo "  systemctl --user enable --now digitalsignage-resource-log.timer"
    echo "  systemctl --user enable --now digitalsignage-health.timer"
    echo "  systemctl --user enable --now digitalsignage-screenshot-cache.timer"
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
append_missing_config_defaults "${CONFIG_FILE}"

load_config
configure_desktop_background
install_user_units

systemctl daemon-reload
systemctl disable --now digitalsignage-healthcheck.timer 2>/dev/null || true

echo "Installatie klaar. Controleer ${CONFIG_FILE} en start de kioskservices waar nodig."
