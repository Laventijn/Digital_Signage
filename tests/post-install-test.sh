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

run_user_systemctl() {
  local args=("$@")
  if [ -z "${KIOSK_USER}" ] || [ -z "${KIOSK_UID}" ]; then
    log_error "Kioskgebruiker of UID is niet bepaald"
    return 1
  fi

  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "${KIOSK_USER}" \
      XDG_RUNTIME_DIR="/run/user/${KIOSK_UID}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${KIOSK_UID}/bus" \
      systemctl --user "${args[@]}"
  else
    XDG_RUNTIME_DIR="/run/user/${KIOSK_UID}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${KIOSK_UID}/bus" \
      systemctl --user "${args[@]}"
  fi
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
  for path in /opt/digitalsignage /etc/digitalsignage/digitalsignage.conf /opt/digitalsignage/scripts/start-kiosk.sh /opt/digitalsignage/scripts/refresh-presentation.py /opt/digitalsignage/scripts/log-resources.py; do
    if [ -e "${path}" ]; then
      log_ok "Installatiepad bestaat: ${path}"
    else
      log_error "Installatiepad ontbreekt: ${path}"
      failed=1
    fi
  done

  for path in /opt/digitalsignage/scripts/start-kiosk.sh /opt/digitalsignage/scripts/refresh-presentation.py /opt/digitalsignage/scripts/log-resources.py; do
    if [ -x "${path}" ]; then
      log_ok "Script is uitvoerbaar: ${path}"
    else
      log_error "Script is niet uitvoerbaar: ${path}"
      failed=1
    fi
  done
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
  local unit
  if [ ! -S "/run/user/${KIOSK_UID}/bus" ]; then
    log_error "Geen actieve user-D-Bus gevonden: /run/user/${KIOSK_UID}/bus"
    return 1
  fi

  for unit in digitalsignage-kiosk.service digitalsignage-refresh.service digitalsignage-refresh.timer digitalsignage-resource-log.service digitalsignage-resource-log.timer; do
    run_user_systemctl status "${unit}" --no-pager || log_warning "Statuscontrole gaf niet-nul exitcode voor ${unit}"
  done

  run_user_systemctl is-enabled digitalsignage-kiosk.service >/dev/null && log_ok "Kioskservice is enabled" || { log_error "Kioskservice is niet enabled"; failed=1; }
  run_user_systemctl is-enabled digitalsignage-refresh.timer >/dev/null && log_ok "Refreshtimer is enabled" || { log_error "Refreshtimer is niet enabled"; failed=1; }
  run_user_systemctl is-enabled digitalsignage-resource-log.timer >/dev/null && log_ok "Resource-logtimer is enabled" || { log_error "Resource-logtimer is niet enabled"; failed=1; }
  run_user_systemctl is-active digitalsignage-kiosk.service >/dev/null && log_ok "Kioskservice is actief" || { log_error "Kioskservice is niet actief"; failed=1; }
  run_user_systemctl is-active digitalsignage-refresh.timer >/dev/null && log_ok "Refreshtimer is actief" || { log_error "Refreshtimer is niet actief"; failed=1; }
  run_user_systemctl is-active digitalsignage-resource-log.timer >/dev/null && log_ok "Resource-logtimer is actief" || { log_error "Resource-logtimer is niet actief"; failed=1; }

  return "${failed}"
}

test_chromium() {
  local failed=0
  local presentation_url cmdline pid
  presentation_url="$(read_config_value PRESENTATION_URL "${CONFIG_FILE}")"
  pid="$(pgrep -u "${KIOSK_UID}" -f '/usr/bin/chromium.*--kiosk' | head -n 1 || true)"
  if [ -z "${pid}" ]; then
    log_error "Geen Chromium-kioskproces gevonden"
    return 1
  fi
  log_ok "Chromium-kioskproces gevonden: PID ${pid}"

  cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline")"
  log_info "Chromium commandline: ${cmdline}"

  local option
  for option in '--ozone-platform=wayland' '--disable-gpu' '--password-store=basic' '--kiosk' '--remote-debugging-address=127.0.0.1' '--remote-debugging-port=9222' '--disk-cache-size='; do
    if printf '%s\n' "${cmdline}" | grep -F -- "${option}" >/dev/null; then
      log_ok "Chromium-optie aanwezig: ${option}"
    else
      log_error "Chromium-optie ontbreekt: ${option}"
      failed=1
    fi
  done

  if [ -n "${presentation_url}" ] && printf '%s\n' "${cmdline}" | grep -F -- "${presentation_url}" >/dev/null; then
    log_ok "Presentatie-URL staat in Chromium commandline"
  else
    log_error "Presentatie-URL ontbreekt in Chromium commandline"
    failed=1
  fi

  if run_user_systemctl status digitalsignage-kiosk.service --no-pager | grep -F "${pid}" >/dev/null; then
    log_ok "Chromium-proces hoort bij kioskservice"
  else
    log_warning "PID niet rechtstreeks teruggevonden in systemctl status"
  fi

  return "${failed}"
}

