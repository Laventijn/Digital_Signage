#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-library.sh
source "${SCRIPT_DIR}/test-library.sh"

init_test_context "post-install"

CONFIG_FILE="/etc/digitalsignage/digitalsignage.conf"
KIOSK_USER=""
KIOSK_HOME=""
KIOSK_UID=""
KIOSK_GID=""
KIOSK_GROUP=""

run_as_kiosk_user() {
  if [ -z "${KIOSK_USER}" ] || [ -z "${KIOSK_UID}" ]; then
    log_error "Kioskgebruiker of UID is niet bepaald"
    return 1
  fi

  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "${KIOSK_USER}" \
      XDG_RUNTIME_DIR="/run/user/${KIOSK_UID}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${KIOSK_UID}/bus" \
      "$@"
  else
    XDG_RUNTIME_DIR="/run/user/${KIOSK_UID}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${KIOSK_UID}/bus" \
      "$@"
  fi
}

run_user_systemctl() {
  run_as_kiosk_user systemctl --user "$@"
}

run_user_journalctl() {
  run_as_kiosk_user journalctl --user "$@"
}

journal_has_entries() {
  local output="$1"
  [ -n "${output}" ] || return 1
  if printf '%s\n' "${output}" | grep -E 'No journal files were found|-- No entries --' >/dev/null; then
    return 1
  fi
  return 0
}

read_unit_journal() {
  local unit="$1"
  local output
  output="$(run_user_journalctl -u "${unit}" -n 30 --no-pager 2>&1 || true)"
  if journal_has_entries "${output}"; then
    printf '%s\n' "${output}"
    return 0
  fi

  printf '[INFO] Geen bruikbare journalregels via journalctl --user voor %s; probeer systeemjournal.\n' "${unit}"
  if [ "$(id -u)" -eq 0 ]; then
    output="$(journalctl "_SYSTEMD_USER_UNIT=${unit}" --no-pager -n 30 2>&1 || true)"
    if journal_has_entries "${output}"; then
      printf '%s\n' "${output}"
      return 0
    fi
  else
    printf '[INFO] Systeemjournalfallback vereist rootrechten.\n'
  fi

  printf '%s\n' "${output}"
  return 1
}

get_user_unit_property() {
  local unit="$1"
  local property="$2"
  run_user_systemctl show "${unit}" --property="${property}" --value 2>/dev/null
}

show_oneshot_result() {
  local unit="$1"
  run_user_systemctl show "${unit}" --property=Result --property=ExecMainCode --property=ExecMainStatus --property=ActiveState --no-pager 2>&1 || true
}

extract_slides_id() {
  local url="$1"
  case "${url}" in
    *"/presentation/d/"*)
      url="${url#*/presentation/d/}"
      printf '%s\n' "${url%%/*}"
      ;;
    *)
      printf '\n'
      ;;
  esac
}

test_user_and_config() {
  local passwd_entry
  if [ ! -f "${CONFIG_FILE}" ]; then
    log_error "Configuratie ontbreekt: ${CONFIG_FILE}"
    return 1
  fi

  KIOSK_USER="$(read_config_value KIOSK_USER "${CONFIG_FILE}")"
  if [ -z "${KIOSK_USER}" ]; then
    log_error "KIOSK_USER ontbreekt in ${CONFIG_FILE}"
    return 1
  fi

  passwd_entry="$(getent passwd "${KIOSK_USER}" || true)"
  if [ -z "${passwd_entry}" ]; then
    log_error "Kioskgebruiker bestaat niet: ${KIOSK_USER}"
    return 1
  fi

  KIOSK_UID="$(printf '%s' "${passwd_entry}" | cut -d: -f3)"
  KIOSK_GID="$(printf '%s' "${passwd_entry}" | cut -d: -f4)"
  KIOSK_HOME="$(printf '%s' "${passwd_entry}" | cut -d: -f6)"
  KIOSK_GROUP="$(getent group "${KIOSK_GID}" | cut -d: -f1 || true)"
  if [ -z "${KIOSK_HOME}" ] || [ -z "${KIOSK_GROUP}" ]; then
    log_error "Homefolder of primaire groep kon niet bepaald worden"
    return 1
  fi

  log_info "Kioskgebruiker: ${KIOSK_USER}"
  log_info "UID: ${KIOSK_UID}"
  log_info "Primaire groep: ${KIOSK_GROUP}"
  log_info "Homefolder: ${KIOSK_HOME}"
  return 0
}

