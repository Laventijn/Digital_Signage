@echo off
setlocal EnableExtensions DisableDelayedExpansion

chcp 65001 >nul

set "PI_USER=bloemkool"
set "PI_HOST=fmg-pi05.local"
set "PI_PROJECT_DIR=/home/bloemkool/DigitalSignage"
set "PI_TARGET=%PI_USER%@%PI_HOST%"
set "PI_EXPECTED_BRANCH=fase-3-offline-gedrag"
set "PHASE3_TEST_MODE=full"

if not "%~2"=="" (
    echo [FOUT] Onbekende argumenten: %*
    goto failure
)

if not "%~1"=="" (
    if /i "%~1"=="--safe-only" (
        set "PHASE3_TEST_MODE=safe-only"
    ) else (
        echo [FOUT] Onbekend argument: %~1
        echo Gebruik: TestPi.bat of TestPi.bat --safe-only
        goto failure
    )
)

echo.
echo ============================================================
echo Digital Signage - Fase 3-test
echo Betrouwbaar offline gedrag en automatisch herstel
echo ============================================================
echo Raspberry Pi: %PI_TARGET%
echo Projectpad: %PI_PROJECT_DIR%
echo Verwachte branch: %PI_EXPECTED_BRANCH%
echo Testmodus: %PHASE3_TEST_MODE%
echo Logbestand: tools\windows\logs\fase3-test-<timestamp>.log
echo.

if not defined PI_USER (
    echo [FOUT] PI_USER is niet ingesteld.
    goto failure
)

if not defined PI_HOST (
    echo [FOUT] PI_HOST is niet ingesteld.
    goto failure
)

if not defined PI_PROJECT_DIR (
    echo [FOUT] PI_PROJECT_DIR is niet ingesteld.
    goto failure
)

if not defined PI_TARGET (
    echo [FOUT] PI_TARGET kon niet worden opgebouwd.
    goto failure
)

if not defined PI_EXPECTED_BRANCH (
    echo [FOUT] PI_EXPECTED_BRANCH is niet ingesteld.
    goto failure
)

