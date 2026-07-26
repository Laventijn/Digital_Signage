#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TEST_TMP_DIR}"
}
trap cleanup EXIT

write_config() {
  local config_file="$1"
  local enabled="$2"
  local wallpaper_file="$3"
  local mode="$4"

  cat >"${config_file}" <<EOF
KIOSK_USER="$(id -un)"
DESKTOP_BACKGROUND_ENABLED=${enabled}
DESKTOP_BACKGROUND_FILE="${wallpaper_file}"
DESKTOP_BACKGROUND_MODE=${mode}
EOF
}

run_configurator() {
  local config_file="$1"
  local home_dir="$2"

  CONFIG_FILE="${config_file}" \
  DIGITALSIGNAGE_TEST_KIOSK_USER="$(id -un)" \
  DIGITALSIGNAGE_TEST_KIOSK_GROUP="$(id -gn)" \
  DIGITALSIGNAGE_TEST_KIOSK_HOME="${home_dir}" \
    bash "${ROOT_DIR}/scripts/configure-desktop-background.sh"
}

run_configurator_with_pcmanfm_log() {
  local config_file="$1"
  local home_dir="$2"
  local command_log="$3"

  CONFIG_FILE="${config_file}" \
  DIGITALSIGNAGE_TEST_KIOSK_USER="$(id -un)" \
  DIGITALSIGNAGE_TEST_KIOSK_GROUP="$(id -gn)" \
  DIGITALSIGNAGE_TEST_KIOSK_UID="$(id -u)" \
  DIGITALSIGNAGE_TEST_KIOSK_HOME="${home_dir}" \
  DIGITALSIGNAGE_TEST_XDG_RUNTIME_DIR="${TEST_TMP_DIR}/runtime" \
  DIGITALSIGNAGE_TEST_DBUS_SESSION_BUS_ADDRESS="unix:path=${TEST_TMP_DIR}/runtime/bus" \
  DIGITALSIGNAGE_TEST_PCMANFM_ACTIVE=1 \
  DIGITALSIGNAGE_TEST_PCMANFM_COMMAND_LOG="${command_log}" \
    bash "${ROOT_DIR}/scripts/configure-desktop-background.sh"
}

assert_contains() {
  local file="$1"
  local expected="$2"

  if ! grep -F -- "${expected}" "${file}" >/dev/null; then
    echo "Ontbrekende tekst in ${file}: ${expected}" >&2
    [ -f "${file}" ] && sed -n '1,120p' "${file}" >&2
    return 1
  fi
}

assert_count() {
  local file="$1"
  local pattern="$2"
  local expected_count="$3"
  local actual_count

  actual_count="$(grep -c -F -- "${pattern}" "${file}" || true)"
  [ "${actual_count}" = "${expected_count}" ]
}

test_sets_background_idempotently() {
  local home_dir="${TEST_TMP_DIR}/home-idempotent"
  local wallpaper_file="${TEST_TMP_DIR}/background.png"
  local config_file="${TEST_TMP_DIR}/idempotent.conf"
  local desktop_config="${home_dir}/.config/pcmanfm/LXDE-pi/desktop-items-0.conf"

  mkdir -p "${home_dir}"
  printf 'png\n' >"${wallpaper_file}"
  write_config "${config_file}" "true" "${wallpaper_file}" "zoom"

  run_configurator "${config_file}" "${home_dir}" >/dev/null
  run_configurator "${config_file}" "${home_dir}" >/dev/null

  assert_contains "${desktop_config}" "wallpaper=${wallpaper_file}"
  assert_contains "${desktop_config}" "wallpaper_mode=crop"
  assert_count "${desktop_config}" "wallpaper=" "1"
  assert_count "${desktop_config}" "wallpaper_mode=" "1"
}

test_backup_existing_config() {
  local home_dir="${TEST_TMP_DIR}/home-backup"
  local wallpaper_file="${TEST_TMP_DIR}/backup-background.png"
  local config_file="${TEST_TMP_DIR}/backup.conf"
  local desktop_dir="${home_dir}/.config/pcmanfm/LXDE-pi"
  local desktop_config="${desktop_dir}/desktop-items-0.conf"

  mkdir -p "${desktop_dir}"
  printf 'png\n' >"${wallpaper_file}"
  printf '[*]\nwallpaper=/oude/achtergrond.png\nwallpaper_mode=center\n' >"${desktop_config}"
  write_config "${config_file}" "true" "${wallpaper_file}" "fit"

  run_configurator "${config_file}" "${home_dir}" >/dev/null

  compgen -G "${desktop_config}.backup.*" >/dev/null
  assert_contains "${desktop_config}" "wallpaper=${wallpaper_file}"
  assert_contains "${desktop_config}" "wallpaper_mode=fit"
}

