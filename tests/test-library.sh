#!/usr/bin/env bash
set -u
set -o pipefail

# Gedeelde hulpfuncties voor de Digital Signage-tests.
# Deze bibliotheek voert zelf geen destructieve acties uit.

TEST_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_LOG_DIR="${TEST_ROOT_DIR}/test-logs"
TEST_CONTEXT_NAME="${TEST_CONTEXT_NAME:-test}"
TEST_OK_COUNT=0
TEST_WARNING_COUNT=0
TEST_ERROR_COUNT=0
TEST_SKIPPED_COUNT=0

COLOR_OK=""
COLOR_WARNING=""
COLOR_ERROR=""
COLOR_SKIPPED=""
COLOR_RESET=""

init_test_context() {
  TEST_CONTEXT_NAME="$1"
  if [ -e "${TEST_LOG_DIR}" ] && [ ! -d "${TEST_LOG_DIR}" ]; then
    printf '[FOUT] test-logs bestaat, maar is geen map: %s\n' "${TEST_LOG_DIR}" >&2
    exit 1
  fi
  mkdir -p "${TEST_LOG_DIR}"
  if [ ! -w "${TEST_LOG_DIR}" ]; then
    printf '[FOUT] test-logs is niet schrijfbaar: %s\n' "${TEST_LOG_DIR}" >&2
    printf '[INFO] Herstel op Linux met: sudo chown -R "$USER":"$(id -gn)" test-logs\n' >&2
    exit 1
  fi
  local timestamp
  timestamp="$(date '+%Y-%m-%d_%H%M%S')"
  TEST_LOG_FILE="${TEST_LOG_DIR}/${TEST_CONTEXT_NAME}-${timestamp}.log"

  # Alle uitvoer loopt via tee, zodat terminal en logbestand dezelfde tekst tonen.
  # Kleuren blijven uit zodra stdout geen terminal is; zo blijven logs leesbaar.
  if [ -t 1 ] && [ -z "${TEST_LOGGING_STARTED:-}" ]; then
    COLOR_OK="$(printf '\033[32m')"
    COLOR_WARNING="$(printf '\033[33m')"
    COLOR_ERROR="$(printf '\033[31m')"
    COLOR_SKIPPED="$(printf '\033[36m')"
    COLOR_RESET="$(printf '\033[0m')"
  fi

  exec > >(tee -a "${TEST_LOG_FILE}") 2>&1
  TEST_LOGGING_STARTED=1
  COLOR_OK=""
  COLOR_WARNING=""
  COLOR_ERROR=""
  COLOR_SKIPPED=""
  COLOR_RESET=""

  log_info "Logbestand: ${TEST_LOG_FILE}"
}

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_ok() {
  TEST_OK_COUNT=$((TEST_OK_COUNT + 1))
  printf '%s[OK]%s %s\n' "${COLOR_OK}" "${COLOR_RESET}" "$*"
}

log_warning() {
  TEST_WARNING_COUNT=$((TEST_WARNING_COUNT + 1))
  printf '%s[WAARSCHUWING]%s %s\n' "${COLOR_WARNING}" "${COLOR_RESET}" "$*"
}

log_error() {
  TEST_ERROR_COUNT=$((TEST_ERROR_COUNT + 1))
  printf '%s[FOUT]%s %s\n' "${COLOR_ERROR}" "${COLOR_RESET}" "$*"
}

log_skipped() {
  TEST_SKIPPED_COUNT=$((TEST_SKIPPED_COUNT + 1))
  printf '%s[OVERGESLAGEN]%s %s\n' "${COLOR_SKIPPED}" "${COLOR_RESET}" "$*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_test() {
  local name="$1"
  local function_name="$2"

  log_info "Test: ${name}"
  if "${function_name}"; then
    log_ok "${name}"
  else
    log_error "${name}"
  fi
}

print_summary() {
  printf '\nSamenvatting %s\n' "${TEST_CONTEXT_NAME}"
  printf 'OK: %s\n' "${TEST_OK_COUNT}"
  printf 'WAARSCHUWING: %s\n' "${TEST_WARNING_COUNT}"
  printf 'FOUT: %s\n' "${TEST_ERROR_COUNT}"
  printf 'OVERGESLAGEN: %s\n' "${TEST_SKIPPED_COUNT}"
  printf 'Logbestand: %s\n' "${TEST_LOG_FILE:-niet-aangemaakt}"

  if [ "${TEST_ERROR_COUNT}" -gt 0 ]; then
    return 1
  fi
  return 0
}

read_config_value() {
  local key="$1"
  local file="$2"
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
