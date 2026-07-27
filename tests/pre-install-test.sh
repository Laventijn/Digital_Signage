#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-library.sh
source "${SCRIPT_DIR}/test-library.sh"

init_test_context "pre-install"

is_expected_preinstall_opt_warning() {
  local output="$1"
  local line saw_execstart_warning=0
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    case "${line}" in
      *.service:|*.timer:)
        ;;
      "Command /opt/digitalsignage/"*" is not executable: No such file or directory")
        saw_execstart_warning=1
        ;;
      *)
        return 1
        ;;
    esac
  done <<EOF
${output}
EOF
  [ "${saw_execstart_warning}" -eq 1 ]
}

test_system() {
  local failed=0
  if [ -f /etc/os-release ]; then
    log_ok "/etc/os-release bestaat"
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID:-}" in
      debian|raspbian)
        log_ok "Ondersteund OS gedetecteerd: ${PRETTY_NAME:-${ID}}"
        ;;
      *)
        if printf '%s\n' "${PRETTY_NAME:-}" | grep -qi 'Raspberry Pi OS'; then
          log_ok "Raspberry Pi OS gedetecteerd: ${PRETTY_NAME}"
        else
          log_error "Onverwacht OS: ${PRETTY_NAME:-onbekend}"
          failed=1
        fi
        ;;
    esac
  else
    log_error "/etc/os-release ontbreekt"
    failed=1
  fi

  local arch
  arch="$(uname -m 2>/dev/null || true)"
  case "${arch}" in
    aarch64|arm64) log_ok "Architectuur: ${arch}" ;;
    *) log_warning "Afwijkende architectuur: ${arch:-onbekend}; syntaxcontroles kunnen nog bruikbaar zijn" ;;
  esac

  log_info "Kernel: $(uname -a 2>/dev/null || echo onbekend)"
  log_info "Hostname: $(hostname 2>/dev/null || echo onbekend)"

  local mem_available_kib
  mem_available_kib="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "${mem_available_kib:-0}" -ge 307200 ]; then
    log_ok "Minstens 300 MiB RAM beschikbaar"
  else
    log_error "Minder dan 300 MiB RAM beschikbaar"
    failed=1
  fi

  local free_root_mib
  free_root_mib="$(df -Pm / 2>/dev/null | awk 'NR==2 { print $4 }')"
  if [ "${free_root_mib:-0}" -ge 1024 ]; then
    log_ok "Minstens 1 GiB vrije ruimte op /"
  else
    log_error "Minder dan 1 GiB vrije ruimte op /"
    failed=1
  fi

  return "${failed}"
}

test_commands() {
  local failed=0
  local command_name
  for command_name in bash python3 systemctl systemd-analyze grep find getent install curl git; do
    if command_exists "${command_name}"; then
      log_ok "Commando aanwezig: ${command_name}"
    else
      log_error "Commando ontbreekt: ${command_name}"
      failed=1
    fi
  done

  if [ -x /usr/bin/chromium ]; then
    log_ok "Chromium aanwezig: /usr/bin/chromium"
  else
    log_error "Chromium ontbreekt of is niet uitvoerbaar: /usr/bin/chromium"
    failed=1
  fi

  return "${failed}"
}