echo(%PI_TARGET%| findstr /c:"@" >nul
if errorlevel 1 (
    echo [FOUT] Ongeldige SSH-bestemming: %PI_TARGET%
    goto failure
)

where ssh >nul 2>nul
if errorlevel 1 (
    echo [FOUT] De Windows SSH-client is niet gevonden.
    goto failure
)

where scp >nul 2>nul
if errorlevel 1 (
    echo [FOUT] De Windows SCP-client is niet gevonden.
    goto failure
)

echo [1/4] SSH-verbinding testen...
ssh -o ConnectTimeout=10 -o BatchMode=no "%PI_TARGET%" "printf 'SSH_OK\n'"
if errorlevel 1 (
    echo [FOUT] SSH-verbinding met de Raspberry Pi is mislukt.
    goto failure
)

echo [OK] SSH-verbinding werkt.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p='%~f0'; $m='### ' + 'POWERSHELL-START ###'; $c=Get-Content -Raw -LiteralPath $p; $i=$c.LastIndexOf($m); if ($i -lt 0) { Write-Error 'PowerShell-marker ontbreekt.'; exit 2 }; Invoke-Expression $c.Substring($i + $m.Length)"
if errorlevel 1 goto failure

:success
echo.
echo [KLAAR] FASE 3 TEST: GESLAAGD
endlocal
exit /b 0

:failure
echo.
echo [WAARSCHUWING] FASE 3 TEST: NIET GESLAAGD
endlocal
exit /b 1

### POWERSHELL-START ###
$ErrorActionPreference = "Stop"

$PiUser = $env:PI_USER
$PiHost = $env:PI_HOST
$PiProjectDir = $env:PI_PROJECT_DIR
$PiExpectedBranch = $env:PI_EXPECTED_BRANCH
$Phase3TestMode = $env:PHASE3_TEST_MODE

$env:TERM = "dumb"
$env:NO_COLOR = "1"
$env:SYSTEMD_COLORS = "0"
$env:SYSTEMD_PAGER = "cat"
$env:GIT_PAGER = "cat"

$scriptDir = Split-Path -Parent $p
$logDir = Join-Path $scriptDir "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$localScript = Join-Path $env:TEMP "digitalsignage-fase3-test-$stamp.sh"
$remoteScript = "/tmp/digitalsignage-fase3-test-$stamp.sh"
$logFile = Join-Path $logDir "fase3-test-$stamp.log"
$sshTarget = "$PiUser@$PiHost"

function Fail($message) {
    Write-Host "[FOUT] $message"
    exit 1
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $Command
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $hasNativeCommandPreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue
    $previousNativeCommandPreference = $null
    try {
        # Native programma's zoals ssh.exe en scp.exe gebruiken stderr ook voor
        # normale verbindingsmeldingen. We lezen daarom expliciet de exitcode.
        $script:ErrorActionPreference = "Continue"
        if ($null -ne $hasNativeCommandPreference) {
            $previousNativeCommandPreference = $global:PSNativeCommandUseErrorActionPreference
            $global:PSNativeCommandUseErrorActionPreference = $false
        }
        & $Command
        return $LASTEXITCODE
    }
    finally {
        if ($null -ne $hasNativeCommandPreference) {
            $global:PSNativeCommandUseErrorActionPreference = $previousNativeCommandPreference
        }
        $script:ErrorActionPreference = $previousErrorActionPreference
    }
}

Write-Host ""
Write-Host "Raspberry Pi: $sshTarget"
Write-Host "Projectpad: $PiProjectDir"
Write-Host "Verwachte branch: $PiExpectedBranch"
Write-Host "Testmodus: $Phase3TestMode"
Write-Host "Logbestand: $logFile"
Write-Host ""

$linuxScript = @'
#!/usr/bin/env bash
set -u
set -o pipefail

export TERM=dumb
export NO_COLOR=1
export SYSTEMD_COLORS=0
export SYSTEMD_PAGER=cat
export GIT_PAGER=cat

OK_COUNT=0
WARNING_COUNT=0
ERROR_COUNT=0
SKIPPED_COUNT=0

TEST_MODE="${PHASE3_TEST_MODE:-full}"
EXPECTED_BRANCH="${PI_EXPECTED_BRANCH:-fase-3-offline-gedrag}"
PROJECT_DIR="${DIGITALSIGNAGE_PROJECT_DIR:-}"
ACTIVE_CONFIG="/etc/digitalsignage/digitalsignage.conf"
INVALID_TEST_URL="https://dit-domein-bestaat-niet.invalid/"
TMP_PREFIX="/tmp/digitalsignage-fase3-$$"
CONFIG_BACKUP="${TMP_PREFIX}-digitalsignage.conf.backup"
STATE_BACKUP="${TMP_PREFIX}-connectivity.state.backup"
TEST_OUTPUT="${TMP_PREFIX}-output.txt"

KIOSK_USER=""
KIOSK_HOME=""
STATE_FILE=""
HEALTH_LOG=""
PRESENTATION_URL=""
OFFLINE_PAGE_URL=""
REMOTE_DEBUG_HOST="127.0.0.1"
REMOTE_DEBUG_PORT="9222"
ORIGINAL_CONFIG_SUM=""
ORIGINAL_STATE_EXISTS=false
CONFIG_BACKUP_CREATED=false
STATE_BACKUP_CREATED=false
HEALTH_TIMER_WAS_ACTIVE=false
LIVE_TEST_STARTED=false
LIVE_TEST_ALLOWED=true
SHORT_INTERRUPTION_PROVEN=false
LONG_INTERRUPTION_PROVEN=false
RECOVERY_PROVEN=false
NO_RESTART_PROVEN=false
CONFIG_RESTORED_PROVEN=false
ORIGINAL_KIOSK_PID=""
ORIGINAL_URL=""
OFFLINE_CHECKSUM_BEFORE=""
OFFLINE_CSS_CHECKSUM_BEFORE=""

section() {
  printf '\n============================================================\n'
  printf '%s\n' "$1"
  printf '============================================================\n'
}

ok() { OK_COUNT=$((OK_COUNT + 1)); printf '[OK] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warning() { WARNING_COUNT=$((WARNING_COUNT + 1)); printf '[WAARSCHUWING] %s\n' "$*"; }
failure() { ERROR_COUNT=$((ERROR_COUNT + 1)); printf '[FOUT] %s\n' "$*"; }
skipped() { SKIPPED_COUNT=$((SKIPPED_COUNT + 1)); printf '[OVERGESLAGEN] %s\n' "$*"; }

finish() {
  section "Eindresultaat"
  current_branch="$(git branch --show-current 2>/dev/null || printf 'onbekend')"
  current_commit="$(git rev-parse --short HEAD 2>/dev/null || printf 'onbekend')"
  kiosk_status="$(systemctl --user is-active digitalsignage-kiosk.service 2>/dev/null || true)"
  health_status="$(systemctl --user is-active digitalsignage-health.timer 2>/dev/null || true)"
  health_substate="$(systemctl --user show digitalsignage-health.timer --property=SubState --value 2>/dev/null || true)"

  printf 'OK:             %s\n' "${OK_COUNT}"
  printf 'Waarschuwingen: %s\n' "${WARNING_COUNT}"
  printf 'Fouten:         %s\n' "${ERROR_COUNT}"
  printf 'Overgeslagen:   %s\n' "${SKIPPED_COUNT}"
  printf 'Testmodus:      %s\n' "${TEST_MODE}"
  printf 'Branch:         %s\n' "${current_branch}"
  printf 'Commit:         %s\n' "${current_commit}"
  printf 'Kioskservice:   %s\n' "${kiosk_status:-onbekend}"
  printf 'Healthtimer:    %s %s\n' "${health_status:-onbekend}" "${health_substate:-}"
  printf 'Lokaal logbestand: wordt door Windows getoond na afloop\n'

  if [ "${TEST_MODE}" = "full" ]; then
    [ "${SHORT_INTERRUPTION_PROVEN}" = true ] && printf 'Korte onderbreking: presentatie bleef zichtbaar\n'
    [ "${LONG_INTERRUPTION_PROVEN}" = true ] && printf 'Langdurige onderbreking: offlinepagina verscheen\n'
    [ "${RECOVERY_PROVEN}" = true ] && printf 'Internetherstel: kioskpagina keerde terug\n'
    [ "${NO_RESTART_PROVEN}" = true ] && printf 'Kioskherstart tijdens netwerkverlies: nee\n'
    [ "${CONFIG_RESTORED_PROVEN}" = true ] && printf 'Configuratie hersteld: ja\n'
  fi

  if [ "${ERROR_COUNT}" -eq 0 ]; then
    printf '\nFASE 3 TEST: GESLAAGD\n'
    exit 0
  fi
  printf '\nFASE 3 TEST: NIET GESLAAGD\n'
  exit 1
}

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

active_key_count() {
  local key="$1"
  local file="$2"
  [ -f "${file}" ] || { printf '0\n'; return 0; }
  awk -F= -v key="${key}" '
    /^[[:space:]]*#/ { next }
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" { count++ }
    END { print count + 0 }
  ' "${file}"
}

is_positive_integer() {
  printf '%s\n' "$1" | grep -E '^[1-9][0-9]*$' >/dev/null
}

is_nonnegative_integer() {
  printf '%s\n' "$1" | grep -E '^[0-9]+$' >/dev/null
}

is_boolean() {
  printf '%s\n' "$1" | grep -Ei '^(true|false|1|0|yes|no|ja|nee|on|off)$' >/dev/null
}

run_check() {
  local label="$1"
  shift
  if "$@"; then
    ok "${label}"
    return 0
  fi
  failure "${label}"
  return 1
}

run_test_script() {
  local script="$1"
  if [ ! -f "${script}" ]; then
    failure "Testscript ontbreekt: ${script}"
    return 1
  fi
  if bash "${script}"; then
    ok "Test geslaagd: ${script}"
    return 0
  fi
  failure "Test gefaald: ${script}"
  return 1
}

assert_file_present() {
  local file="$1"
  if [ -f "${file}" ]; then
    ok "Bestand aanwezig: ${file}"
    return 0
  fi
  failure "Bestand ontbreekt: ${file}"
  return 1
}

assert_single_config_value() {
  local key="$1"
  local expected="$2"
  local file="$3"
  local count value
  count="$(active_key_count "${key}" "${file}")"
  value="$(read_config_value "${key}" "${file}")"
  printf '%s=%s\n' "${key}" "${value}"
  [ "${count}" = "1" ] && ok "${key} staat exact eenmaal actief" || failure "${key} staat ${count} keer actief"
  [ "${value}" = "${expected}" ] && ok "${key} heeft verwachte waarde" || failure "${key} is '${value}', verwacht '${expected}'"
}

refresh_config_values() {
  KIOSK_USER="$(read_config_value KIOSK_USER "${ACTIVE_CONFIG}")"
  PRESENTATION_URL="$(read_config_value PRESENTATION_URL "${ACTIVE_CONFIG}")"
  OFFLINE_PAGE_URL="$(read_config_value OFFLINE_PAGE_URL "${ACTIVE_CONFIG}")"
  REMOTE_DEBUG_HOST="$(read_config_value REMOTE_DEBUG_HOST "${ACTIVE_CONFIG}")"
  REMOTE_DEBUG_PORT="$(read_config_value REMOTE_DEBUG_PORT "${ACTIVE_CONFIG}")"
  REMOTE_DEBUG_HOST="${REMOTE_DEBUG_HOST:-127.0.0.1}"
  REMOTE_DEBUG_PORT="${REMOTE_DEBUG_PORT:-9222}"
  OFFLINE_PAGE_URL="${OFFLINE_PAGE_URL:-file:///opt/digitalsignage/offline/index.html}"
  if [ -n "${KIOSK_USER}" ]; then
    passwd_entry="$(getent passwd "${KIOSK_USER}" 2>/dev/null || true)"
    if [ -n "${passwd_entry}" ]; then
      KIOSK_HOME="$(printf '%s' "${passwd_entry}" | cut -d: -f6)"
      STATE_FILE="${KIOSK_HOME}/.local/state/digitalsignage/connectivity.state"
      HEALTH_LOG="${KIOSK_HOME}/.local/state/digitalsignage/health.log"
    fi
  fi
}

current_kiosk_pid() {
  systemctl --user show digitalsignage-kiosk.service --property=MainPID --value 2>/dev/null || true
}

health_log_line_count() {
  [ -f "${HEALTH_LOG}" ] || { printf '0\n'; return 0; }
  wc -l < "${HEALTH_LOG}" | tr -d ' '
}

new_health_lines() {
  local start_line="$1"
  [ -f "${HEALTH_LOG}" ] || return 0
  tail -n +"$((start_line + 1))" "${HEALTH_LOG}"
}

last_health_line() {
  [ -f "${HEALTH_LOG}" ] || return 0
  tail -1 "${HEALTH_LOG}"
}

start_health_once() {
  systemctl --user start digitalsignage-health.service
  while systemctl --user is-active --quiet digitalsignage-health.service 2>/dev/null; do
    sleep 1
  done
}

get_current_url() {
  python3 - "$REMOTE_DEBUG_HOST" "$REMOTE_DEBUG_PORT" <<'PY'
import json
import sys
import urllib.request

host, port = sys.argv[1], sys.argv[2]
try:
    with urllib.request.urlopen(f"http://{host}:{port}/json", timeout=5) as response:
        targets = json.loads(response.read().decode("utf-8"))
except Exception:
    sys.exit(1)
for target in targets:
    if target.get("type") == "page" and target.get("url"):
        print(target["url"])
        sys.exit(0)
sys.exit(2)
PY
}

classify_kiosk_url() {
  local url="$1"
  python3 - "$url" "$PRESENTATION_URL" "$OFFLINE_PAGE_URL" <<'PY'
import re
import sys
import urllib.parse

url, presentation, offline = sys.argv[1], sys.argv[2], sys.argv[3]

def norm(value):
    parsed = urllib.parse.urlparse(value)
    return (parsed.scheme.lower(), parsed.netloc.lower(), parsed.path.rstrip("/"), parsed.query)

def slides_id(value):
    match = re.search(r"/presentation/d/([^/]+)", urllib.parse.urlparse(value).path)
    return match.group(1) if match else None

if url and offline and norm(url) == norm(offline):
    print("offline")
elif url and presentation and norm(url) == norm(presentation):
    print("presentation")
elif slides_id(url) and slides_id(url) == slides_id(presentation):
    print("presentation")
else:
    print("other")
PY
}

wait_for_chromium_page() {
  local expected_type="$1"
  local timeout_seconds="${2:-10}"
  local interval_seconds="${3:-1}"
  local start_time current_time current_url current_type

  start_time="$(date +%s)"
  while true; do
    current_url="$(get_current_url 2>/dev/null || true)"
    current_type="$(classify_kiosk_url "${current_url}" 2>/dev/null || printf 'other')"

    case "${expected_type}" in
      offline)
        if [ "${current_type}" = "offline" ]; then
          printf '%s\n' "${current_url}"
          return 0
        fi
        ;;
      presentation)
        if [ "${current_type}" = "presentation" ]; then
          printf '%s\n' "${current_url}"
          return 0
        fi
        ;;
      *)
        printf 'Onbekend verwacht paginatype: %s\n' "${expected_type}" >&2
        return 2
        ;;
    esac

    current_time="$(date +%s)"
    if [ $((current_time - start_time)) -ge "${timeout_seconds}" ]; then
      printf '%s\n' "${current_url}"
      return 1
    fi

    sleep "${interval_seconds}"
  done
}