test_install_paths() {
  local failed=0
  local path
  for path in /opt/digitalsignage /etc/digitalsignage/digitalsignage.conf /opt/digitalsignage/scripts/start-kiosk.sh /opt/digitalsignage/scripts/refresh-presentation.py /opt/digitalsignage/scripts/log-resources.py /opt/digitalsignage/scripts/health-check.py /opt/digitalsignage/scripts/configure-desktop-background.sh /opt/digitalsignage/assets/wallpapers/digitalsignage-background.png; do
    if [ -e "${path}" ]; then
      log_ok "Installatiepad bestaat: ${path}"
    else
      log_error "Installatiepad ontbreekt: ${path}"
      failed=1
    fi
  done

  for path in /opt/digitalsignage/scripts/start-kiosk.sh /opt/digitalsignage/scripts/refresh-presentation.py /opt/digitalsignage/scripts/log-resources.py /opt/digitalsignage/scripts/health-check.py /opt/digitalsignage/scripts/configure-desktop-background.sh /opt/digitalsignage/scripts/health-check.sh /opt/digitalsignage/scripts/refresh-kiosk.sh /opt/digitalsignage/scripts/restart-chromium.sh /opt/digitalsignage/scripts/show-network-info.sh /opt/digitalsignage/scripts/check-network.sh; do
    if [ -x "${path}" ]; then
      log_ok "Script is uitvoerbaar: ${path}"
    else
      log_error "Script is niet uitvoerbaar: ${path}"
      failed=1
    fi
    if [ -e "${path}" ]; then
      local mode
      mode="$(stat -c '%a' "${path}")"
      [ "${mode}" = "755" ] && log_ok "Scriptmodus is 0755: ${path}" || { log_error "Scriptmodus is ${mode}, verwacht 0755: ${path}"; failed=1; }
    fi
  done

  if [ -e /opt/digitalsignage/assets/wallpapers/digitalsignage-background.png ]; then
    local wallpaper_mode
    wallpaper_mode="$(stat -c '%a' /opt/digitalsignage/assets/wallpapers/digitalsignage-background.png)"
    [ "${wallpaper_mode}" = "644" ] && log_ok "Desktopachtergrondmodus is 0644" || { log_error "Desktopachtergrondmodus is ${wallpaper_mode}, verwacht 644"; failed=1; }
  fi
  return "${failed}"
}

test_desktop_background() {
  local failed=0
  local enabled background_file mode desktop_config

  enabled="$(read_config_value DESKTOP_BACKGROUND_ENABLED "${CONFIG_FILE}")"
  background_file="$(read_config_value DESKTOP_BACKGROUND_FILE "${CONFIG_FILE}")"
  mode="$(read_config_value DESKTOP_BACKGROUND_MODE "${CONFIG_FILE}")"
  desktop_config="${KIOSK_HOME}/.config/pcmanfm/LXDE-pi/desktop-items-0.conf"

  [ "${enabled}" = "true" ] && log_ok "Desktopachtergrond staat standaard aan" || { log_error "DESKTOP_BACKGROUND_ENABLED is ${enabled:-leeg}"; failed=1; }
  [ "${background_file}" = "/opt/digitalsignage/assets/wallpapers/digitalsignage-background.png" ] && log_ok "Desktopachtergrondpad correct" || { log_error "DESKTOP_BACKGROUND_FILE is ${background_file:-leeg}"; failed=1; }
  [ "${mode}" = "zoom" ] && log_ok "Desktopachtergrondmodus correct" || { log_error "DESKTOP_BACKGROUND_MODE is ${mode:-leeg}"; failed=1; }

  if [ -f "${desktop_config}" ]; then
    log_ok "pcmanfm-desktopconfiguratie bestaat: ${desktop_config}"
    grep -F "wallpaper=${background_file}" "${desktop_config}" >/dev/null && log_ok "Desktopconfiguratie verwijst naar projectachtergrond" || { log_error "Desktopconfiguratie verwijst niet naar projectachtergrond"; failed=1; }
    grep -F "wallpaper_mode=crop" "${desktop_config}" >/dev/null && log_ok "Desktopconfiguratie gebruikt crop voor zoom" || { log_error "Desktopconfiguratie mist wallpaper_mode=crop"; failed=1; }
  else
    log_error "pcmanfm-desktopconfiguratie ontbreekt: ${desktop_config}"
    failed=1
  fi

  return "${failed}"
}

