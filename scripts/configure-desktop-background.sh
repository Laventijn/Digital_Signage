#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/digitalsignage/digitalsignage.conf}"
DEFAULT_BACKGROUND_FILE="/opt/digitalsignage/assets/wallpapers/digitalsignage-background.png"
PCMANFM_PROFILE="LXDE-pi"
DEFAULT_WAYLAND_DISPLAY="wayland-0"

error() {
  echo "FOUT: $*" >&2
}

info() {
  echo "$*"
}

warn() {
  echo "Waarschuwing: $*" >&2
}

read_config_value() {
  local key="$1"
  local file="$2"

  [ -f "${file}" ] || return 0

  awk -F= -v key="${key}" '
    $0 ~ "^[[:space:]]*#" { next }
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "${file}"
}

is_enabled() {
  case "${1,,}" in
    ""|"1"|"true"|"yes"|"ja"|"on") return 0 ;;
    "0"|"false"|"no"|"nee"|"off") return 1 ;;
    *)
      warn "ongeldige DESKTOP_BACKGROUND_ENABLED='${1}', standaard wordt true gebruikt."
      return 0
      ;;
  esac
}

normalize_mode() {
  case "${1,,}" in
    ""|"zoom"|"crop") printf '%s\n' "crop" ;;
    "fit"|"stretch"|"center"|"tile") printf '%s\n' "${1,,}" ;;
    *)
      warn "ongeldige DESKTOP_BACKGROUND_MODE='${1}', standaard wordt zoom gebruikt."
      printf '%s\n' "crop"
      ;;
  esac
}

primary_group_for_user() {
  local user="$1"
  local gid group

  gid="$(getent passwd "${user}" | awk -F: '{ print $4 }')"
  group="$(getent group "${gid}" | awk -F: '{ print $1 }')"
  printf '%s\n' "${group:-${user}}"
}

primary_uid_for_user() {
  local user="$1"
  getent passwd "${user}" | awk -F: '{ print $3 }'
}

install_owned_dir() {
  local dir="$1"
  local user="$2"
  local group="$3"

  if [ "$(id -u)" -eq 0 ]; then
    install -d -m 0755 -o "${user}" -g "${group}" "${dir}"
  else
    install -d -m 0755 "${dir}"
  fi
}

set_file_owner() {
  local path="$1"
  local user="$2"
  local group="$3"

  if [ "$(id -u)" -eq 0 ]; then
    chown "${user}:${group}" "${path}"
  fi
}

determine_kiosk_home() {
  local user="$1"
  local passwd_entry

  # In productie bepalen we de homefolder via de systeemdatabase. Zo blijft het
  # script bruikbaar voor elke kioskgebruiker en wordt geen /home/... hardcoded.
  if [ -n "${DIGITALSIGNAGE_TEST_KIOSK_HOME:-}" ]; then
    printf '%s\n' "${DIGITALSIGNAGE_TEST_KIOSK_HOME}"
    return 0
  fi

  passwd_entry="$(getent passwd "${user}" || true)"
  if [ -z "${passwd_entry}" ]; then
    error "Kioskgebruiker bestaat niet: ${user}"
    return 1
  fi

  printf '%s\n' "${passwd_entry}" | awk -F: '{ print $6 }'
}

pcmanfm_desktop_is_active() {
  local user="$1"

  case "${DIGITALSIGNAGE_TEST_PCMANFM_ACTIVE:-}" in
    "") ;;
    "1") return 0 ;;
    "0") return 1 ;;
    *)
      error "Ongeldige DIGITALSIGNAGE_TEST_PCMANFM_ACTIVE='${DIGITALSIGNAGE_TEST_PCMANFM_ACTIVE}'. Gebruik 1, 0 of laat leeg."
      return 2
      ;;
  esac

  [ -n "$(pcmanfm_desktop_pid "${user}")" ]
}

pcmanfm_desktop_pid() {
  local user="$1"

  command -v pgrep >/dev/null 2>&1 || return 1
  pgrep -u "${user}" -a pcmanfm 2>/dev/null | awk '/--desktop/ { print $1; exit }'
}

process_environment_value() {
  local pid="$1"
  local key="$2"

  [ -r "/proc/${pid}/environ" ] || return 0
  tr '\0' '\n' <"/proc/${pid}/environ" | awk -F= -v key="${key}" '$1 == key { print substr($0, index($0, "=") + 1); exit }'
}