restore_kiosk_url_if_needed() {
  local current classification
  current="$(get_current_url 2>/dev/null || true)"
  [ -n "${current}" ] || return 0
  classification="$(classify_kiosk_url "${current}" 2>/dev/null || printf 'other')"
  if [ "${classification}" = "offline" ]; then
    if /opt/digitalsignage/scripts/refresh-presentation.py >/dev/null 2>&1; then
      warning "Cleanup: kiosk-URL hersteld via refresh-presentation.py"
    else
      warning "Cleanup: offlinepagina was zichtbaar, maar kiosk-URL kon niet automatisch worden hersteld"
    fi
  fi
}

restore_config_from_backup() {
  [ "${CONFIG_BACKUP_CREATED}" = true ] || return 0
  if sudo cp -p "${CONFIG_BACKUP}" "${ACTIVE_CONFIG}" 2>/dev/null; then
    :
  else
    warning "Cleanup: configuratie kon niet worden hersteld uit ${CONFIG_BACKUP}"
  fi
}

restore_state_from_backup() {
  [ -n "${STATE_FILE}" ] || return 0
  if [ "${STATE_BACKUP_CREATED}" = true ]; then
    cp -p "${STATE_BACKUP}" "${STATE_FILE}" 2>/dev/null || warning "Cleanup: connectivity-state kon niet worden hersteld"
  elif [ "${LIVE_TEST_STARTED}" = true ]; then
    rm -f "${STATE_FILE}" 2>/dev/null || warning "Cleanup: tijdelijk connectivity-statebestand kon niet worden verwijderd"
  fi
}

cleanup() {
  # Veiligheidsregels: deze test schakelt geen wifi uit, verbreekt geen actieve
  # verbinding, herstart NetworkManager niet, reboot niet en stopt de kioskservice
  # niet. De live simulatie gebeurt alleen met CONNECTIVITY_CHECK_URL=.invalid.
  restore_config_from_backup
  restore_state_from_backup
  restore_kiosk_url_if_needed
  if [ "${HEALTH_TIMER_WAS_ACTIVE}" = true ]; then
    systemctl --user daemon-reload >/dev/null 2>&1 || warning "Cleanup: daemon-reload faalde"
    systemctl --user restart digitalsignage-health.timer >/dev/null 2>&1 || warning "Cleanup: healthtimer kon niet opnieuw worden gestart"
  fi
  rm -f "${TMP_PREFIX}"-* 2>/dev/null || true
}
trap cleanup EXIT

write_temp_config() {
  local original_url="$1"
  local tmp_file="${TMP_PREFIX}-digitalsignage.conf.new"
  sudo awk -F= -v invalid_url="${INVALID_TEST_URL}" '
    BEGIN {
      seen["OFFLINE_PAGE_ENABLED"]=0
      seen["OFFLINE_AFTER_SECONDS"]=0
      seen["ONLINE_CONFIRM_SECONDS"]=0
      seen["CONNECTIVITY_TIMEOUT_SECONDS"]=0
      seen["CONNECTIVITY_CHECK_URL"]=0
    }
    /^[[:space:]]*#/ || $0 !~ /=/ { print; next }
    {
      key=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key=="OFFLINE_PAGE_ENABLED") { print "OFFLINE_PAGE_ENABLED=true"; seen[key]=1; next }
      if (key=="OFFLINE_AFTER_SECONDS") { print "OFFLINE_AFTER_SECONDS=15"; seen[key]=1; next }
      if (key=="ONLINE_CONFIRM_SECONDS") { print "ONLINE_CONFIRM_SECONDS=10"; seen[key]=1; next }
      if (key=="CONNECTIVITY_TIMEOUT_SECONDS") { print "CONNECTIVITY_TIMEOUT_SECONDS=2"; seen[key]=1; next }
      if (key=="CONNECTIVITY_CHECK_URL") { print "CONNECTIVITY_CHECK_URL=\"" invalid_url "\""; seen[key]=1; next }
      print
    }
    END {
      if (!seen["OFFLINE_PAGE_ENABLED"]) print "OFFLINE_PAGE_ENABLED=true"
      if (!seen["OFFLINE_AFTER_SECONDS"]) print "OFFLINE_AFTER_SECONDS=15"
      if (!seen["ONLINE_CONFIRM_SECONDS"]) print "ONLINE_CONFIRM_SECONDS=10"
      if (!seen["CONNECTIVITY_TIMEOUT_SECONDS"]) print "CONNECTIVITY_TIMEOUT_SECONDS=2"
      if (!seen["CONNECTIVITY_CHECK_URL"]) print "CONNECTIVITY_CHECK_URL=\"" invalid_url "\""
    }
  ' "${ACTIVE_CONFIG}" > "${tmp_file}" || return 1
  sudo install -m "$(stat -c '%a' "${ACTIVE_CONFIG}")" -o "$(stat -c '%U' "${ACTIVE_CONFIG}")" -g "$(stat -c '%G' "${ACTIVE_CONFIG}")" "${tmp_file}" "${ACTIVE_CONFIG}"
  [ "$(read_config_value CONNECTIVITY_CHECK_URL "${ACTIVE_CONFIG}")" = "${original_url}" ] && return 1
  return 0
}