test_status_directory() {
  local state_dir="${KIOSK_HOME}/.local/state/digitalsignage"
  local failed=0
  if [ -d "${state_dir}" ]; then
    log_ok "Statusmap bestaat: ${state_dir}"
  else
    log_error "Statusmap ontbreekt: ${state_dir}"
    return 1
  fi

  local owner group mode
  owner="$(stat -c '%U' "${state_dir}")"
  group="$(stat -c '%G' "${state_dir}")"
  mode="$(stat -c '%a' "${state_dir}")"
  log_info "Statusmap eigenaar=${owner} groep=${group} modus=${mode}"

  [ "${owner}" = "${KIOSK_USER}" ] && log_ok "Statusmap eigenaar correct" || { log_error "Statusmap eigenaar is ${owner}"; failed=1; }
  [ "${group}" = "${KIOSK_GROUP}" ] && log_ok "Statusmap groep correct" || { log_error "Statusmap groep is ${group}"; failed=1; }

  if sudo -u "${KIOSK_USER}" test -w "${state_dir}"; then
    log_ok "Statusmap is schrijfbaar voor kioskgebruiker"
  else
    log_error "Statusmap is niet schrijfbaar voor kioskgebruiker"
    failed=1
  fi
  return "${failed}"
}

test_user_systemd() {
  local failed=0
  local unit health_seconds health_dropin inactive_count active_count
  if [ ! -S "/run/user/${KIOSK_UID}/bus" ]; then
    log_error "Geen actieve user-D-Bus gevonden: /run/user/${KIOSK_UID}/bus"
    return 1
  fi

  for unit in digitalsignage-kiosk.service digitalsignage-refresh.timer digitalsignage-resource-log.timer digitalsignage-health.timer; do
    run_user_systemctl status "${unit}" --no-pager || log_warning "Statuscontrole gaf niet-nul exitcode voor ${unit}"
  done

  for unit in digitalsignage-refresh.service digitalsignage-resource-log.service digitalsignage-health.service; do
    local unit_state
    unit_state="$(show_oneshot_result "${unit}")"
    printf '%s\n' "${unit_state}"
    printf '%s\n' "${unit_state}" | grep -F 'Result=success' >/dev/null && log_ok "${unit} laatste Result=success" || log_info "${unit} heeft nog geen succesvolle oneshot-run"
    printf '%s\n' "${unit_state}" | grep -F 'ActiveState=inactive' >/dev/null && log_ok "${unit} mag inactive zijn na oneshot" || true
  done

  run_user_systemctl is-enabled digitalsignage-kiosk.service >/dev/null && log_ok "Kioskservice is enabled" || { log_error "Kioskservice is niet enabled"; failed=1; }
  run_user_systemctl is-enabled digitalsignage-refresh.timer >/dev/null && log_ok "Refreshtimer is enabled" || { log_error "Refreshtimer is niet enabled"; failed=1; }
  run_user_systemctl is-enabled digitalsignage-resource-log.timer >/dev/null && log_ok "Resource-logtimer is enabled" || { log_error "Resource-logtimer is niet enabled"; failed=1; }
  run_user_systemctl is-enabled digitalsignage-health.timer >/dev/null && log_ok "Healthtimer is enabled" || { log_error "Healthtimer is niet enabled"; failed=1; }
  run_user_systemctl is-active digitalsignage-kiosk.service >/dev/null && log_ok "Kioskservice is actief" || { log_error "Kioskservice is niet actief"; failed=1; }
  run_user_systemctl is-active digitalsignage-refresh.timer >/dev/null && log_ok "Refreshtimer is actief" || { log_error "Refreshtimer is niet actief"; failed=1; }
  run_user_systemctl is-active digitalsignage-resource-log.timer >/dev/null && log_ok "Resource-logtimer is actief" || { log_error "Resource-logtimer is niet actief"; failed=1; }
  run_user_systemctl is-active digitalsignage-health.timer >/dev/null && log_ok "Healthtimer is actief" || { log_error "Healthtimer is niet actief"; failed=1; }

  health_seconds="$(read_config_value HEALTH_CHECK_SECONDS "${CONFIG_FILE}")"
  health_dropin="${KIOSK_HOME}/.config/systemd/user/digitalsignage-health.timer.d/interval.conf"
  if [ -f "${health_dropin}" ]; then
    inactive_count="$(awk -F= '$1 == "OnUnitInactiveSec" && $2 != "" { count++ } END { print count + 0 }' "${health_dropin}")"
    active_count="$(awk -F= '$1 == "OnUnitActiveSec" && $2 != "" { count++ } END { print count + 0 }' "${health_dropin}")"
    grep -q '^OnBootSec=$' "${health_dropin}" && log_ok "Healthtimer-drop-in reset oude OnBootSec" || { log_error "Healthtimer-drop-in reset OnBootSec niet"; failed=1; }
    grep -q '^OnActiveSec=2min$' "${health_dropin}" && log_ok "Healthtimer-drop-in bouwt OnActiveSec opnieuw op" || { log_error "Healthtimer-drop-in mist OnActiveSec=2min"; failed=1; }
    [ "${inactive_count}" = "1" ] && log_ok "Healthtimer-drop-in bevat exact een actieve OnUnitInactiveSec" || { log_error "Healthtimer-drop-in bevat ${inactive_count} actieve OnUnitInactiveSec-regels"; failed=1; }
    grep -q "^OnUnitInactiveSec=${health_seconds}s$" "${health_dropin}" && log_ok "Healthtimer-drop-in gebruikt HEALTH_CHECK_SECONDS=${health_seconds}" || { log_error "Healthtimer-drop-in gebruikt niet HEALTH_CHECK_SECONDS=${health_seconds}"; failed=1; }
    [ "${active_count}" = "0" ] && log_ok "Healthtimer-drop-in gebruikt geen actieve OnUnitActiveSec" || { log_error "Healthtimer-drop-in bevat actieve OnUnitActiveSec"; failed=1; }
    if grep -q '^OnUnitActiveSec=$' "${health_dropin}" || grep -q '^OnUnitInactiveSec=$' "${health_dropin}"; then
      log_error "Healthtimer-drop-in gebruikt nog een lege OnUnitActiveSec/OnUnitInactiveSec-reset"
      failed=1
    else
      log_ok "Healthtimer-drop-in gebruikt geen lege OnUnitActiveSec/OnUnitInactiveSec-reset"
    fi
  else
    log_error "Healthtimer-drop-in ontbreekt: ${health_dropin}"
    failed=1
  fi

  return "${failed}"
}