test_repository() {
  local failed=0
  local file
  local required_files=(
    "install/install.sh"
    "install/upgrade.sh"
    "install/uninstall.sh"
    "scripts/start-kiosk.sh"
    "scripts/refresh-presentation.py"
    "scripts/capture-content-cache.py"
    "scripts/digitalsignage_config.py"
    "scripts/log-resources.py"
    "scripts/health-check.py"
    "scripts/configure-desktop-background.sh"
    "assets/wallpapers/digitalsignage-background.png"
    "services/digitalsignage-kiosk.service"
    "services/digitalsignage-refresh.service"
    "services/digitalsignage-refresh.timer"
    "services/digitalsignage-resource-log.service"
    "services/digitalsignage-resource-log.timer"
    "services/digitalsignage-health.service"
    "services/digitalsignage-health.timer"
    "services/digitalsignage-screenshot-cache.service"
    "services/digitalsignage-screenshot-cache.timer"
    "assets/screenshot-player/index.html"
    "assets/screenshot-player/player.css"
    "assets/screenshot-player/player.js"
    "config/digitalsignage.conf.example"
    "tests/test-upgrade-config-merge.sh"
    "tests/test-resource-log-retention.py"
    "tests/test-refresh-presentation.py"
    "tests/test_health_check.py"
    "tests/test-desktop-background.sh"
  )

  for file in "${required_files[@]}"; do
    if [ -e "${TEST_ROOT_DIR}/${file}" ]; then
      log_ok "Bestand bestaat: ${file}"
    else
      log_error "Bestand ontbreekt: ${file}"
      failed=1
    fi
  done

  for file in install/install.sh install/upgrade.sh install/uninstall.sh scripts/start-kiosk.sh scripts/refresh-kiosk.sh scripts/restart-chromium.sh scripts/health-check.sh scripts/health-check.py scripts/refresh-presentation.py scripts/log-resources.py scripts/configure-desktop-background.sh tests/test-desktop-background.sh; do
    if [ -x "${TEST_ROOT_DIR}/${file}" ]; then
      log_ok "Uitvoerbaar: ${file}"
    else
      log_warning "Niet uitvoerbaar in working tree: ${file}"
    fi
  done

  if command_exists git && git -C "${TEST_ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_info "git status --short"
    git -C "${TEST_ROOT_DIR}" status --short || true
    if [ -n "$(git -C "${TEST_ROOT_DIR}" status --short)" ]; then
      log_warning "Working tree is niet schoon"
    fi
    log_info "git log --oneline -3"
    git -C "${TEST_ROOT_DIR}" log --oneline -3 || log_warning "Geen git commits beschikbaar"
  else
    log_warning "Geen bruikbare Git-repository gevonden"
  fi

  return "${failed}"
}

test_bash_syntax() {
  local failed=0
  local file
  while IFS= read -r -d '' file; do
    if [ "${file}" = "${BASH_SOURCE[0]}" ]; then
      log_info "Actief testscript wordt wel syntactisch gecontroleerd: ${file#${TEST_ROOT_DIR}/}"
    fi
    if bash -n "${file}"; then
      log_ok "bash -n: ${file#${TEST_ROOT_DIR}/}"
    else
      log_error "bash -n faalt: ${file#${TEST_ROOT_DIR}/}"
      failed=1
    fi
  done < <(find "${TEST_ROOT_DIR}/install" "${TEST_ROOT_DIR}/scripts" "${TEST_ROOT_DIR}/tests" -type f -name '*.sh' -print0)
  return "${failed}"
}

test_python_syntax() {
  local pycache_dir
  pycache_dir="$(mktemp -d)"
  if PYTHONPYCACHEPREFIX="${pycache_dir}" python3 -m py_compile "${TEST_ROOT_DIR}/scripts/health-check.py" "${TEST_ROOT_DIR}/scripts/refresh-presentation.py" "${TEST_ROOT_DIR}/scripts/capture-content-cache.py" "${TEST_ROOT_DIR}/scripts/digitalsignage_config.py" "${TEST_ROOT_DIR}/scripts/log-resources.py" "${TEST_ROOT_DIR}/tests/test_health_check.py" "${TEST_ROOT_DIR}/tests/test_screenshot_cache.py" "${TEST_ROOT_DIR}/tests/test-resource-log-retention.py" "${TEST_ROOT_DIR}/tests/test-refresh-presentation.py"; then
    log_ok "Python-syntaxis is geldig"
  else
    rm -rf "${pycache_dir}"
    log_error "Python-syntaxiscontrole faalt"
    return 1
  fi
  rm -rf "${pycache_dir}"
  log_info "Python-cache is buiten de repository aangemaakt en opgeruimd"
  return 0
}

test_systemd_units() {
  local failed=0
  local output status unit
  for unit in services/digitalsignage-kiosk.service services/digitalsignage-refresh.service services/digitalsignage-refresh.timer services/digitalsignage-resource-log.service services/digitalsignage-resource-log.timer services/digitalsignage-health.service services/digitalsignage-health.timer services/digitalsignage-screenshot-cache.service services/digitalsignage-screenshot-cache.timer; do
    output="$(systemd-analyze --user verify "${TEST_ROOT_DIR}/${unit}" 2>&1)"
    status=$?
    if [ -n "${output}" ]; then
      printf '%s\n' "${output}"
    fi
    if [ "${status}" -eq 0 ]; then
      log_ok "systemd-analyze verify: ${unit}"
    elif is_expected_preinstall_opt_warning "${output}"; then
      log_warning "Verwachte pre-install melding voor ${unit}: /opt/digitalsignage bestaat mogelijk nog niet"
    else
      log_error "systemd-analyze verify faalt: ${unit}"
      failed=1
    fi
  done
  return "${failed}"
}