set_connectivity_check_url() {
  local wanted_url="$1"
  local tmp_file="${TMP_PREFIX}-connectivity-url.conf.new"
  sudo awk -F= -v wanted_url="${wanted_url}" '
    BEGIN { seen=0 }
    /^[[:space:]]*#/ || $0 !~ /=/ { print; next }
    {
      key=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key=="CONNECTIVITY_CHECK_URL") {
        print "CONNECTIVITY_CHECK_URL=\"" wanted_url "\""
        seen=1
        next
      }
      print
    }
    END {
      if (!seen) print "CONNECTIVITY_CHECK_URL=\"" wanted_url "\""
    }
  ' "${ACTIVE_CONFIG}" > "${tmp_file}" || return 1
  sudo install -m "$(stat -c '%a' "${ACTIVE_CONFIG}")" -o "$(stat -c '%U' "${ACTIVE_CONFIG}")" -g "$(stat -c '%G' "${ACTIVE_CONFIG}")" "${tmp_file}" "${ACTIVE_CONFIG}"
}

section "1. Repositorycontrole"
date
hostname
uname -a
whoami

if [ -z "${PROJECT_DIR}" ] || [ ! -d "${PROJECT_DIR}/.git" ]; then
  PROJECT_DIR=""
  for candidate in "$HOME/DigitalSignage" "$HOME/Digital_Signage" "$HOME/VS_Digital_Signage"; do
    if [ -d "${candidate}/.git" ]; then
      PROJECT_DIR="${candidate}"
      break
    fi
  done
fi

if [ -z "${PROJECT_DIR}" ]; then
  failure "Projectrepository niet gevonden."
  finish
fi

cd "${PROJECT_DIR}" || { failure "Kan projectmap niet openen: ${PROJECT_DIR}"; finish; }
ok "Projectmap gevonden: ${PROJECT_DIR}"
current_branch="$(git branch --show-current || true)"
printf 'Branch: %s\n' "${current_branch}"
git --no-pager log -5 --oneline || true
git status --short || true
[ "${current_branch}" = "${EXPECTED_BRANCH}" ] && ok "Actieve branch is ${EXPECTED_BRANCH}" || failure "Actieve branch is '${current_branch}', verwacht '${EXPECTED_BRANCH}'"
if [ -z "$(git status --short)" ]; then
  ok "Werkboom is schoon"
else
  failure "Werkboom is niet schoon; commit of stash wijzigingen voor deze test"
fi

section "2. Vereiste Fase 3-bestanden"
ESSENTIAL_MISSING=false
health_script=""
for candidate in scripts/health-check.py scripts/health-check.sh; do
  if [ -f "${candidate}" ]; then
    health_script="${candidate}"
    break
  fi
done
[ -n "${health_script}" ] && ok "Health-checkscript gevonden: ${health_script}" || { failure "Health-checkscript niet gevonden"; ESSENTIAL_MISSING=true; }

for file in \
  assets/offline/index.html \
  assets/offline/offline.css \
  config/digitalsignage.conf.example \
  tests/test-offline-behaviour.sh \
  install/install.sh \
  install/upgrade.sh \
  services/digitalsignage-health.timer
do
  assert_file_present "${file}" || ESSENTIAL_MISSING=true
done

section "3. Shellsyntaxis"
for file in install/install.sh install/upgrade.sh scripts/check-network.sh scripts/start-kiosk.sh tests/test-offline-behaviour.sh; do
  if [ -f "${file}" ]; then
    run_check "bash -n ${file}" bash -n "${file}"
  else
    failure "Shellscript ontbreekt: ${file}"
  fi
done
if [ -n "${health_script}" ]; then
  case "$(head -1 "${health_script}")" in
    *bash*) run_check "bash -n ${health_script}" bash -n "${health_script}" ;;
    *) skipped "Health-checkscript heeft geen Bash-shebang: ${health_script}" ;;
  esac
fi

section "4. Geisoleerde tests"
run_test_script tests/test-offline-behaviour.sh
run_test_script tests/pre-install-test.sh
run_test_script tests/test-installation.sh
run_test_script tests/test-upgrade-config-merge.sh
run_test_script tests/test-desktop-background.sh

section "5. Repositoryconfiguratie controleren"
REPO_CONFIG="config/digitalsignage.conf.example"
assert_single_config_value OFFLINE_PAGE_ENABLED "true" "${REPO_CONFIG}"
assert_single_config_value OFFLINE_AFTER_SECONDS "300" "${REPO_CONFIG}"
assert_single_config_value ONLINE_CONFIRM_SECONDS "30" "${REPO_CONFIG}"
assert_single_config_value CONNECTIVITY_CHECK_URL "https://clients3.google.com/generate_204" "${REPO_CONFIG}"
assert_single_config_value CONNECTIVITY_TIMEOUT_SECONDS "8" "${REPO_CONFIG}"
assert_single_config_value OFFLINE_PAGE_URL "file:///opt/digitalsignage/offline/index.html" "${REPO_CONFIG}"
is_positive_integer "$(read_config_value OFFLINE_AFTER_SECONDS "${REPO_CONFIG}")" && ok "OFFLINE_AFTER_SECONDS is positief geheel getal" || failure "OFFLINE_AFTER_SECONDS is ongeldig"
is_nonnegative_integer "$(read_config_value ONLINE_CONFIRM_SECONDS "${REPO_CONFIG}")" && ok "ONLINE_CONFIRM_SECONDS is niet-negatief geheel getal" || failure "ONLINE_CONFIRM_SECONDS is ongeldig"
is_positive_integer "$(read_config_value CONNECTIVITY_TIMEOUT_SECONDS "${REPO_CONFIG}")" && ok "CONNECTIVITY_TIMEOUT_SECONDS is positief geheel getal" || failure "CONNECTIVITY_TIMEOUT_SECONDS is ongeldig"

section "6. Offlinepagina statisch controleren"
for file in assets/offline/index.html assets/offline/offline.css; do
  assert_file_present "${file}"
  [ -s "${file}" ] && ok "${file} is niet leeg" || failure "${file} is leeg"
  [ -r "${file}" ] && ok "${file} is leesbaar" || failure "${file} is niet leesbaar"
  grep -Eiq '<\?php|<script[^>]+src=|https?://|//cdn|@import|fonts\.|cdn\.' "${file}" && failure "${file} bevat ongewenste externe of PHP-verwijzing" || ok "${file} bevat geen PHP, CDN of externe verwijzingen"
done
grep -F "Presentatie tijdelijk niet beschikbaar" assets/offline/index.html >/dev/null && ok "Offlinepagina bevat de Nederlandse hoofdboodschap" || failure "Offlinepagina mist de Nederlandse hoofdboodschap"
grep -F 'href="offline.css"' assets/offline/index.html >/dev/null && ok "Offlinepagina gebruikt lokale CSS" || failure "Offlinepagina verwijst niet naar lokale CSS"

section "7. Upgrade uitvoeren"
systemctl --user is-active digitalsignage-kiosk.service >/dev/null 2>&1 && ok "Kioskservice is actief voor upgrade" || warning "Kioskservice is niet actief voor upgrade"
if systemctl --user is-active --quiet digitalsignage-health.timer; then
  HEALTH_TIMER_WAS_ACTIVE=true
  ok "Healthtimer is actief voor upgrade"