test_chromium() {
  local failed=0
  local cmdline pid debug_host debug_port profile_dir cache_dir expected_profile expected_cache option
  pid="$(get_user_unit_property digitalsignage-kiosk.service MainPID)"
  debug_host="$(read_config_value REMOTE_DEBUG_HOST "${CONFIG_FILE}")"
  debug_port="$(read_config_value REMOTE_DEBUG_PORT "${CONFIG_FILE}")"
  profile_dir="$(read_config_value CHROMIUM_PROFILE_DIR "${CONFIG_FILE}")"
  cache_dir="$(read_config_value CHROMIUM_CACHE_DIR "${CONFIG_FILE}")"
  debug_host="${debug_host:-127.0.0.1}"
  debug_port="${debug_port:-9222}"

  if ! printf '%s\n' "${pid}" | grep -E '^[0-9]+$' >/dev/null; then
    log_error "MainPID van digitalsignage-kiosk.service is niet numeriek: ${pid:-leeg}"
    return 1
  fi
  if [ "${pid}" -le 0 ]; then
    log_error "MainPID van digitalsignage-kiosk.service is niet groter dan nul: ${pid}"
    return 1
  fi
  if [ ! -d "/proc/${pid}" ]; then
    log_error "/proc/${pid} bestaat niet voor kiosk MainPID"
    return 1
  fi
  log_ok "Kiosk MainPID gevonden: ${pid}"

  cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline")"
  log_info "Chromium commandline: ${cmdline}"

  printf '%s\n' "${cmdline}" | grep -F 'chromium' >/dev/null && log_ok "Chromium-binary in commandline" || { log_error "Commandline bevat geen chromium"; failed=1; }
  for option in '--kiosk' '--ozone-platform=wayland' '--disable-gpu' "--remote-debugging-address=${debug_host}" "--remote-debugging-port=${debug_port}"; do
    if printf '%s\n' "${cmdline}" | grep -F -- "${option}" >/dev/null; then
      log_ok "Chromium-optie aanwezig: ${option}"
    else
      log_error "Chromium-optie ontbreekt: ${option}"
      failed=1
    fi
  done

  if [ -n "${profile_dir}" ]; then
    expected_profile="${KIOSK_HOME}/${profile_dir}"
    printf '%s\n' "${cmdline}" | grep -F -- "--user-data-dir=${expected_profile}" >/dev/null && log_ok "Chromium-profielargument aanwezig" || { log_error "Chromium-profielargument ontbreekt: --user-data-dir=${expected_profile}"; failed=1; }
  else
    printf '%s\n' "${cmdline}" | grep -F -- '--user-data-dir=' >/dev/null && log_ok "Chromium-profielargument aanwezig" || { log_error "Chromium-profielargument ontbreekt"; failed=1; }
  fi

  if [ -n "${cache_dir}" ]; then
    expected_cache="${KIOSK_HOME}/${cache_dir}"
    printf '%s\n' "${cmdline}" | grep -F -- "--disk-cache-dir=${expected_cache}" >/dev/null && log_ok "Chromium-cacheargument aanwezig" || { log_error "Chromium-cacheargument ontbreekt: --disk-cache-dir=${expected_cache}"; failed=1; }
  else
    printf '%s\n' "${cmdline}" | grep -F -- '--disk-cache-dir=' >/dev/null && log_ok "Chromium-cacheargument aanwezig" || { log_error "Chromium-cacheargument ontbreekt"; failed=1; }
  fi

  return "${failed}"
}