test_runner_sudo_handling() {
  local runner="${TEST_ROOT_DIR}/tests/run-tests.sh"
  local failed=0
  [ "$(id -u)" -ne 0 ] && log_ok "Pre-installatietest draait zonder rootrechten" || { log_error "Pre-installatietest draait als root"; failed=1; }
  grep -q 'SUDO_USER' "${runner}" && log_ok "run-tests.sh controleert SUDO_USER" || { log_error "SUDO_USER-controle ontbreekt"; failed=1; }
  grep -q 'DIGITALSIGNAGE_PRE_REEXEC' "${runner}" && log_ok "run-tests.sh voorkomt een herstartlus" || { log_error "Herstartlusbescherming ontbreekt"; failed=1; }
  grep -q 'user_runtime="/run/user/${original_uid}"' "${runner}" &&
    grep -q 'XDG_RUNTIME_DIR="${user_runtime}"' "${runner}" &&
    log_ok "run-tests.sh bepaalt XDG_RUNTIME_DIR uit UID" || { log_error "XDG_RUNTIME_DIR-bepaling ontbreekt"; failed=1; }
  grep -q 'DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}"' "${runner}" && log_ok "run-tests.sh zet user D-Bus-adres" || { log_error "D-Bus-adres ontbreekt"; failed=1; }
  grep -q 'runuser -u "${original_user}"' "${runner}" && log_ok "run-tests.sh schakelt terug naar SUDO_USER" || { log_error "Terugschakelen naar SUDO_USER ontbreekt"; failed=1; }
  return "${failed}"
}

test_systemd_warning_classification() {
  local expected_output bad_manager bad_syntax failed=0
  expected_output=$'digitalsignage-resource-log.service:\nCommand /opt/digitalsignage/scripts/log-resources.py is not executable: No such file or directory'
  bad_manager="Failed to initialize manager: No such device or address"
  bad_syntax="Unknown key name 'BogusDirective' in section 'Service', ignoring."

  if is_expected_preinstall_opt_warning "${expected_output}"; then
    log_ok "Ontbrekend /opt ExecStart-bestand wordt waarschuwing"
  else
    log_error "Ontbrekend /opt ExecStart-bestand wordt niet als waarschuwing herkend"
    failed=1
  fi

  if is_expected_preinstall_opt_warning "${bad_manager}"; then
    log_error "Failed to initialize manager wordt ten onrechte waarschuwing"
    failed=1
  else
    log_ok "Failed to initialize manager blijft een fout"
  fi

  if is_expected_preinstall_opt_warning "${bad_syntax}"; then
    log_error "Systemd-syntaxfout wordt ten onrechte waarschuwing"
    failed=1
  else
    log_ok "Systemd-syntaxfout blijft een fout"
  fi

  return "${failed}"
}

test_installer_executable_modes() {
  local failed=0
  for file in install/install.sh install/upgrade.sh; do
    if grep -q 'install -m 0755 .*scripts' "${TEST_ROOT_DIR}/${file}"; then
      log_ok "${file} installeert scripts met modus 0755"
    else
      log_error "${file} installeert scripts niet aantoonbaar met modus 0755"
      failed=1
    fi
  done
  return "${failed}"
}

test_upgrade_config_merge() {
  if bash "${TEST_ROOT_DIR}/tests/test-upgrade-config-merge.sh"; then
    log_ok "Upgradeconfiguratie vult ontbrekende variabelen idempotent aan"
  else
    log_error "Upgradeconfiguratie-merge faalt"
    return 1
  fi
}

test_resource_log_retention() {
  if python3 "${TEST_ROOT_DIR}/tests/test-resource-log-retention.py"; then
    log_ok "Resource-logretentie bewaart recente historische regels en verwijdert oude regels"
  else
    log_error "Resource-logretentietest faalt"
    return 1
  fi
}

