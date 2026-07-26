#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/digitalsignage/digitalsignage.conf}"

read_config_value() {
  local key="$1"
  local file="$2"
  [ -f "${file}" ] || return 0
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

PRESENTATION_URL="$(read_config_value PRESENTATION_URL "${CONFIG_FILE}")"
CHROMIUM_BIN="$(read_config_value CHROMIUM_BIN "${CONFIG_FILE}")"
WAYLAND_DISPLAY="$(read_config_value WAYLAND_DISPLAY "${CONFIG_FILE}")"
CHROMIUM_PROFILE_DIR="$(read_config_value CHROMIUM_PROFILE_DIR "${CONFIG_FILE}")"
CHROMIUM_CACHE_DIR="$(read_config_value CHROMIUM_CACHE_DIR "${CONFIG_FILE}")"
CACHE_SIZE_MB="$(read_config_value CACHE_SIZE_MB "${CONFIG_FILE}")"
REMOTE_DEBUG_HOST="$(read_config_value REMOTE_DEBUG_HOST "${CONFIG_FILE}")"
REMOTE_DEBUG_PORT="$(read_config_value REMOTE_DEBUG_PORT "${CONFIG_FILE}")"

CHROMIUM_BIN="${CHROMIUM_BIN:-/usr/bin/chromium}"
WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
CHROMIUM_PROFILE_DIR="${CHROMIUM_PROFILE_DIR:-.local/share/digitalsignage/chromium-profile}"
CHROMIUM_CACHE_DIR="${CHROMIUM_CACHE_DIR:-.cache/digitalsignage/chromium}"
CACHE_SIZE_MB="${CACHE_SIZE_MB:-100}"
REMOTE_DEBUG_HOST="${REMOTE_DEBUG_HOST:-127.0.0.1}"
REMOTE_DEBUG_PORT="${REMOTE_DEBUG_PORT:-9222}"

if [ -z "${PRESENTATION_URL}" ]; then
  echo "Fout: PRESENTATION_URL ontbreekt in ${CONFIG_FILE}." >&2
  exit 1
fi

if [ -z "${HOME:-}" ]; then
  echo "Fout: HOME is niet ingesteld; profiel- en cachepaden kunnen niet worden opgebouwd." >&2
  exit 1
fi

if [ ! -x "${CHROMIUM_BIN}" ]; then
  echo "Fout: Chromium-binary is niet uitvoerbaar: ${CHROMIUM_BIN}" >&2
  exit 1
fi

case "${CACHE_SIZE_MB}" in
  ''|*[!0-9]*)
    echo "Fout: CACHE_SIZE_MB moet een positief geheel getal zijn." >&2
    exit 1
    ;;
esac

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export WAYLAND_DISPLAY
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

if [ ! -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]; then
  echo "Fout: Wayland-socket ontbreekt: ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" >&2
  exit 1
fi

if [ ! -S "${XDG_RUNTIME_DIR}/bus" ]; then
  echo "Fout: D-Bus usersessie ontbreekt: ${XDG_RUNTIME_DIR}/bus" >&2
  exit 1
fi

PROFILE_DIR="${HOME}/${CHROMIUM_PROFILE_DIR}"
CACHE_DIR="${HOME}/${CHROMIUM_CACHE_DIR}"
CACHE_SIZE_BYTES=$((CACHE_SIZE_MB * 1024 * 1024))

mkdir -p "${PROFILE_DIR}" "${CACHE_DIR}"

exec "${CHROMIUM_BIN}" \
  --ozone-platform=wayland \
  --disable-gpu \
  --password-store=basic \
  --user-data-dir="${PROFILE_DIR}" \
  --disk-cache-dir="${CACHE_DIR}" \
  --disk-cache-size="${CACHE_SIZE_BYTES}" \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --disable-session-crashed-bubble \
  --autoplay-policy=no-user-gesture-required \
  --remote-debugging-address="${REMOTE_DEBUG_HOST}" \
  --remote-debugging-port="${REMOTE_DEBUG_PORT}" \
  --remote-allow-origins="http://${REMOTE_DEBUG_HOST}:${REMOTE_DEBUG_PORT}" \
  "${PRESENTATION_URL}"
