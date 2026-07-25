#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-library.sh
source "${SCRIPT_DIR}/test-library.sh"

init_test_context "pre-install"

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
    "services/digitalsignage-kiosk.service"
    "services/digitalsignage-refresh.service"
    "services/digitalsignage-refresh.timer"
    "config/digitalsignage.conf.example"
  )

  for file in "${required_files[@]}"; do
    if [ -e "${TEST_ROOT_DIR}/${file}" ]; then
      log_ok "Bestand bestaat: ${file}"
    else
      log_error "Bestand ontbreekt: ${file}"
      failed=1
    fi
  done

  for file in install/install.sh install/upgrade.sh install/uninstall.sh scripts/start-kiosk.sh scripts/refresh-kiosk.sh scripts/restart-chromium.sh scripts/health-check.sh; do
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
  local cache_dir="${TEST_ROOT_DIR}/scripts/__pycache__"
  local before_marker after_marker
  before_marker="$(find "${cache_dir}" -type f -name 'refresh-presentation*.pyc' -print 2>/dev/null || true)"
  if python3 -m py_compile "${TEST_ROOT_DIR}/scripts/refresh-presentation.py"; then
    log_ok "Python-syntaxis is geldig"
  else
    log_error "Python-syntaxiscontrole faalt"
    return 1
  fi
  after_marker="$(find "${cache_dir}" -type f -name 'refresh-presentation*.pyc' -print 2>/dev/null || true)"
  if [ -n "${after_marker}" ] && [ "${after_marker}" != "${before_marker}" ]; then
    find "${cache_dir}" -type f -name 'refresh-presentation*.pyc' -delete 2>/dev/null || true
    rmdir "${cache_dir}" 2>/dev/null || true
    log_info "Door py_compile gemaakte cache veilig opgeruimd"
  fi
  return 0
}

test_systemd_units() {
  local failed=0
  local output status unit
  for unit in services/digitalsignage-kiosk.service services/digitalsignage-refresh.service services/digitalsignage-refresh.timer; do
    output="$(systemd-analyze --user verify "${TEST_ROOT_DIR}/${unit}" 2>&1)"
    status=$?
    if [ -n "${output}" ]; then
      printf '%s\n' "${output}"
    fi
    if [ "${status}" -eq 0 ]; then
      log_ok "systemd-analyze verify: ${unit}"
    elif printf '%s\n' "${output}" | grep -q '/opt/digitalsignage'; then
      log_warning "Verwachte pre-install melding voor ${unit}: /opt/digitalsignage bestaat mogelijk nog niet"
    else
      log_error "systemd-analyze verify faalt: ${unit}"
      failed=1
    fi
  done
  return "${failed}"
}

test_forbidden_patterns() {
  local failed=0
  local pattern
  local home_prefix="/home"
  for pattern in "${home_prefix}/pi" "${home_prefix}/bloemkool" 'chromium-browser' 'DISPLAY=:0' 'export DISPLAY' 'DISPLAY_ID' 'xdotool' 'pkill -HUP'; do
    if grep -R -n -F "${pattern}" "${TEST_ROOT_DIR}/install" "${TEST_ROOT_DIR}/scripts" "${TEST_ROOT_DIR}/services" "${TEST_ROOT_DIR}/config"; then
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
  for key in PRESENTATION_URL OFFLINE_URL CHROMIUM_BIN WAYLAND_DISPLAY REMOTE_DEBUG_HOST REMOTE_DEBUG_PORT CACHE_SIZE_MB KIOSK_USER REFRESH_SECONDS SWAP_LOG_MAX_BYTES; do
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
  if grep -R -n -E "${home_prefix}/(pi|bloemkool)" "${TEST_ROOT_DIR}/install" "${TEST_ROOT_DIR}/scripts" "${TEST_ROOT_DIR}/services" "${TEST_ROOT_DIR}/config"; then
    log_error "Hardcoded kiosk-homefolder gevonden"
    failed=1
  else
    log_ok "Geen hardcoded kiosk-homefolder gevonden"
  fi

  if grep -q '^ReadWritePaths=' "${TEST_ROOT_DIR}/services/digitalsignage-refresh.service"; then
    log_error "Refreshservice gebruikt nog ReadWritePaths"
    failed=1
  else
    log_ok "Refreshservice gebruikt geen fragiele ReadWritePaths"
  fi

  if grep -q '^StateDirectory=digitalsignage$' "${TEST_ROOT_DIR}/services/digitalsignage-refresh.service"; then
    log_ok "StateDirectory=digitalsignage aanwezig"
  else
    log_error "StateDirectory=digitalsignage ontbreekt"
    failed=1
  fi

  return "${failed}"
}

run_test "Systeem" test_system
run_test "Benodigde commando's" test_commands
run_test "Repository" test_repository
run_test "Bash-syntaxis" test_bash_syntax
run_test "Python-syntaxis" test_python_syntax
run_test "systemd-units" test_systemd_units
run_test "Verboden patronen" test_forbidden_patterns
run_test "Configuratie" test_config
run_test "Statusmap-oplossing" test_state_directory_fix

print_summary