test_debug_port() {
  local failed=0
  local presentation_url offline_page_url debug_host debug_port result
  presentation_url="$(read_config_value PRESENTATION_URL "${CONFIG_FILE}")"
  offline_page_url="$(read_config_value OFFLINE_PAGE_URL "${CONFIG_FILE}")"
  debug_host="$(read_config_value REMOTE_DEBUG_HOST "${CONFIG_FILE}")"
  debug_port="$(read_config_value REMOTE_DEBUG_PORT "${CONFIG_FILE}")"
  offline_page_url="${offline_page_url:-file:///opt/digitalsignage/offline/index.html}"
  debug_host="${debug_host:-127.0.0.1}"
  debug_port="${debug_port:-9222}"

  result="$(python3 - "${debug_host}" "${debug_port}" "${presentation_url}" "${offline_page_url}" <<'PY'
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

host, port, presentation_url, offline_page_url = sys.argv[1:5]

def slides_id(value):
    match = re.search(r"/presentation/d/([^/]+)", urllib.parse.urlparse(value).path)
    return match.group(1) if match else None

def normalized(value):
    parsed = urllib.parse.urlparse(value)
    return (parsed.scheme.lower(), parsed.netloc.lower(), parsed.path.rstrip("/"))

try:
    with urllib.request.urlopen(f"http://{host}:{port}/json", timeout=5) as response:
        targets = json.loads(response.read().decode("utf-8"))
except (urllib.error.URLError, TimeoutError, OSError) as exc:
    print(f"ERROR endpoint:{exc}")
    sys.exit(1)
except json.JSONDecodeError as exc:
    print(f"ERROR json:{exc}")
    sys.exit(1)

if not isinstance(targets, list):
    print("ERROR json:debugpoort gaf geen JSON-lijst")
    sys.exit(1)

page_urls = [str(target.get("url", "")).strip() for target in targets if target.get("type") == "page"]
if not page_urls:
    print("ERROR pages:geen Chromium page-target gevonden")
    sys.exit(1)

configured_slides_id = slides_id(presentation_url)
for url in page_urls:
    if offline_page_url and normalized(url) == normalized(offline_page_url):
        print(f"OK offline {url}")
        sys.exit(0)
    if presentation_url and normalized(url) == normalized(presentation_url):
        print(f"OK slides {url}")
        sys.exit(0)
    if configured_slides_id and slides_id(url) == configured_slides_id:
        print(f"OK slides {url}")
        sys.exit(0)

print("ERROR kiosk:geen relevante kioskpagina gevonden")
for url in page_urls:
    print(f"PAGE {url}")
sys.exit(1)
PY
)"
  if [ $? -ne 0 ]; then
    printf '%s\n' "${result}"
    log_error "Debugpoort bevat geen geldige actuele kioskpagina"
    return 1
  fi

  printf '%s\n' "${result}"
  case "${result}" in
    "OK slides "*)
      log_ok "Actuele Chromium-pagina is Google Slides"
      ;;
    "OK offline "*)
      log_ok "Actuele Chromium-pagina is de lokale offlinepagina"
      ;;
    *)
      log_error "Onverwachte debugpoortclassificatie: ${result}"
      failed=1
      ;;
  esac
  return "${failed}"
}