run_pcmanfm_wallpaper_command() {
  local user="$1"
  local uid="$2"
  local wallpaper_file="$3"
  local wallpaper_mode="$4"
  local runtime_dir bus_path wayland_display display pcmanfm_pid
  local -a env_args command_args

  runtime_dir="${DIGITALSIGNAGE_TEST_XDG_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/${uid}}}"
  bus_path="${DIGITALSIGNAGE_TEST_DBUS_SESSION_BUS_ADDRESS:-}"
  wayland_display="${WAYLAND_DISPLAY:-${DEFAULT_WAYLAND_DISPLAY}}"
  display="${DISPLAY:-}"
  pcmanfm_pid="$(pcmanfm_desktop_pid "${user}" || true)"
  if [ -n "${pcmanfm_pid}" ]; then
    bus_path="${bus_path:-$(process_environment_value "${pcmanfm_pid}" DBUS_SESSION_BUS_ADDRESS || true)}"
    wayland_display="$(process_environment_value "${pcmanfm_pid}" WAYLAND_DISPLAY || true)"
    wayland_display="${wayland_display:-${DEFAULT_WAYLAND_DISPLAY}}"
    display="$(process_environment_value "${pcmanfm_pid}" DISPLAY || true)"
  fi
  bus_path="${bus_path:-unix:path=${runtime_dir}/bus}"

  if [ -z "${DIGITALSIGNAGE_TEST_PCMANFM_COMMAND_LOG:-}" ] && [ ! -d "${runtime_dir}" ]; then
    warn "geen actieve gebruikersruntime gevonden: ${runtime_dir}; achtergrond wordt bij volgende desktopstart toegepast."
    return 0
  fi
  if [ -z "${DIGITALSIGNAGE_TEST_PCMANFM_COMMAND_LOG:-}" ] && [ ! -S "${runtime_dir}/bus" ]; then
    warn "geen user D-Bus gevonden: ${runtime_dir}/bus; achtergrond wordt bij volgende desktopstart toegepast."
    return 0
  fi
  if ! pcmanfm_desktop_is_active "${user}"; then
    info "Geen actieve pcmanfm --desktop gevonden; achtergrond wordt bij volgende desktopstart toegepast."
    return 0
  fi
  if ! command -v pcmanfm >/dev/null 2>&1 && [ -z "${DIGITALSIGNAGE_TEST_PCMANFM_COMMAND_LOG:-}" ]; then
    warn "pcmanfm is niet gevonden; achtergrond wordt bij volgende desktopstart toegepast."
    return 0
  fi

  env_args=(
    "XDG_RUNTIME_DIR=${runtime_dir}"
    "DBUS_SESSION_BUS_ADDRESS=${bus_path}"
    "WAYLAND_DISPLAY=${wayland_display}"
  )
  if [ -n "${display}" ]; then
    env_args+=("DISPLAY=${display}")
  fi

  command_args=(
    pcmanfm
    --profile "${PCMANFM_PROFILE}"
    --set-wallpaper="${wallpaper_file}"
    --wallpaper-mode="${wallpaper_mode}"
  )

  if [ -n "${DIGITALSIGNAGE_TEST_PCMANFM_COMMAND_LOG:-}" ]; then
    {
      printf 'user=%s\n' "${user}"
      printf 'env_XDG_RUNTIME_DIR=%s\n' "${runtime_dir}"
      printf 'env_DBUS_SESSION_BUS_ADDRESS=%s\n' "${bus_path}"
      printf 'env_WAYLAND_DISPLAY=%s\n' "${wayland_display}"
      if [ -n "${display}" ]; then
        printf 'env_DISPLAY=%s\n' "${display}"
      fi
      printf 'arg_0=%s\n' "pcmanfm"
      printf 'arg_1=%s\n' "--profile"
      printf 'arg_2=%s\n' "${PCMANFM_PROFILE}"
      printf 'arg_3=%s\n' "--set-wallpaper=${wallpaper_file}"
      printf 'arg_4=%s\n' "--wallpaper-mode=${wallpaper_mode}"
    } >>"${DIGITALSIGNAGE_TEST_PCMANFM_COMMAND_LOG}"
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    if runuser -u "${user}" -- env "${env_args[@]}" "${command_args[@]}"; then
      info "Actieve pcmanfm-desktop bijgewerkt."
    else
      warn "pcmanfm kon de actieve achtergrond niet onmiddellijk bijwerken; configuratiebestand is wel aangepast."
    fi
  else
    if [ "$(id -un)" != "${user}" ]; then
      warn "script draait niet als ${user}; actieve achtergrond wordt niet onder de verkeerde gebruiker aangepast."
      return 0
    fi
    if env "${env_args[@]}" "${command_args[@]}"; then
      info "Actieve pcmanfm-desktop bijgewerkt."
    else
      warn "pcmanfm kon de actieve achtergrond niet onmiddellijk bijwerken; configuratiebestand is wel aangepast."
    fi
  fi
}