else
  warning "Healthtimer is niet actief voor upgrade"
fi
if sudo bash install/upgrade.sh; then
  ok "Upgrade is geslaagd"
else
  failure "Upgrade is mislukt"
  ESSENTIAL_MISSING=true
fi

refresh_config_values

section "8. Geinstalleerde offlinepagina"
for pair in "assets/offline/index.html:/opt/digitalsignage/offline/index.html" "assets/offline/offline.css:/opt/digitalsignage/offline/offline.css"; do
  repo_file="${pair%%:*}"
  installed_file="${pair#*:}"
  assert_file_present "${installed_file}"
  [ -s "${installed_file}" ] && ok "${installed_file} is niet leeg" || failure "${installed_file} is leeg"
  [ -f "${installed_file}" ] && ok "${installed_file} is een gewoon bestand" || failure "${installed_file} is geen gewoon bestand"
  sudo -u "${KIOSK_USER:-$USER}" test -r "${installed_file}" && ok "${installed_file} is leesbaar voor kioskgebruiker" || failure "${installed_file} is niet leesbaar voor kioskgebruiker"
  stat -c '%a %U %G %n' "${installed_file}" || true
  [ "$(stat -c '%a' "${installed_file}")" = "644" ] && ok "${installed_file} heeft modus 0644" || warning "${installed_file} heeft geen modus 0644"
  [ "$(stat -c '%a' "$(dirname "${installed_file}")")" = "755" ] && ok "$(dirname "${installed_file}") heeft modus 0755" || warning "$(dirname "${installed_file}") heeft geen modus 0755"
  file "${installed_file}" || true
  if [ "$(sha256sum "${repo_file}" | awk '{ print $1 }')" = "$(sha256sum "${installed_file}" | awk '{ print $1 }')" ]; then
    ok "Checksum komt overeen: ${installed_file}"
  else
    failure "Checksum verschilt: ${installed_file}"
  fi
done
[ "${OFFLINE_PAGE_URL}" = "file:///opt/digitalsignage/offline/index.html" ] && ok "OFFLINE_PAGE_URL verwijst naar geinstalleerde offlinepagina" || warning "OFFLINE_PAGE_URL is aangepast: ${OFFLINE_PAGE_URL}"

section "9. Actieve configuratie"
assert_file_present "${ACTIVE_CONFIG}"
for key in OFFLINE_PAGE_ENABLED OFFLINE_AFTER_SECONDS ONLINE_CONFIRM_SECONDS CONNECTIVITY_CHECK_URL CONNECTIVITY_TIMEOUT_SECONDS OFFLINE_PAGE_URL; do
  count="$(active_key_count "${key}" "${ACTIVE_CONFIG}")"
  value="$(read_config_value "${key}" "${ACTIVE_CONFIG}")"
  printf '%s=%s\n' "${key}" "${value}"
  [ "${count}" = "1" ] && ok "${key} staat exact eenmaal actief" || failure "${key} staat ${count} keer actief"
  [ -n "${value}" ] && ok "${key} heeft een actieve waarde" || failure "${key} heeft geen actieve waarde"
done
is_boolean "$(read_config_value OFFLINE_PAGE_ENABLED "${ACTIVE_CONFIG}")" && ok "OFFLINE_PAGE_ENABLED is geldig boolean" || failure "OFFLINE_PAGE_ENABLED is ongeldig"
is_positive_integer "$(read_config_value OFFLINE_AFTER_SECONDS "${ACTIVE_CONFIG}")" && ok "OFFLINE_AFTER_SECONDS is positief geheel getal" || failure "OFFLINE_AFTER_SECONDS is ongeldig"
is_nonnegative_integer "$(read_config_value ONLINE_CONFIRM_SECONDS "${ACTIVE_CONFIG}")" && ok "ONLINE_CONFIRM_SECONDS is niet-negatief geheel getal" || failure "ONLINE_CONFIRM_SECONDS is ongeldig"
is_positive_integer "$(read_config_value CONNECTIVITY_TIMEOUT_SECONDS "${ACTIVE_CONFIG}")" && ok "CONNECTIVITY_TIMEOUT_SECONDS is positief geheel getal" || failure "CONNECTIVITY_TIMEOUT_SECONDS is ongeldig"
case "$(read_config_value OFFLINE_PAGE_URL "${ACTIVE_CONFIG}")" in
  file://*) ok "OFFLINE_PAGE_URL gebruikt file:// voor lokale offlinepagina" ;;
  *) warning "OFFLINE_PAGE_URL gebruikt geen file://: $(read_config_value OFFLINE_PAGE_URL "${ACTIVE_CONFIG}")" ;;
esac

section "10. Post-installatiecontrole na upgrade"
systemctl --user daemon-reload && ok "systemd user-daemon opnieuw geladen" || { failure "systemd user-daemon kon niet opnieuw laden"; LIVE_TEST_ALLOWED=false; }
systemctl --user is-active --quiet digitalsignage-kiosk.service && ok "Kioskservice is actief voor post-installatiecontrole" || { failure "Kioskservice is niet actief voor post-installatiecontrole"; LIVE_TEST_ALLOWED=false; }
systemctl --user is-active --quiet digitalsignage-health.timer && ok "Healthtimer is actief voor post-installatiecontrole" || { failure "Healthtimer is niet actief voor post-installatiecontrole"; LIVE_TEST_ALLOWED=false; }
if [ -f tests/post-install-test.sh ]; then
  if bash tests/post-install-test.sh; then
    ok "Post-installatiecontrole na upgrade geslaagd"
  else
    failure "Post-installatiecontrole na upgrade gefaald; live simulatie wordt niet gestart"
    LIVE_TEST_ALLOWED=false
  fi
else
  failure "tests/post-install-test.sh ontbreekt"
  LIVE_TEST_ALLOWED=false
fi

section "11. Healthtimer-regressie"
health_seconds="$(read_config_value HEALTH_CHECK_SECONDS "${ACTIVE_CONFIG}")"
health_seconds="${health_seconds:-60}"
systemctl --user cat digitalsignage-health.timer || failure "Kan healthtimer-unit niet tonen"
systemctl --user show digitalsignage-health.timer --property=TimersMonotonic --property=ActiveState --property=SubState --property=NextElapseUSecMonotonic --property=LastTriggerUSec || failure "Kan healthtimer-eigenschappen niet tonen"
timer_show="$(systemctl --user show digitalsignage-health.timer --property=TimersMonotonic --property=ActiveState --property=SubState --property=NextElapseUSecMonotonic --property=LastTriggerUSec 2>/dev/null || true)"
printf '%s\n' "${timer_show}" | grep -F 'OnActiveUSec=2min' >/dev/null && ok "Healthtimer bevat OnActiveUSec=2min" || failure "Healthtimer mist OnActiveUSec=2min"
if [ "${health_seconds}" = "60" ]; then
  printf '%s\n' "${timer_show}" | grep -E 'OnUnitInactiveUSec=(60s|1min)' >/dev/null && ok "Healthtimer gebruikt HEALTH_CHECK_SECONDS=60" || failure "Healthtimer mist OnUnitInactiveUSec=1min"
else
  printf '%s\n' "${timer_show}" | grep -F "OnUnitInactiveUSec=${health_seconds}s" >/dev/null && ok "Healthtimer gebruikt HEALTH_CHECK_SECONDS=${health_seconds}" || failure "Healthtimer mist OnUnitInactiveUSec=${health_seconds}s"