test_disabled_does_not_change_config() {
  local home_dir="${TEST_TMP_DIR}/home-disabled"
  local wallpaper_file="${TEST_TMP_DIR}/disabled-background.png"
  local config_file="${TEST_TMP_DIR}/disabled.conf"
  local desktop_dir="${home_dir}/.config/pcmanfm/LXDE-pi"
  local desktop_config="${desktop_dir}/desktop-items-0.conf"
  local checksum_before checksum_after

  mkdir -p "${desktop_dir}"
  printf 'png\n' >"${wallpaper_file}"
  printf '[*]\nwallpaper=/blijft/staan.png\n' >"${desktop_config}"
  checksum_before="$(sha256sum "${desktop_config}" | awk '{ print $1 }')"
  write_config "${config_file}" "false" "${wallpaper_file}" "zoom"

  run_configurator "${config_file}" "${home_dir}" >/dev/null

  checksum_after="$(sha256sum "${desktop_config}" | awk '{ print $1 }')"
  [ "${checksum_before}" = "${checksum_after}" ]
  assert_contains "${desktop_config}" "wallpaper=/blijft/staan.png"
  ! assert_contains "${desktop_config}" "wallpaper=${wallpaper_file}"
}

test_missing_wallpaper_fails() {
  local home_dir="${TEST_TMP_DIR}/home-missing"
  local config_file="${TEST_TMP_DIR}/missing.conf"
  local output_file="${TEST_TMP_DIR}/missing.out"

  mkdir -p "${home_dir}"
  write_config "${config_file}" "true" "${TEST_TMP_DIR}/ontbreekt.png" "zoom"

  if run_configurator "${config_file}" "${home_dir}" >"${output_file}" 2>&1; then
    return 1
  fi

  assert_contains "${output_file}" "Desktopachtergrondbestand ontbreekt"
}

test_pcmanfm_command_is_built() {
  local home_dir="${TEST_TMP_DIR}/home-pcmanfm"
  local wallpaper_file="${TEST_TMP_DIR}/pcmanfm-background.png"
  local config_file="${TEST_TMP_DIR}/pcmanfm.conf"
  local command_log="${TEST_TMP_DIR}/pcmanfm-command.log"

  mkdir -p "${home_dir}" "${TEST_TMP_DIR}/runtime"
  printf 'png\n' >"${wallpaper_file}"
  write_config "${config_file}" "true" "${wallpaper_file}" "zoom"

  run_configurator_with_pcmanfm_log "${config_file}" "${home_dir}" "${command_log}" >/dev/null

  assert_contains "${command_log}" "env_XDG_RUNTIME_DIR=${TEST_TMP_DIR}/runtime"
  assert_contains "${command_log}" "env_DBUS_SESSION_BUS_ADDRESS=unix:path=${TEST_TMP_DIR}/runtime/bus"
  assert_contains "${command_log}" "env_WAYLAND_DISPLAY=wayland-0"
  assert_contains "${command_log}" "arg_0=pcmanfm"
  assert_contains "${command_log}" "arg_1=--profile"
  assert_contains "${command_log}" "arg_2=LXDE-pi"
  assert_contains "${command_log}" "arg_3=--set-wallpaper=${wallpaper_file}"
  assert_contains "${command_log}" "arg_4=--wallpaper-mode=crop"
}

test_no_pcmanfm_command_when_desktop_inactive() {
  local home_dir="${TEST_TMP_DIR}/home-no-pcmanfm"
  local wallpaper_file="${TEST_TMP_DIR}/no-pcmanfm-background.png"
  local config_file="${TEST_TMP_DIR}/no-pcmanfm.conf"
  local command_log="${TEST_TMP_DIR}/no-pcmanfm-command.log"

  mkdir -p "${home_dir}"
  printf 'png\n' >"${wallpaper_file}"
  write_config "${config_file}" "true" "${wallpaper_file}" "zoom"

  CONFIG_FILE="${config_file}" \
  DIGITALSIGNAGE_TEST_KIOSK_USER="$(id -un)" \
  DIGITALSIGNAGE_TEST_KIOSK_GROUP="$(id -gn)" \
  DIGITALSIGNAGE_TEST_KIOSK_HOME="${home_dir}" \
  DIGITALSIGNAGE_TEST_PCMANFM_COMMAND_LOG="${command_log}" \
    bash "${ROOT_DIR}/scripts/configure-desktop-background.sh" >/dev/null

  [ ! -e "${command_log}" ]
}

test_sets_background_idempotently
test_backup_existing_config
test_disabled_does_not_change_config
test_missing_wallpaper_fails
test_pcmanfm_command_is_built
test_no_pcmanfm_command_when_desktop_inactive