test_refresh_presentation_unit() {
  if python3 "${TEST_ROOT_DIR}/tests/test-refresh-presentation.py"; then
    log_ok "Refresh-presentatie unit tests slagen"
  else
    log_error "Refresh-presentatie unit tests falen"
    return 1
  fi
}

test_health_check_unit() {
  if python3 -m unittest "${TEST_ROOT_DIR}/tests/test_health_check.py"; then
    log_ok "Health-check unit tests slagen"
  else
    log_error "Health-check unit tests falen"
    return 1
  fi
}

test_screenshot_cache_unit() {
  if python3 -m unittest "${TEST_ROOT_DIR}/tests/test_screenshot_cache.py"; then
    log_ok "Screenshotcache unit tests slagen"
  else
    log_error "Screenshotcache unit tests falen"
    return 1
  fi
}

test_desktop_background_unit() {
  if bash "${TEST_ROOT_DIR}/tests/test-desktop-background.sh"; then
    log_ok "Desktopachtergrondtests slagen"
  else
    log_error "Desktopachtergrondtests falen"
    return 1
  fi
}

test_forbidden_patterns() {
  local failed=0
  local pattern
  local home_prefix="/home"
  for pattern in "${home_prefix}/pi" "${home_prefix}/bloemkool" 'chromium-browser' 'DISPLAY=:0' 'export DISPLAY' 'DISPLAY_ID' 'xdotool' 'pkill -HUP' 'shell=True' 'pkill' 'killall' 'sudo systemctl' 'wayfire.ini' 'google-service-account.json' 'Google Slides API' 'serviceaccount'; do
    if grep -R -n -F --exclude-dir=__pycache__ --exclude='*.pyc' --exclude='*.pyo' "${pattern}" "${TEST_ROOT_DIR}/install" "${TEST_ROOT_DIR}/scripts" "${TEST_ROOT_DIR}/services" "${TEST_ROOT_DIR}/config"; then
      log_error "Verboden patroon gevonden: ${pattern}"
      failed=1
    else
      log_ok "Verboden patroon afwezig: ${pattern}"
    fi
  done
  return "${failed}"
}

test_config() {
  local failed=0
  local config="${TEST_ROOT_DIR}/config/digitalsignage.conf.example"
  local key value
  for key in CONTENT_MODE CONTENT_URL PRESENTATION_URL SCREENSHOT_CACHE_ENABLED SCREENSHOT_CACHE_REFRESH_SECONDS SCREENSHOT_CAPTURE_DEBUG_PORT OFFLINE_WATERMARK_TEXT WEBSITE_OFFLINE_CAPTURE_MODE OFFLINE_URL CHROMIUM_BIN WAYLAND_DISPLAY REMOTE_DEBUG_HOST REMOTE_DEBUG_PORT CACHE_SIZE_MB KIOSK_USER REFRESH_SECONDS SWAP_LOG_MAX_BYTES RESOURCE_LOG_RETENTION_DAYS HEALTH_CHECK_SECONDS HEALTH_FAILURE_THRESHOLD HEALTH_RESTART_COOLDOWN_SECONDS HEALTH_HTTP_TIMEOUT_SECONDS HEALTH_STARTUP_GRACE_SECONDS HEALTH_LOG_RETENTION_DAYS HEALTH_LOG_MAX_BYTES DESKTOP_BACKGROUND_ENABLED DESKTOP_BACKGROUND_FILE DESKTOP_BACKGROUND_MODE; do
    if [ -n "$(read_config_value "${key}" "${config}")" ]; then
      log_ok "Configvariabele aanwezig: ${key}"
    else
      log_error "Configvariabele ontbreekt of is leeg: ${key}"
      failed=1
    fi
  done

  value="$(read_config_value CHROMIUM_BIN "${config}")"
  [ "${value}" = "/usr/bin/chromium" ] && log_ok "CHROMIUM_BIN correct" || { log_error "CHROMIUM_BIN is '${value}'"; failed=1; }
  value="$(read_config_value REMOTE_DEBUG_HOST "${config}")"
  [ "${value}" = "127.0.0.1" ] && log_ok "REMOTE_DEBUG_HOST correct" || { log_error "REMOTE_DEBUG_HOST is '${value}'"; failed=1; }
  value="$(read_config_value REMOTE_DEBUG_PORT "${config}")"
  [ "${value}" = "9222" ] && log_ok "REMOTE_DEBUG_PORT correct" || { log_error "REMOTE_DEBUG_PORT is '${value}'"; failed=1; }
  value="$(read_config_value REFRESH_SECONDS "${config}")"
  [ "${value}" = "300" ] && log_ok "REFRESH_SECONDS standaard 300" || { log_error "REFRESH_SECONDS is '${value}', verwacht 300"; failed=1; }
  value="$(read_config_value HEALTH_CHECK_SECONDS "${config}")"
  [ "${value}" = "15" ] && log_ok "HEALTH_CHECK_SECONDS standaard 15" || { log_error "HEALTH_CHECK_SECONDS is '${value}', verwacht 15"; failed=1; }
  value="$(read_config_value DESKTOP_BACKGROUND_ENABLED "${config}")"
  [ "${value}" = "true" ] && log_ok "DESKTOP_BACKGROUND_ENABLED standaard true" || { log_error "DESKTOP_BACKGROUND_ENABLED is '${value}', verwacht true"; failed=1; }
  value="$(read_config_value DESKTOP_BACKGROUND_FILE "${config}")"
  [ "${value}" = "/opt/digitalsignage/assets/wallpapers/digitalsignage-background.png" ] && log_ok "DESKTOP_BACKGROUND_FILE correct" || { log_error "DESKTOP_BACKGROUND_FILE is '${value}'"; failed=1; }
  value="$(read_config_value DESKTOP_BACKGROUND_MODE "${config}")"
  [ "${value}" = "zoom" ] && log_ok "DESKTOP_BACKGROUND_MODE standaard zoom" || { log_error "DESKTOP_BACKGROUND_MODE is '${value}', verwacht zoom"; failed=1; }

  return "${failed}"
}