fi
printf '%s\n' "${timer_show}" | grep -F 'ActiveState=active' >/dev/null && ok "Healthtimer ActiveState=active" || failure "Healthtimer is niet active"
printf '%s\n' "${timer_show}" | grep -F 'SubState=waiting' >/dev/null && ok "Healthtimer SubState=waiting" || failure "Healthtimer is niet waiting"
printf '%s\n' "${timer_show}" | grep -E '^NextElapseUSecMonotonic=.+$' >/dev/null && ok "Healthtimer heeft een volgende monotone trigger gepland" || failure "Healthtimer heeft geen volgende monotone trigger gepland"
systemctl --user list-timers --all | tee "${TEST_OUTPUT}" || true
awk '/digitalsignage-health.timer/ { found=1; if ($1 != "-" && $1 != "n/a") ok=1 } END { exit(found && ok ? 0 : 1) }' "${TEST_OUTPUT}" && ok "Healthtimer heeft een toekomstige trigger" || failure "Healthtimer heeft geen duidelijke toekomstige trigger"

section "12. Normale online-healthcheck"
refresh_config_values
if [ -z "${KIOSK_USER}" ] || [ -z "${KIOSK_HOME}" ]; then
  failure "Kioskgebruiker of homefolder kon niet worden bepaald"
  LIVE_TEST_ALLOWED=false
fi
info "KIOSK_USER=${KIOSK_USER:-onbekend}"
info "KIOSK_HOME=${KIOSK_HOME:-onbekend}"
info "HEALTH_LOG=${HEALTH_LOG:-onbekend}"
info "STATE_FILE=${STATE_FILE:-onbekend}"
info "PRESENTATION_URL=${PRESENTATION_URL:-onbekend}"
info "OFFLINE_PAGE_URL=${OFFLINE_PAGE_URL:-onbekend}"
info "REMOTE_DEBUG=${REMOTE_DEBUG_HOST}:${REMOTE_DEBUG_PORT}"
online_log_start="$(health_log_line_count)"
if start_health_once; then
  ok "Healthservice start gecontroleerd"
else
  failure "Healthservice start faalt"
  LIVE_TEST_ALLOWED=false
fi
last_line="$(last_health_line)"
printf '%s\n' "${last_line}"
if printf '%s\n' "${last_line}" | grep -F 'network=online' >/dev/null && printf '%s\n' "${last_line}" | grep -F 'nm=full' >/dev/null && printf '%s\n' "${last_line}" | grep -F 'http=ok' >/dev/null; then
  ok "Basistoestand is online"
else
  if [ "${TEST_MODE}" = "safe-only" ]; then
    warning "Basistoestand is niet online; live herstelproef wordt in safe-only niet uitgevoerd"
  else
    failure "De basistoestand is niet online; automatisch herstel kan niet betrouwbaar worden getest."
  fi
  LIVE_TEST_ALLOWED=false
fi
printf '%s\n' "${last_line}" | grep -F 'action=' >/dev/null && ok "Healthlog bevat action-veld" || failure "Healthlog mist action-veld"
printf '%s\n' "${last_line}" | grep -F 'reason=' >/dev/null && ok "Healthlog bevat reason-veld" || failure "Healthlog mist reason-veld"

section "13. Chromium-URL uitlezen"
ORIGINAL_KIOSK_PID="$(current_kiosk_pid)"
ORIGINAL_URL="$(get_current_url 2>/dev/null || true)"
printf 'MainPID=%s\n' "${ORIGINAL_KIOSK_PID}"
printf 'Huidige URL=%s\n' "${ORIGINAL_URL}"
if [ -n "${ORIGINAL_URL}" ]; then
  ok "Chromium-debugpoort geeft huidige URL terug"
else
  failure "Chromium-debugpoort geeft geen huidige URL terug"
  LIVE_TEST_ALLOWED=false
fi
if [ "$(classify_kiosk_url "${ORIGINAL_URL}")" = "offline" ]; then
  failure "Chromium staat al op de offlinepagina voor de live proef"
  LIVE_TEST_ALLOWED=false
else
  ok "Chromium staat voor de live proef niet op de offlinepagina"
fi
systemctl --user is-active --quiet digitalsignage-kiosk.service && ok "Kioskservice is actief voor live proef" || { failure "Kioskservice is niet actief voor live proef"; LIVE_TEST_ALLOWED=false; }

if [ "${TEST_MODE}" = "safe-only" ]; then
  section "14. Veilige offline- en herstelproef"
  skipped "--safe-only: live simulatie met .invalid-URL overgeslagen"
elif [ "${LIVE_TEST_ALLOWED}" != true ] || [ "${ESSENTIAL_MISSING}" = true ]; then
  section "14. Veilige offline- en herstelproef"
  skipped "Live proef overgeslagen omdat essentiële voorwaarden ontbreken"
