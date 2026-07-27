#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR=/opt/digitalsignage
CONFIG_FILE=/etc/digitalsignage/digitalsignage.conf

[ "${EUID}" -eq 0 ] || { echo "Voer uit met sudo." >&2; exit 1; }
[ -f "${CONFIG_FILE}" ] || { echo "Configuratie ontbreekt: ${CONFIG_FILE}" >&2; exit 1; }

read_value() {
  awk -F= -v key="$1" '/^[[:space:]]*#/ {next} $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {v=$0;sub(/^[^=]*=/,"",v);gsub(/^[[:space:]]+|[[:space:]]+$/,"",v);gsub(/^"|"$/,"",v);print v;exit}' "${CONFIG_FILE}"
}
add_default() {
  local key="${1%%=*}"
  if ! awk -F= -v key="${key}" '/^[[:space:]]*#/ {next} $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {found=1} END {exit found?0:1}' "${CONFIG_FILE}"; then
    printf '\n%s\n' "$1" >> "${CONFIG_FILE}"
    echo "Configuratie toegevoegd: ${key}"
  fi
}

if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y python3 python3-requests python3-google-auth
fi

KIOSK_USER="$(read_value KIOSK_USER)"; KIOSK_USER="${KIOSK_USER:-bloemkool}"
CACHE_SECONDS="$(read_value PRESENTATION_CACHE_REFRESH_SECONDS)"; CACHE_SECONDS="${CACHE_SECONDS:-900}"
case "${CACHE_SECONDS}" in ''|*[!0-9]*|0) CACHE_SECONDS=900;; esac

backup="${CONFIG_FILE}.backup.presentation-cache.$(date +%Y%m%d-%H%M%S)"
cp -p "${CONFIG_FILE}" "${backup}"
for entry in \
  'CONTENT_MODE="presentation"' \
  'PRESENTATION_CACHE_ENABLED=true' \
  'PRESENTATION_CACHE_REFRESH_SECONDS=900' \
  'PRESENTATION_CACHE_INCLUDE_SKIPPED_SLIDES=false' \
  'PRESENTATION_CACHE_SLIDE_SECONDS=5' \
  'PRESENTATION_CACHE_HTTP_TIMEOUT_SECONDS=20' \
  'GOOGLE_SERVICE_ACCOUNT_FILE="/etc/digitalsignage/google-service-account.json"'; do add_default "${entry}"; done

group="$(id -gn "${KIOSK_USER}")"
home="$(getent passwd "${KIOSK_USER}" | cut -d: -f6)"
uid="$(id -u "${KIOSK_USER}")"
[ -n "${home}" ] || { echo "Kioskgebruiker ontbreekt: ${KIOSK_USER}" >&2; exit 1; }

install -d -m 0755 "${INSTALL_DIR}/scripts" "${INSTALL_DIR}/offline-player" "${INSTALL_DIR}/offline-fallback"
install -m 0755 "${ROOT}/scripts/sync-presentation-cache.py" "${INSTALL_DIR}/scripts/sync-presentation-cache.py"
install -m 0644 "${ROOT}/assets/offline-presentation/index.html" "${INSTALL_DIR}/offline-player/index.html"
install -m 0644 "${ROOT}/assets/offline-presentation/slideshow.css" "${INSTALL_DIR}/offline-player/slideshow.css"
install -m 0644 "${ROOT}/assets/offline-presentation/slideshow.js" "${INSTALL_DIR}/offline-player/slideshow.js"
install -m 0644 "${ROOT}/assets/offline/index.html" "${INSTALL_DIR}/offline-fallback/index.html"
install -m 0644 "${ROOT}/assets/offline/offline.css" "${INSTALL_DIR}/offline-fallback/offline.css"

install -d -m 0755 -o "${KIOSK_USER}" -g "${group}" "${INSTALL_DIR}/offline" "${INSTALL_DIR}/offline/versions"
if [ ! -f "${INSTALL_DIR}/offline/index.html" ]; then
  install -m 0644 -o "${KIOSK_USER}" -g "${group}" "${INSTALL_DIR}/offline-fallback/index.html" "${INSTALL_DIR}/offline/index.html"
  install -m 0644 -o "${KIOSK_USER}" -g "${group}" "${INSTALL_DIR}/offline-fallback/offline.css" "${INSTALL_DIR}/offline/offline.css"
fi
chown -R "${KIOSK_USER}:${group}" "${INSTALL_DIR}/offline"

unit_dir="${home}/.config/systemd/user"
install -d -m 0755 -o "${KIOSK_USER}" -g "${group}" "${unit_dir}"
install -m 0644 -o "${KIOSK_USER}" -g "${group}" "${ROOT}/services/digitalsignage-presentation-cache.service" "${unit_dir}/digitalsignage-presentation-cache.service"
cat > "${unit_dir}/digitalsignage-presentation-cache.timer" <<EOF
[Unit]
Description=Digital Signage lokale presentatiecache periodiek bijwerken
[Timer]
OnBootSec=45s
OnUnitInactiveSec=${CACHE_SECONDS}s
AccuracySec=30s
Persistent=true
Unit=digitalsignage-presentation-cache.service
[Install]
WantedBy=timers.target
EOF
chown "${KIOSK_USER}:${group}" "${unit_dir}/digitalsignage-presentation-cache.timer"

runtime="/run/user/${uid}"; bus="${runtime}/bus"
if [ -S "${bus}" ]; then
  runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" systemctl --user daemon-reload
  runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" systemctl --user enable --now digitalsignage-presentation-cache.timer
  runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${runtime}" DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" systemctl --user restart digitalsignage-presentation-cache.timer
else
  echo "Geen actieve usersessie; timer is geïnstalleerd maar nog niet gestart."
fi

echo "Fase 3.1-upgrade klaar. Configbackup: ${backup}"