test_desktop_background_integration() {
  local failed=0
  grep -q 'assets/wallpapers/digitalsignage-background.png' "${TEST_ROOT_DIR}/install/install.sh" && log_ok "Installer installeert desktopachtergrond" || { log_error "Installer verwerkt desktopachtergrond niet"; failed=1; }
  grep -q 'configure-desktop-background.sh' "${TEST_ROOT_DIR}/install/install.sh" && log_ok "Installer voert desktopachtergrondscript uit" || { log_error "Installer voert desktopachtergrondscript niet uit"; failed=1; }
  grep -q 'assets/wallpapers/digitalsignage-background.png' "${TEST_ROOT_DIR}/install/upgrade.sh" && log_ok "Upgrader installeert desktopachtergrond" || { log_error "Upgrader verwerkt desktopachtergrond niet"; failed=1; }
  grep -q 'configure-desktop-background.sh' "${TEST_ROOT_DIR}/install/upgrade.sh" && log_ok "Upgrader voert desktopachtergrondscript uit" || { log_error "Upgrader voert desktopachtergrondscript niet uit"; failed=1; }
  grep -q 'desktop-items-0.conf' "${TEST_ROOT_DIR}/install/uninstall.sh" && log_ok "Uninstaller documenteert achterblijvende desktopconfiguratie" || { log_error "Uninstaller meldt desktopconfiguratie niet"; failed=1; }
  grep -q 'pcmanfm' "${TEST_ROOT_DIR}/scripts/configure-desktop-background.sh" && log_ok "Desktopachtergrond gebruikt pcmanfm-configuratie" || { log_error "Desktopachtergrondmethode ontbreekt"; failed=1; }
  if grep -R -n -F --exclude-dir=__pycache__ --exclude='*.pyc' --exclude='*.pyo' 'wayfire' "${TEST_ROOT_DIR}/scripts/configure-desktop-background.sh" "${TEST_ROOT_DIR}/install" "${TEST_ROOT_DIR}/config"; then
    log_error "Wayfire-configuratie gevonden in desktopachtergrondimplementatie"
    failed=1
  else
    log_ok "Geen Wayfire-configuratie gebruikt"
  fi
  return "${failed}"
}