else
  section "14. Veilige offline- en herstelproef"
  LIVE_TEST_STARTED=true
  ORIGINAL_CONFIG_SUM="$(sha256sum "${ACTIVE_CONFIG}" | awk '{ print $1 }')"
  if sudo cp -p "${ACTIVE_CONFIG}" "${CONFIG_BACKUP}"; then
    CONFIG_BACKUP_CREATED=true
    ok "Actieve configuratie geback-upt"
  else
    failure "Actieve configuratie kon niet worden geback-upt"
  fi
  if [ -f "${STATE_FILE}" ]; then
    cp -p "${STATE_FILE}" "${STATE_BACKUP}" && STATE_BACKUP_CREATED=true && ORIGINAL_STATE_EXISTS=true && ok "Connectivity-state geback-upt"
  else
    ok "Geen bestaand connectivity-statebestand; test gebruikt schone state"
  fi
  original_check_url="$(read_config_value CONNECTIVITY_CHECK_URL "${ACTIVE_CONFIG}")"
  systemctl --user stop digitalsignage-health.timer && ok "Healthtimer tijdelijk gestopt voor handmatige healthchecks" || warning "Healthtimer kon niet tijdelijk worden gestopt"
  write_temp_config "${original_check_url}" && ok "Tijdelijke .invalid-configuratie atomisch geplaatst" || failure "Tijdelijke .invalid-configuratie kon niet worden geplaatst"
  for key in OFFLINE_PAGE_ENABLED OFFLINE_AFTER_SECONDS ONLINE_CONFIRM_SECONDS CONNECTIVITY_TIMEOUT_SECONDS CONNECTIVITY_CHECK_URL; do
    [ "$(active_key_count "${key}" "${ACTIVE_CONFIG}")" = "1" ] && ok "Tijdelijke ${key} staat exact eenmaal actief" || failure "Tijdelijke ${key} staat niet exact eenmaal actief"
  done
  rm -f "${STATE_FILE}" 2>/dev/null || true
  refresh_config_values
  live_log_start="$(health_log_line_count)"

  start_health_once && ok "Eerste offlinecontrole crasht niet" || failure "Eerste offlinecontrole faalt"
  first_line="$(last_health_line)"
  printf '%s\n' "${first_line}"
  printf '%s\n' "${first_line}" | grep -F 'nm=full' >/dev/null && ok "NetworkManager blijft full tijdens simulatie" || warning "NetworkManager meldt niet full tijdens simulatie"
  printf '%s\n' "${first_line}" | grep -E 'http=(failed|timeout)' >/dev/null && ok "HTTP-controle faalt door .invalid-URL" || failure "HTTP-controle faalt niet zoals verwacht"
  printf '%s\n' "${first_line}" | grep -F 'network=offline' >/dev/null && ok "Status wordt offline" || failure "Status wordt niet offline"
  grep -E '^OFFLINE_SINCE=[1-9][0-9]*$' "${STATE_FILE}" >/dev/null && ok "OFFLINE_SINCE is gezet" || failure "OFFLINE_SINCE is niet gezet"
  current_after_first="$(get_current_url 2>/dev/null || true)"
  [ "$(classify_kiosk_url "${current_after_first}")" != "offline" ] && ok "Korte onderbreking houdt presentatie zichtbaar" || failure "Offlinepagina verscheen te vroeg"
  SHORT_INTERRUPTION_PROVEN=true
  [ "$(current_kiosk_pid)" = "${ORIGINAL_KIOSK_PID}" ] && ok "Kiosk-PID bleef gelijk na eerste offlinecontrole" || failure "Kiosk-PID wijzigde na eerste offlinecontrole"

  info "Wacht 17 seconden: dit is bewust iets langer dan OFFLINE_AFTER_SECONDS=15."
  sleep 17
  start_health_once && ok "Tweede offlinecontrole crasht niet" || failure "Tweede offlinecontrole faalt"
  second_line="$(last_health_line)"
  printf '%s\n' "${second_line}"
  printf '%s\n' "${second_line}" | grep -F 'action=show_offline_page' >/dev/null && ok "Log bevat show_offline_page" || warning "Log bevat geen show_offline_page"
  printf '%s\n' "${second_line}" | grep -F 'reason=offline_threshold_reached' >/dev/null && ok "Log bevat offline_threshold_reached" || warning "Log bevat geen offline_threshold_reached"
  info "Wacht maximaal 10 seconden tot Chromium de offlinepagina toont."
  if current_after_threshold="$(wait_for_chromium_page offline 10 1)"; then
    ok "Offlinepagina is zichtbaar na navigatie"
  else
    failure "Offlinepagina werd niet zichtbaar binnen 10 seconden"
    info "Laatste Chromium-URL: ${current_after_threshold}"
  fi
  grep -F 'OFFLINE_PAGE_SHOWN=true' "${STATE_FILE}" >/dev/null && ok "State bevat OFFLINE_PAGE_SHOWN=true" || failure "State bevat geen OFFLINE_PAGE_SHOWN=true"
  [ "$(current_kiosk_pid)" = "${ORIGINAL_KIOSK_PID}" ] && ok "Kiosk-PID bleef gelijk bij offlinepagina" || failure "Kiosk-PID wijzigde bij offlinepagina"
  LONG_INTERRUPTION_PROVEN=true

  start_health_once && ok "Derde offlinecontrole crasht niet" || failure "Derde offlinecontrole faalt"
  third_line="$(last_health_line)"
  printf '%s\n' "${third_line}"
  [ "$(classify_kiosk_url "$(get_current_url 2>/dev/null || true)")" = "offline" ] && ok "Offlinepagina blijft zichtbaar zonder herladen" || failure "Offlinepagina bleef niet zichtbaar"
  printf '%s\n' "${third_line}" | grep -E 'offline_page_already_visible|action=none' >/dev/null && ok "Log meldt geen herhaalde navigatie" || warning "Geen duidelijke log voor niet-herladen"
  [ "$(current_kiosk_pid)" = "${ORIGINAL_KIOSK_PID}" ] && ok "Kiosk-PID bleef gelijk bij herhaalde offlinecheck" || failure "Kiosk-PID wijzigde bij herhaalde offlinecheck"

  set_connectivity_check_url "${original_check_url}" && ok "Alleen CONNECTIVITY_CHECK_URL hersteld; korte wachttijden blijven actief" || failure "CONNECTIVITY_CHECK_URL kon niet apart worden hersteld"
  refresh_config_values
  start_health_once && ok "Eerste herstelcontrole crasht niet" || failure "Eerste herstelcontrole faalt"
  recovery_wait_line="$(last_health_line)"
  printf '%s\n' "${recovery_wait_line}"
  printf '%s\n' "${recovery_wait_line}" | grep -F 'network=online' >/dev/null && ok "Netwerk wordt opnieuw online gedetecteerd" || failure "Netwerk wordt niet online gedetecteerd"
  [ "$(classify_kiosk_url "$(get_current_url 2>/dev/null || true)")" = "offline" ] && ok "Offlinepagina blijft zichtbaar tijdens bevestigingstijd" || failure "Offlinepagina bleef niet zichtbaar tijdens bevestigingstijd"
  grep -E '^ONLINE_SINCE=[1-9][0-9]*$' "${STATE_FILE}" >/dev/null && ok "ONLINE_SINCE is gezet" || failure "ONLINE_SINCE is niet gezet"
  printf '%s\n' "${recovery_wait_line}" | grep -F 'wait_online_confirmation' >/dev/null && ok "Log bevat wait_online_confirmation" || warning "Log bevat geen wait_online_confirmation"
  [ "$(current_kiosk_pid)" = "${ORIGINAL_KIOSK_PID}" ] && ok "Kiosk-PID bleef gelijk tijdens herstelwachttijd" || failure "Kiosk-PID wijzigde tijdens herstelwachttijd"

  info "Wacht 12 seconden: dit is bewust iets langer dan ONLINE_CONFIRM_SECONDS=10."
  sleep 12
  start_health_once && ok "Tweede herstelcontrole crasht niet" || failure "Tweede herstelcontrole faalt"
  recovery_line="$(last_health_line)"
  printf '%s\n' "${recovery_line}"
  printf '%s\n' "${recovery_line}" | grep -F 'show_kiosk_page' >/dev/null && ok "Log bevat show_kiosk_page" || warning "Log bevat geen show_kiosk_page"
  printf '%s\n' "${recovery_line}" | grep -F 'connectivity_restored' >/dev/null && ok "Log bevat connectivity_restored" || warning "Log bevat geen connectivity_restored"
  info "Wacht maximaal 10 seconden tot Chromium terugkeert naar de presentatie."
  if final_url="$(wait_for_chromium_page presentation 10 1)"; then
    ok "Kioskpagina keerde terug na stabiel herstel"
  else
    failure "Kioskpagina keerde niet terug binnen 10 seconden"
    info "Laatste Chromium-URL: ${final_url}"
  fi
  grep -F 'OFFLINE_PAGE_SHOWN=false' "${STATE_FILE}" >/dev/null && ok "OFFLINE_PAGE_SHOWN=false na herstel" || failure "OFFLINE_PAGE_SHOWN is niet false na herstel"
  grep -F 'OFFLINE_SINCE=0' "${STATE_FILE}" >/dev/null && ok "OFFLINE_SINCE=0 na herstel" || failure "OFFLINE_SINCE is niet 0 na herstel"
  grep -F 'ONLINE_SINCE=0' "${STATE_FILE}" >/dev/null && ok "ONLINE_SINCE=0 na herstel" || failure "ONLINE_SINCE is niet 0 na herstel"
  [ "$(current_kiosk_pid)" = "${ORIGINAL_KIOSK_PID}" ] && { ok "Kiosk-PID bleef gelijk tijdens volledige netwerkproef"; NO_RESTART_PROVEN=true; } || failure "Kiosk-PID wijzigde tijdens netwerkproef"
  RECOVERY_PROVEN=true

  restore_state_from_backup
  restore_config_from_backup
  restore_kiosk_url_if_needed
  systemctl --user daemon-reload && systemctl --user restart digitalsignage-health.timer && ok "Healthtimer na live proef herstart" || failure "Healthtimer na live proef niet herstart"
  timer_after_restore="$(systemctl --user show digitalsignage-health.timer --property=ActiveState --property=SubState 2>/dev/null || true)"
  printf '%s\n' "${timer_after_restore}" | grep -F 'ActiveState=active' >/dev/null && printf '%s\n' "${timer_after_restore}" | grep -F 'SubState=waiting' >/dev/null && ok "Healthtimer is opnieuw active/waiting" || failure "Healthtimer is niet active/waiting na herstel"
  if [ "$(sha256sum "${ACTIVE_CONFIG}" | awk '{ print $1 }')" = "${ORIGINAL_CONFIG_SUM}" ]; then
    ok "Configuratiechecksum is hersteld"
    CONFIG_RESTORED_PROVEN=true
  else
    failure "Configuratiechecksum verschilt na herstel"
  fi
  grep -F "${INVALID_TEST_URL}" "${ACTIVE_CONFIG}" >/dev/null && failure ".invalid-URL staat nog in actieve configuratie" || ok ".invalid-URL is verwijderd uit actieve configuratie"
  start_health_once && ok "Normale online healthcheck na herstel uitgevoerd" || warning "Normale online healthcheck na herstel faalde"

  section "15. Nieuwe healthlogregels van live proef"
  new_health_lines "${live_log_start}" | tail -20
  new_lines="$(new_health_lines "${live_log_start}")"
  printf '%s\n' "${new_lines}" | grep -F 'network=online' >/dev/null && ok "Nieuwe logs bevatten normale onlinecontrole" || warning "Nieuwe logs bevatten geen normale onlinecontrole"
  printf '%s\n' "${new_lines}" | grep -F 'offline_grace_period' >/dev/null && ok "Nieuwe logs bevatten offline grace period" || warning "Nieuwe logs bevatten geen offline grace period"
  printf '%s\n' "${new_lines}" | grep -F 'show_offline_page' >/dev/null && ok "Nieuwe logs bevatten offlinepagina tonen" || warning "Nieuwe logs bevatten geen offlinepagina tonen"
  printf '%s\n' "${new_lines}" | grep -E 'offline_page_already_visible|action=none' >/dev/null && ok "Nieuwe logs bevatten geen herhaalde offline-navigatie" || warning "Nieuwe logs bevatten geen bewijs voor niet-herladen"
  printf '%s\n' "${new_lines}" | grep -F 'wait_online_confirmation' >/dev/null && ok "Nieuwe logs bevatten online bevestiging" || warning "Nieuwe logs bevatten geen online bevestiging"
  printf '%s\n' "${new_lines}" | grep -F 'show_kiosk_page' >/dev/null && ok "Nieuwe logs bevatten terugkeer naar kioskpagina" || warning "Nieuwe logs bevatten geen terugkeer naar kioskpagina"