test_manual_refresh() {
  local failed=0
  run_user_systemctl start digitalsignage-refresh.service || {
    log_error "Handmatige refreshservice start faalt"
    return 1
  }

  local status journal
  journal="$(show_oneshot_result digitalsignage-refresh.service)"
  printf '%s\n' "${journal}"
  status="$(run_user_systemctl status digitalsignage-refresh.service --no-pager 2>&1 || true)"
  printf '%s\n' "${status}"

  printf '%s\n%s\n' "${status}" "${journal}" | grep -E '226/NAMESPACE|Failed to set up mount namespacing' >/dev/null && { log_error "Namespacefout gevonden bij refreshservice"; failed=1; }
  printf '%s\n' "${journal}" | grep -F 'Result=success' >/dev/null && log_ok "Laatste refresh eindigde succesvol" || { log_error "Laatste refresh was niet succesvol"; failed=1; }
  printf '%s\n' "${journal}" | grep -F 'ExecMainStatus=0' >/dev/null && log_ok "Refresh exitstatus 0" || { log_error "Refresh exitstatus is niet 0"; failed=1; }

  return "${failed}"
}

test_resource_log() {
  local failed=0
  local log_file="${KIOSK_HOME}/.local/state/digitalsignage/swap.log"
  run_user_systemctl start digitalsignage-resource-log.service || {
    log_error "Handmatige resource-logservice start faalt"
    return 1
  }

  local journal
  journal="$(show_oneshot_result digitalsignage-resource-log.service)"
  printf '%s\n' "${journal}"
  printf '%s\n' "${journal}" | grep -E '226/NAMESPACE|Failed to set up mount namespacing' >/dev/null && { log_error "Namespacefout gevonden bij resource-logservice"; failed=1; }
  printf '%s\n' "${journal}" | grep -F 'Result=success' >/dev/null && log_ok "Laatste resource-log eindigde succesvol" || { log_error "Laatste resource-log was niet succesvol"; failed=1; }
  printf '%s\n' "${journal}" | grep -F 'ExecMainStatus=0' >/dev/null && log_ok "Resource-log exitstatus 0" || { log_error "Resource-log exitstatus is niet 0"; failed=1; }

  if [ -f "${log_file}" ]; then
    log_ok "Resource-log bestaat: ${log_file}"
  else
    log_error "Resource-log ontbreekt: ${log_file}"
    return 1
  fi

  if sudo -u "${KIOSK_USER}" test -r "${log_file}" && sudo -u "${KIOSK_USER}" test -w "${log_file}"; then
    log_ok "Resource-log is leesbaar en schrijfbaar voor kioskgebruiker"
  else
    log_error "Resource-log is niet leesbaar en schrijfbaar voor kioskgebruiker"
    failed=1
  fi

  tail -n 5 "${log_file}"
  tail -n 5 "${log_file}" | grep -F 'resource=ok' >/dev/null && log_ok "Laatste logregels bevatten resource=ok" || { log_error "Geen resource=ok in laatste logregels"; failed=1; }
  tail -n 5 "${log_file}" | grep -E 'ram_used_mib=.*ram_available_mib=.*swap_used_mib=.*swap_free_mib=' >/dev/null && log_ok "RAM- en swapvelden aanwezig" || { log_error "RAM- en swapvelden ontbreken"; failed=1; }
  return "${failed}"
}