test_state_directory_fix() {
  local failed=0
  if grep -q 'user_state_dir=.*\.local/state/digitalsignage' "${TEST_ROOT_DIR}/install/install.sh" &&
    grep -q 'install -d -m 0755 .*"${user_state_dir}"' "${TEST_ROOT_DIR}/install/install.sh"; then
    log_ok "Installer maakt gebruikersstatusmap aan"
  else
    log_error "Installer maakt gebruikersstatusmap niet aantoonbaar aan"
    failed=1
  fi

  if grep -q 'user_state_dir=.*\.local/state/digitalsignage' "${TEST_ROOT_DIR}/install/upgrade.sh" &&
    grep -q 'install -d -m 0755 .*"${user_state_dir}"' "${TEST_ROOT_DIR}/install/upgrade.sh"; then
    log_ok "Upgrader maakt gebruikersstatusmap aan"
  else
    log_error "Upgrader maakt gebruikersstatusmap niet aantoonbaar aan"
    failed=1
  fi

  local home_prefix="/home"
  if grep -R -n -E --exclude-dir=__pycache__ --exclude='*.pyc' --exclude='*.pyo' "${home_prefix}/(pi|bloemkool)" "${TEST_ROOT_DIR}/install" "${TEST_ROOT_DIR}/scripts" "${TEST_ROOT_DIR}/services" "${TEST_ROOT_DIR}/config"; then
    log_error "Hardcoded kiosk-homefolder gevonden"
    failed=1
  else
    log_ok "Geen hardcoded kiosk-homefolder gevonden"
  fi

  if grep -q '^ReadWritePaths=' "${TEST_ROOT_DIR}/services/digitalsignage-resource-log.service"; then
    log_error "Resource-logservice gebruikt nog ReadWritePaths"
    failed=1
  else
    log_ok "Resource-logservice gebruikt geen fragiele ReadWritePaths"
  fi

  if grep -q '^StateDirectory=digitalsignage$' "${TEST_ROOT_DIR}/services/digitalsignage-resource-log.service"; then
    log_ok "StateDirectory=digitalsignage aanwezig"
  else
    log_error "StateDirectory=digitalsignage ontbreekt"
    failed=1
  fi

  if grep -q '^ReadWritePaths=' "${TEST_ROOT_DIR}/services/digitalsignage-health.service"; then
    log_error "Healthservice gebruikt fragiele ReadWritePaths"
    failed=1
  else
    log_ok "Healthservice gebruikt geen fragiele ReadWritePaths"
  fi

  if grep -q '^StateDirectory=digitalsignage$' "${TEST_ROOT_DIR}/services/digitalsignage-health.service"; then
    log_ok "Healthservice gebruikt StateDirectory=digitalsignage"
  else
    log_error "Healthservice definieert geen StateDirectory=digitalsignage"
    failed=1
  fi

  return "${failed}"
}