fi

section "16. Tweede upgrade en idempotentie"
OFFLINE_CHECKSUM_BEFORE="$(sha256sum /opt/digitalsignage/offline/index.html 2>/dev/null | awk '{ print $1 }')"
OFFLINE_CSS_CHECKSUM_BEFORE="$(sha256sum /opt/digitalsignage/offline/offline.css 2>/dev/null | awk '{ print $1 }')"
if sudo bash install/upgrade.sh; then
  ok "Tweede upgrade is geslaagd"
else
  failure "Tweede upgrade is mislukt"
fi
for key in OFFLINE_PAGE_ENABLED OFFLINE_AFTER_SECONDS ONLINE_CONFIRM_SECONDS CONNECTIVITY_CHECK_URL CONNECTIVITY_TIMEOUT_SECONDS OFFLINE_PAGE_URL; do
  [ "$(active_key_count "${key}" "${ACTIVE_CONFIG}")" = "1" ] && ok "Na tweede upgrade staat ${key} exact eenmaal actief" || failure "Na tweede upgrade staat ${key} niet exact eenmaal actief"
done
[ "${OFFLINE_CHECKSUM_BEFORE}" = "$(sha256sum /opt/digitalsignage/offline/index.html 2>/dev/null | awk '{ print $1 }')" ] && ok "Offline HTML blijft gelijk na tweede upgrade" || failure "Offline HTML wijzigde na tweede upgrade"
[ "${OFFLINE_CSS_CHECKSUM_BEFORE}" = "$(sha256sum /opt/digitalsignage/offline/offline.css 2>/dev/null | awk '{ print $1 }')" ] && ok "Offline CSS blijft gelijk na tweede upgrade" || failure "Offline CSS wijzigde na tweede upgrade"
systemctl --user is-active --quiet digitalsignage-kiosk.service && ok "Kioskservice blijft actief na tweede upgrade" || failure "Kioskservice is niet actief na tweede upgrade"
systemctl --user is-active --quiet digitalsignage-health.timer && ok "Healthtimer blijft actief na tweede upgrade" || failure "Healthtimer is niet actief na tweede upgrade"

section "17. Healthlogcontrole"
if [ -f "${HEALTH_LOG}" ]; then
  tail -20 "${HEALTH_LOG}"
else
  warning "Healthlog ontbreekt: ${HEALTH_LOG}"
fi

finish
'@

# Het .bat-bestand zelf gebruikt CRLF, maar het tijdelijke Linux-script moet
# zonder BOM en met LF-only regelafbrekingen worden opgeslagen voor Bash.
$linuxScript = $linuxScript -replace "`r`n", "`n"
$linuxScript = $linuxScript -replace "`r", "`n"
[System.IO.File]::WriteAllText($localScript, $linuxScript, [System.Text.UTF8Encoding]::new($false))

$copyDone = $false
try {
    Write-Host ""
    Write-Host "[2/4] Tijdelijk Fase 3-testscript naar Raspberry Pi kopieren..."
    $copyResult = Invoke-NativeCommand { & scp $localScript "$sshTarget`:$remoteScript" }
    if ($copyResult -ne 0) {
        Fail "Het tijdelijke testscript kon niet worden gekopieerd."
    }
    $copyDone = $true

    Write-Host ""
    Write-Host "[3/4] Fase 3-test uitvoeren..."
    Write-Host "Mogelijk wordt je Raspberry Pi-wachtwoord gevraagd."
    Write-Host "Bij sudo kan het wachtwoord opnieuw gevraagd worden."
    Write-Host ""
    Write-Host "De uitvoer wordt ook opgeslagen in:"
    Write-Host $logFile
    Write-Host ""

    $remoteCommand = "TERM=dumb NO_COLOR=1 SYSTEMD_COLORS=0 SYSTEMD_PAGER=cat GIT_PAGER=cat DIGITALSIGNAGE_PROJECT_DIR='$PiProjectDir' PI_EXPECTED_BRANCH='$PiExpectedBranch' PHASE3_TEST_MODE='$Phase3TestMode' bash -lc 'chmod +x $remoteScript && bash $remoteScript'"
    $testResult = Invoke-NativeCommand { & ssh -q -t $sshTarget $remoteCommand *> $logFile }

    Get-Content -LiteralPath $logFile
}
finally {
    Write-Host ""
    Write-Host "[4/4] Tijdelijke testbestanden opruimen..."
    if ($copyDone) {
        $null = Invoke-NativeCommand { & ssh $sshTarget "rm -f $remoteScript /tmp/digitalsignage-fase3-* 2>/dev/null || true" *> $null }
    }
    Remove-Item -LiteralPath $localScript -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "============================================================"
if ($testResult -eq 0) {
    Write-Host "[KLAAR] FASE 3 TEST: GESLAAGD"
} else {
    Write-Host "[WAARSCHUWING] FASE 3 TEST: NIET GESLAAGD"
}
Write-Host ""
Write-Host "Logbestand:"
Write-Host $logFile
Write-Host "============================================================"
Write-Host ""

exit $testResult