test_health_check() {
  local failed=0
  local state_dir="${KIOSK_HOME}/.local/state/digitalsignage"
  local health_log="${state_dir}/health.log"
  local health_state="${state_dir}/health-state.json"
  local kiosk_pid_before kiosk_pid_after journal status last_line simulation_dir

  kiosk_pid_before="$(get_user_unit_property digitalsignage-kiosk.service MainPID)"
  run_user_systemctl start digitalsignage-health.service || {
    log_error "Handmatige healthservice start faalt"
    return 1
  }

  journal="$(show_oneshot_result digitalsignage-health.service)"
  printf '%s\n' "${journal}"
  status="$(run_user_systemctl status digitalsignage-health.service --no-pager 2>&1 || true)"
  printf '%s\n' "${status}"

  printf '%s\n%s\n' "${status}" "${journal}" | grep -E '226/NAMESPACE|Failed to set up mount namespacing' >/dev/null && { log_error "Namespacefout gevonden bij healthservice"; failed=1; }
  printf '%s\n' "${journal}" | grep -E 'ExecMainStatus=(0|1)' >/dev/null && log_ok "Healthservice exitstatus 0 of verwachte 1" || { log_error "Healthservice exitstatus is niet 0 of 1"; failed=1; }

  if [ -f "${health_log}" ]; then
    log_ok "Health-log bestaat: ${health_log}"
    last_line="$(tail -n 1 "${health_log}")"
    printf '%s\n' "${last_line}"
    printf '%s\n' "${last_line}" | grep -E 'health=(ok|warning|failed)' >/dev/null && log_ok "Health-log bevat healthveld" || { log_error "Health-log mist healthveld"; failed=1; }
    printf '%s\n' "${last_line}" | grep -F 'action=' >/dev/null && log_ok "Health-log bevat actionveld" || { log_error "Health-log mist actionveld"; failed=1; }
    printf '%s\n' "${last_line}" | grep -F 'failures=' >/dev/null && log_ok "Health-log bevat failureteller" || { log_error "Health-log mist failureteller"; failed=1; }
  else
    log_error "Health-log ontbreekt: ${health_log}"
    failed=1
  fi

  if [ -f "${health_state}" ]; then
    python3 -m json.tool "${health_state}" >/dev/null && log_ok "health-state.json is geldige JSON" || { log_error "health-state.json is ongeldig"; failed=1; }
  else
    log_error "health-state.json ontbreekt: ${health_state}"
    failed=1
  fi

  simulation_dir="$(mktemp -d)"
  chown "${KIOSK_USER}:${KIOSK_GROUP}" "${simulation_dir}"
  if run_as_kiosk_user /opt/digitalsignage/scripts/health-check.py --simulate-debug-failure --state-dir "${simulation_dir}"; then
    log_warning "Gesimuleerde fout gaf exitcode 0; controleer output hierboven"
  else
    log_ok "Gesimuleerde fout gaf verwachte niet-nul exitcode"
  fi
  tail -n 1 "${simulation_dir}/health.log" | grep -F 'action=none' >/dev/null && log_ok "Een gesimuleerde fout veroorzaakt geen restart" || { log_error "Gesimuleerde fout probeerde herstelactie"; failed=1; }
  rm -rf "${simulation_dir}"

  kiosk_pid_after="$(get_user_unit_property digitalsignage-kiosk.service MainPID)"
  [ "${kiosk_pid_before}" = "${kiosk_pid_after}" ] && log_ok "Kiosk MainPID bleef gelijk na gezonde health-check en simulatie" || log_warning "Kiosk MainPID veranderde van ${kiosk_pid_before} naar ${kiosk_pid_after}"

  return "${failed}"
}

test_timer() {
  local failed=0 health_properties sub_state active_state next_elapse timers_monotonic timers_output health_seconds
  run_user_systemctl list-timers --all --no-pager | grep digitalsignage || true
  if run_user_systemctl list-timers --all --no-pager | grep -F 'digitalsignage-refresh.timer' >/dev/null; then
    log_ok "Refreshtimer heeft timerinformatie"
  else
    log_error "Refreshtimer ontbreekt in list-timers"
    failed=1
  fi
  if run_user_systemctl list-timers --all --no-pager | grep -F 'digitalsignage-resource-log.timer' >/dev/null; then
    log_ok "Resource-logtimer heeft timerinformatie"
  else
    log_error "Resource-logtimer ontbreekt in list-timers"
    failed=1
  fi
  if run_user_systemctl list-timers --all --no-pager | grep -F 'digitalsignage-health.timer' >/dev/null; then
    log_ok "Healthtimer heeft timerinformatie"
  else
    log_error "Healthtimer ontbreekt in list-timers"
    failed=1
  fi

  run_user_systemctl start digitalsignage-health.service || {
    log_error "Handmatige healthservice-start voor timercontrole faalt"
    return 1
  }
  sleep 2
  health_properties="$(run_user_systemctl show digitalsignage-health.timer --property=TimersMonotonic --property=ActiveState --property=SubState --property=NextElapseUSecMonotonic --property=LastTriggerUSec --no-pager 2>&1 || true)"
  printf '%s\n' "${health_properties}"
  active_state="$(printf '%s\n' "${health_properties}" | awk -F= '$1 == "ActiveState" { print $2 }')"
  sub_state="$(printf '%s\n' "${health_properties}" | awk -F= '$1 == "SubState" { print $2 }')"
  next_elapse="$(printf '%s\n' "${health_properties}" | awk -F= '$1 == "NextElapseUSecMonotonic" { print $2 }')"
  timers_monotonic="$(printf '%s\n' "${health_properties}" | awk -F= '$1 == "TimersMonotonic" { print substr($0, index($0, "=") + 1) }')"
  health_seconds="$(read_config_value HEALTH_CHECK_SECONDS "${CONFIG_FILE}")"
  health_seconds="${health_seconds:-60}"
  [ "${active_state}" = "active" ] && log_ok "Healthtimer ActiveState=active" || { log_error "Healthtimer ActiveState is ${active_state:-leeg}, verwacht active"; failed=1; }
  [ "${sub_state}" != "elapsed" ] && log_ok "Healthtimer blijft niet hangen in SubState=elapsed" || { log_error "Healthtimer staat in SubState=elapsed"; failed=1; }
  [ "${sub_state}" = "waiting" ] && log_ok "Healthtimer SubState=waiting" || { log_error "Healthtimer SubState is ${sub_state:-leeg}, verwacht waiting"; failed=1; }
  [ -n "${next_elapse}" ] && log_ok "Healthtimer heeft een volgende monotone trigger gepland" || { log_error "Healthtimer heeft geen volgende monotone trigger gepland"; failed=1; }
  printf '%s\n' "${timers_monotonic}" | grep -F 'OnActiveUSec=2min' >/dev/null && log_ok "Healthtimer TimersMonotonic bevat OnActiveUSec=2min" || { log_error "Healthtimer TimersMonotonic mist OnActiveUSec=2min"; failed=1; }
  if [ "${health_seconds}" = "60" ]; then
    printf '%s\n' "${timers_monotonic}" | grep -E 'OnUnitInactiveUSec=(60s|1min)' >/dev/null && log_ok "Healthtimer TimersMonotonic gebruikt HEALTH_CHECK_SECONDS=60" || { log_error "Healthtimer TimersMonotonic mist OnUnitInactiveUSec=1min"; failed=1; }
  else
    printf '%s\n' "${timers_monotonic}" | grep -F "OnUnitInactiveUSec=${health_seconds}s" >/dev/null && log_ok "Healthtimer TimersMonotonic gebruikt HEALTH_CHECK_SECONDS=${health_seconds}" || { log_error "Healthtimer TimersMonotonic mist OnUnitInactiveUSec=${health_seconds}s"; failed=1; }
  fi

  timers_output="$(run_user_systemctl list-timers --all --no-pager 2>&1 || true)"
  printf '%s\n' "${timers_output}" | awk '/digitalsignage-health.timer/ { found=1; if ($1 != "-" && $1 != "n/a") ok=1 } END { exit(found && ok ? 0 : 1) }' && log_ok "Healthtimer heeft een echte toekomstige trigger in list-timers" || { log_error "Healthtimer heeft geen echte toekomstige trigger in list-timers"; failed=1; }

  return "${failed}"
}