test_debug_port() {
  local failed=0
  local output
  output="$(curl --silent --show-error --max-time 3 http://127.0.0.1:9222/json 2>&1)"
  if [ $? -ne 0 ]; then
    printf '%s\n' "${output}"
    log_error "Debugpoort reageert niet"
    return 1
  fi
  printf '%s\n' "${output}" | head -c 1000
  printf '\n'

  printf '%s\n' "${output}" | grep -F '"type": "page"' >/dev/null && log_ok "Minstens een page-target gevonden" || { log_error "Geen page-target gevonden"; failed=1; }
  printf '%s\n' "${output}" | grep -F 'docs.google.com/presentation/' >/dev/null && log_ok "Google Slides-target gevonden" || { log_error "Geen Google Slides-target gevonden"; failed=1; }
  printf '%s\n' "${output}" | grep -F 'webSocketDebuggerUrl' >/dev/null && log_ok "webSocketDebuggerUrl aanwezig" || { log_error "webSocketDebuggerUrl ontbreekt"; failed=1; }
  return "${failed}"
}

test_manual_refresh() {
  local failed=0
  run_user_systemctl start digitalsignage-refresh.service || {
    log_error "Handmatige refreshservice start faalt"
    return 1
  }

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! run_user_systemctl is-active digitalsignage-refresh.service >/dev/null; then
      break
    fi
    sleep 1
  done

  local status journal
  status="$(run_user_systemctl status digitalsignage-refresh.service --no-pager 2>&1 || true)"
  printf '%s\n' "${status}"
  journal="$(run_user_systemctl show digitalsignage-refresh.service -p Result -p ExecMainStatus -p ExecMainCode --no-pager 2>&1 || true)"
  printf '%s\n' "${journal}"

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
  journal="$(run_user_systemctl show digitalsignage-resource-log.service -p Result -p ExecMainStatus -p ExecMainCode --no-pager 2>&1 || true)"
  printf '%s\n' "${journal}"
  printf '%s\n' "${journal}" | grep -E '226/NAMESPACE|Failed to set up mount namespacing' >/dev/null && { log_error "Namespacefout gevonden bij resource-logservice"; failed=1; }
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

test_timer() {
  run_user_systemctl list-timers --all --no-pager | grep digitalsignage || true
  if run_user_systemctl list-timers --all --no-pager | grep -F 'digitalsignage-refresh.timer' >/dev/null; then
    log_ok "Refreshtimer heeft timerinformatie"
  else
    log_error "Refreshtimer ontbreekt in list-timers"
    return 1
  fi
  if run_user_systemctl list-timers --all --no-pager | grep -F 'digitalsignage-resource-log.timer' >/dev/null; then
    log_ok "Resource-logtimer heeft timerinformatie"
    return 0
  fi
  log_error "Resource-logtimer ontbreekt in list-timers"
  return 1
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
  local unit
  for unit in digitalsignage-kiosk.service digitalsignage-refresh.service digitalsignage-refresh.timer digitalsignage-resource-log.service digitalsignage-resource-log.timer; do
    log_info "Laatste journalregels voor ${unit}"
    run_user_systemctl --no-pager status "${unit}" >/dev/null 2>&1 || true
    sudo -u "${KIOSK_USER}" \
      XDG_RUNTIME_DIR="/run/user/${KIOSK_UID}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${KIOSK_UID}/bus" \
      journalctl --user -u "${unit}" -n 30 --no-pager || true
  done
  return 0
}

run_test "Gebruiker en configuratie" test_user_and_config
run_test "Installatiepaden" test_install_paths
run_test "Statusmap" test_status_directory
run_test "User-systemd" test_user_systemd
run_test "Chromium" test_chromium
run_test "Debugpoort" test_debug_port
run_test "Handmatige refresh" test_manual_refresh
run_test "Resource-log" test_resource_log
run_test "Timer" test_timer
run_test "Systeemstatus" test_system_status
run_test "Journals" test_journals

print_summary