test_health_integration() {
  local failed=0
  grep -q 'digitalsignage-health.service' "${TEST_ROOT_DIR}/install/install.sh" && log_ok "Installer installeert healthservice" || { log_error "Installer verwerkt healthservice niet"; failed=1; }
  grep -q 'digitalsignage-health.timer' "${TEST_ROOT_DIR}/install/install.sh" && log_ok "Installer installeert healthtimer" || { log_error "Installer verwerkt healthtimer niet"; failed=1; }
  grep -q 'digitalsignage-health.timer.d' "${TEST_ROOT_DIR}/install/install.sh" && log_ok "Installer schrijft healthtimer-drop-in" || { log_error "Installer schrijft geen healthtimer-drop-in"; failed=1; }
  grep -q 'digitalsignage-health.service' "${TEST_ROOT_DIR}/install/upgrade.sh" && log_ok "Upgrader werkt healthservice bij" || { log_error "Upgrader verwerkt healthservice niet"; failed=1; }
  grep -q 'digitalsignage-health.timer' "${TEST_ROOT_DIR}/install/upgrade.sh" && log_ok "Upgrader werkt healthtimer bij" || { log_error "Upgrader verwerkt healthtimer niet"; failed=1; }
  grep -q 'digitalsignage-health.timer' "${TEST_ROOT_DIR}/install/uninstall.sh" && log_ok "Uninstaller verwijdert healthtimer" || { log_error "Uninstaller verwerkt healthtimer niet"; failed=1; }
  grep -q 'SuccessExitStatus=0 1' "${TEST_ROOT_DIR}/services/digitalsignage-health.service" && log_ok "Healthservice accepteert exitcode 1 als verwachte ongezonde status" || { log_error "SuccessExitStatus=0 1 ontbreekt"; failed=1; }
  grep -q '^OnActiveSec=2min$' "${TEST_ROOT_DIR}/services/digitalsignage-health.timer" && log_ok "Healthtimer heeft OnActiveSec voor eerste run na timerstart" || { log_error "Healthtimer mist OnActiveSec=2min"; failed=1; }
  grep -q '^OnUnitInactiveSec=60s$' "${TEST_ROOT_DIR}/services/digitalsignage-health.timer" && log_ok "Healthtimer gebruikt OnUnitInactiveSec" || { log_error "Healthtimer mist OnUnitInactiveSec=60s"; failed=1; }
  if grep -q '^OnUnitActiveSec=60s$' "${TEST_ROOT_DIR}/services/digitalsignage-health.timer"; then
    log_error "Healthtimer gebruikt nog actieve OnUnitActiveSec=60s"
    failed=1
  else
    log_ok "Healthtimer gebruikt geen actieve OnUnitActiveSec=60s"
  fi
  grep -q '^OnBootSec=$' "${TEST_ROOT_DIR}/install/install.sh" && grep -q '^OnActiveSec=2min$' "${TEST_ROOT_DIR}/install/install.sh" && grep -q '^OnUnitInactiveSec=${interval}s$' "${TEST_ROOT_DIR}/install/install.sh" &&
    log_ok "Installer-drop-in reset OnBootSec en bouwt OnActiveSec en OnUnitInactiveSec op" || { log_error "Installer-drop-in voor healthtimer is onjuist"; failed=1; }
  grep -q '^OnBootSec=$' "${TEST_ROOT_DIR}/install/upgrade.sh" && grep -q '^OnActiveSec=2min$' "${TEST_ROOT_DIR}/install/upgrade.sh" && grep -q '^OnUnitInactiveSec=${interval}s$' "${TEST_ROOT_DIR}/install/upgrade.sh" &&
    log_ok "Upgrader-drop-in reset OnBootSec en bouwt OnActiveSec en OnUnitInactiveSec op" || { log_error "Upgrader-drop-in voor healthtimer is onjuist"; failed=1; }

  if grep -q 'sudo' "${TEST_ROOT_DIR}/scripts/health-check.py"; then
    log_error "health-check.py bevat sudo"
    failed=1
  else
    log_ok "health-check.py gebruikt geen sudo"
  fi

  if grep -q 'shell=True' "${TEST_ROOT_DIR}/scripts/health-check.py"; then
    log_error "health-check.py gebruikt shell=True"
    failed=1
  else
    log_ok "health-check.py gebruikt geen shell=True"
  fi

  if grep -E 'pkill|killall|reboot' "${TEST_ROOT_DIR}/scripts/health-check.py"; then
    log_error "health-check.py bevat verboden herstelcommando"
    failed=1
  else
    log_ok "health-check.py bevat geen pkill, killall of reboot"
  fi
  return "${failed}"
}

run_test "Systeem" test_system
run_test "Benodigde commando's" test_commands
run_test "Repository" test_repository
run_test "Pre-test zonder sudo" test_runner_sudo_handling
run_test "Bash-syntaxis" test_bash_syntax
run_test "Python-syntaxis" test_python_syntax
run_test "Systemd-waarschuwingsclassificatie" test_systemd_warning_classification
run_test "systemd-units" test_systemd_units
run_test "Uitvoerrechten installatie" test_installer_executable_modes
run_test "Upgradeconfiguratie-merge" test_upgrade_config_merge
run_test "Resource-logretentie" test_resource_log_retention
run_test "Refresh-presentatie unit tests" test_refresh_presentation_unit
run_test "Health-check unit tests" test_health_check_unit
run_test "Screenshotcache unit tests" test_screenshot_cache_unit
run_test "Desktopachtergrondtests" test_desktop_background_unit
run_test "Verboden patronen" test_forbidden_patterns
run_test "Configuratie" test_config
run_test "Statusmap-oplossing" test_state_directory_fix
run_test "Health-check integratie" test_health_integration
run_test "Desktopachtergrond integratie" test_desktop_background_integration

print_summary
