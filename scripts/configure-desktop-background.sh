#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/digitalsignage/digitalsignage.conf}"
DEFAULT_BACKGROUND_FILE="/opt/digitalsignage/assets/wallpapers/digitalsignage-background.png"
PCMANFM_PROFILE="LXDE-pi"

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
  local kiosk_home kiosk_group desktop_dir desktop_config backup_file changed

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
    info "De actieve desktop neemt dit uiterlijk bij de volgende desktopstart zichtbaar over."
  else
    [ -n "${backup_file:-}" ] && rm -f "${backup_file}"
    info "Desktopachtergrond was al correct ingesteld."
  fi
}

main "$@"
