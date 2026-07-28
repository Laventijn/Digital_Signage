#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/digitalsignage"
CONFIG_FILE="/etc/digitalsignage/digitalsignage.conf"
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
  "SCREENSHOT_SINGLE_SLIDE_CONFIRM_SECONDS=15"
  "SCREENSHOT_IMAGE_DIFFERENCE_PERCENT=2"
  "SCREENSHOT_CACHE_KEEP_VERSIONS=2"
  "OFFLINE_WATERMARK_TEXT=\"Offline modus\""
  "WEBSITE_OFFLINE_CAPTURE_MODE=\"latest\""
  "REFRESH_SECONDS=300"
  "RESOURCE_LOG_RETENTION_DAYS=3"
  "HEALTH_CHECK_SECONDS=15"
  "HEALTH_FAILURE_THRESHOLD=3"
  "HEALTH_RESTART_COOLDOWN_SECONDS=600"
  "HEALTH_HTTP_TIMEOUT_SECONDS=5"
  "HEALTH_STARTUP_GRACE_SECONDS=90"
  "HEALTH_LOG_RETENTION_DAYS=3"
  "HEALTH_LOG_MAX_BYTES=5242880"
  "OFFLINE_PAGE_ENABLED=true"
  "OFFLINE_AFTER_SECONDS=45"
  "ONLINE_CONFIRM_SECONDS=30"
  "CONNECTIVITY_CHECK_URL=\"https://clients3.google.com/generate_204\""
  "CONNECTIVITY_TIMEOUT_SECONDS=5"
  "OFFLINE_PAGE_URL=\"file:///opt/digitalsignage/offline/index.html\""
  "DESKTOP_BACKGROUND_ENABLED=true"
  "DESKTOP_BACKGROUND_FILE=\"/opt/digitalsignage/assets/wallpapers/digitalsignage-background.png\""
  "DESKTOP_BACKGROUND_MODE=zoom"
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
HEALTH_CHECK_SECONDS="60"
SCREENSHOT_CACHE_REFRESH_SECONDS="900"
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
  configured_health_seconds="$(read_config_value HEALTH_CHECK_SECONDS "${CONFIG_FILE}")"
  if [ -n "${configured_health_seconds}" ]; then
    HEALTH_CHECK_SECONDS="${configured_health_seconds}"
  fi
  configured_screenshot_seconds="$(read_config_value SCREENSHOT_CACHE_REFRESH_SECONDS "${CONFIG_FILE}")"
  if [ -n "${configured_screenshot_seconds}" ]; then
    SCREENSHOT_CACHE_REFRESH_SECONDS="${configured_screenshot_seconds}"
  fi
fi

if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y curl python3 python3-websocket
else
  echo "Waarschuwing: apt-get niet gevonden; installeer curl, python3 en python3-websocket handmatig." >&2
fi

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
  # De desktopachtergrond wordt bij upgrade opnieuw idempotent gezet voordat
  # user-services herladen. Zo krijgt een oudere installatie de visuele fallback
  # zonder kiosk-, refresh- of healthlogica te wijzigen.
  "${INSTALL_DIR}/scripts/configure-desktop-background.sh"
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
OnBootSec=${interval}s
OnUnitInactiveSec=${interval}s
AccuracySec=60s
Unit=digitalsignage-screenshot-cache.service

[Install]
WantedBy=timers.target
EOF
}

mkdir -p "${INSTALL_DIR}"
install_project_files
configure_desktop_background

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
  cp "${PROJECT_ROOT}/services/digitalsignage-health.service" "${user_unit_dir}/"
  cp "${PROJECT_ROOT}/services/digitalsignage-health.timer" "${user_unit_dir}/"
  cp "${PROJECT_ROOT}/services/digitalsignage-screenshot-cache.service" "${user_unit_dir}/"
  write_refresh_timer "${user_unit_dir}/digitalsignage-refresh.timer"
  write_health_timer_dropin "${user_unit_dir}/digitalsignage-health.timer.d"
  write_screenshot_timer "${user_unit_dir}/digitalsignage-screenshot-cache.timer"
  chown -R "${KIOSK_USER}:${user_group}" "${user_home}/.config"

  # Maak de gebruikersstatusmap voordat user-services opnieuw geladen of gestart
  # worden. Resource-logging en health-check schrijven hier hun state en logs;
  # deze stap herstelt oudere installaties en voorkomt status=226/NAMESPACE.
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
    echo "Geen actieve usersessie gevonden voor '${KIOSK_USER}'; user-services zijn bijgewerkt maar niet gestart."
    echo "Start na aanmelden als '${KIOSK_USER}':"
    echo "  systemctl --user daemon-reload"
    echo "  systemctl --user enable --now digitalsignage-kiosk.service"
    echo "  systemctl --user enable --now digitalsignage-refresh.timer"
    echo "  systemctl --user enable --now digitalsignage-resource-log.timer"
    echo "  systemctl --user enable --now digitalsignage-health.timer"
    echo "  systemctl --user enable --now digitalsignage-screenshot-cache.timer"
  fi
fi

systemctl daemon-reload
systemctl disable --now digitalsignage-healthcheck.timer 2>/dev/null || true

echo "Upgrade klaar."