write_pcmanfm_config() {
  local config_file="$1"
  local wallpaper_file="$2"
  local wallpaper_mode="$3"
  local tmp_file inserted

  tmp_file="$(mktemp "${config_file}.tmp.XXXXXX")"
  inserted=0

  if [ -f "${config_file}" ]; then
    awk -v wallpaper="${wallpaper_file}" -v mode="${wallpaper_mode}" '
      BEGIN { inserted = 0 }
      /^wallpaper=/ || /^wallpaper_mode=/ { next }
      {
        print
        if (!inserted && $0 == "[*]") {
          print "wallpaper=" wallpaper
          print "wallpaper_mode=" mode
          inserted = 1
        }
      }
      END {
        if (!inserted) {
          print "[*]"
          print "wallpaper=" wallpaper
          print "wallpaper_mode=" mode
        }
      }
    ' "${config_file}" >"${tmp_file}"
  else
    {
      printf '%s\n' "[*]"
      printf 'wallpaper=%s\n' "${wallpaper_file}"
      printf 'wallpaper_mode=%s\n' "${wallpaper_mode}"
    } >"${tmp_file}"
  fi

  if [ -f "${config_file}" ] && cmp -s "${tmp_file}" "${config_file}"; then
    rm -f "${tmp_file}"
    return 1
  fi

  mv "${tmp_file}" "${config_file}"
  return 0
}

main() {
  local kiosk_user enabled background_file requested_mode wallpaper_mode
  local kiosk_home kiosk_group kiosk_uid desktop_dir desktop_config backup_file changed

  kiosk_user="$(read_config_value KIOSK_USER "${CONFIG_FILE}")"
  kiosk_user="${DIGITALSIGNAGE_TEST_KIOSK_USER:-${kiosk_user:-}}"
  if [ -z "${kiosk_user}" ]; then
    error "KIOSK_USER ontbreekt in ${CONFIG_FILE}"
    return 1
  fi

  enabled="$(read_config_value DESKTOP_BACKGROUND_ENABLED "${CONFIG_FILE}")"
  if ! is_enabled "${enabled}"; then
    info "Desktopachtergrond is uitgeschakeld via DESKTOP_BACKGROUND_ENABLED."
    return 0
  fi

  background_file="$(read_config_value DESKTOP_BACKGROUND_FILE "${CONFIG_FILE}")"
  background_file="${background_file:-${DEFAULT_BACKGROUND_FILE}}"
  requested_mode="$(read_config_value DESKTOP_BACKGROUND_MODE "${CONFIG_FILE}")"
  wallpaper_mode="$(normalize_mode "${requested_mode:-zoom}")"

  if [ ! -f "${background_file}" ]; then
    error "Desktopachtergrondbestand ontbreekt: ${background_file}"
    return 1
  fi

  kiosk_home="$(determine_kiosk_home "${kiosk_user}")"
  if [ -z "${kiosk_home}" ]; then
    error "Homefolder van kioskgebruiker kon niet worden bepaald."
    return 1
  fi

  kiosk_group="${DIGITALSIGNAGE_TEST_KIOSK_GROUP:-}"
  if [ -z "${kiosk_group}" ]; then
    kiosk_group="$(primary_group_for_user "${kiosk_user}")"
  fi
  kiosk_uid="${DIGITALSIGNAGE_TEST_KIOSK_UID:-}"
  if [ -z "${kiosk_uid}" ]; then
    kiosk_uid="$(primary_uid_for_user "${kiosk_user}")"
  fi

  # Raspberry Pi OS Trixie met Desktop bewaart de labwc-sessieachtergrond via
  # de pcmanfm-desktopconfiguratie. We passen alleen dit gebruikersbestand aan
  # en forceren geen herstart van labwc, pcmanfm of de volledige desktop.
  desktop_dir="${kiosk_home}/.config/pcmanfm/${PCMANFM_PROFILE}"
  desktop_config="${desktop_dir}/desktop-items-0.conf"
  install_owned_dir "${desktop_dir}" "${kiosk_user}" "${kiosk_group}"

  changed=0
  if [ -f "${desktop_config}" ]; then
    backup_file="${desktop_config}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -p "${desktop_config}" "${backup_file}"
  fi

  if write_pcmanfm_config "${desktop_config}" "${background_file}" "${wallpaper_mode}"; then
    changed=1
  fi

  set_file_owner "${desktop_config}" "${kiosk_user}" "${kiosk_group}"
  chmod 0644 "${desktop_config}"

  if [ "${changed}" -eq 1 ]; then
    info "Desktopachtergrond ingesteld in ${desktop_config}."
  else
    [ -n "${backup_file:-}" ] && rm -f "${backup_file}"
    info "Desktopachtergrond was al correct ingesteld."
  fi

  run_pcmanfm_wallpaper_command "${kiosk_user}" "${kiosk_uid}" "${background_file}" "${wallpaper_mode}"
}

main "$@"