test_system_status() {
  local failed=0
  systemctl --failed --no-pager || true
  free -h || true
  df -h / || true

  if systemctl --failed --no-legend --no-pager | grep -F 'digitalsignage' >/dev/null; then
    log_error "Gefaalde Digital Signage systeemservice gevonden"
    failed=1
  else
    log_ok "Geen gefaalde Digital Signage systeemservices"
  fi

  local other_failed
  other_failed="$(systemctl --failed --no-legend --no-pager | grep -v 'digitalsignage' || true)"
  if [ -n "${other_failed}" ]; then
    log_warning "Andere gefaalde services gevonden:"
    printf '%s\n' "${other_failed}"
  fi

  return "${failed}"
}

test_journals() {
  local unit output unit_state
  for unit in digitalsignage-kiosk.service digitalsignage-refresh.service digitalsignage-refresh.timer digitalsignage-resource-log.service digitalsignage-resource-log.timer digitalsignage-health.service digitalsignage-health.timer; do
    log_info "Laatste journalregels voor ${unit}"
    unit_state="$(run_user_systemctl show "${unit}" --property=Result --property=ExecMainStatus --property=ActiveState --no-pager 2>&1 || true)"
    output="$(read_unit_journal "${unit}" 2>&1)"
    printf '%s\n' "${output}"
    if ! journal_has_entries "${output}" &&
      printf '%s\n' "${unit_state}" | grep -E 'ActiveState=active|Result=success|ExecMainStatus=0' >/dev/null; then
      log_warning "Geen journalregels gevonden voor gezonde of succesvol uitgevoerde unit: ${unit}"
    fi
  done
  return 0
}

run_test "Gebruiker en configuratie" test_user_and_config
run_test "Installatiepaden" test_install_paths
run_test "Desktopachtergrond" test_desktop_background
run_test "Statusmap" test_status_directory
run_test "User-systemd" test_user_systemd
run_test "Chromium" test_chromium
run_test "Debugpoort" test_debug_port
run_test "Handmatige refresh" test_manual_refresh
run_test "Resource-log" test_resource_log
run_test "Health-check" test_health_check
run_test "Timer" test_timer
run_test "Systeemstatus" test_system_status
run_test "Journals" test_journals

print_summary
