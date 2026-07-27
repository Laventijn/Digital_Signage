#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

run_merge() {
  DIGITALSIGNAGE_TEST_CONFIG_MERGE=1 bash "${ROOT_DIR}/install/upgrade.sh" "$1" >/dev/null
}

count_active_key() {
  local key="$1"
  local file="$2"
  awk -F= -v key="${key}" '
    /^[[:space:]]*#/ { next }
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" { count++ }
    END { print count + 0 }
  ' "${file}"
}

assert_contains() {
  local pattern="$1"
  local file="$2"
  grep -q -- "${pattern}" "${file}" || {
    echo "Ontbrekend patroon '${pattern}' in ${file}" >&2
    exit 1
  }
}

missing_config="${TEMP_DIR}/missing.conf"
cat > "${missing_config}" <<'EOF'
SWAP_LOG_MAX_BYTES=5242880
EOF
chmod 0640 "${missing_config}"
run_merge "${missing_config}"
assert_contains '^REFRESH_SECONDS=300$' "${missing_config}"
assert_contains '^CONTENT_MODE="presentation"$' "${missing_config}"
assert_contains '^CONTENT_URL=""$' "${missing_config}"
assert_contains '^SCREENSHOT_CACHE_ENABLED=true$' "${missing_config}"
assert_contains '^SCREENSHOT_CACHE_REFRESH_SECONDS=900$' "${missing_config}"
assert_contains '^SCREENSHOT_CAPTURE_DEBUG_PORT=9333$' "${missing_config}"
assert_contains '^OFFLINE_WATERMARK_TEXT="Offline modus"$' "${missing_config}"
assert_contains '^WEBSITE_OFFLINE_CAPTURE_MODE="latest"$' "${missing_config}"
assert_contains '^RESOURCE_LOG_RETENTION_DAYS=3$' "${missing_config}"
assert_contains '^HEALTH_CHECK_SECONDS=15$' "${missing_config}"
assert_contains '^HEALTH_FAILURE_THRESHOLD=3$' "${missing_config}"
assert_contains '^HEALTH_RESTART_COOLDOWN_SECONDS=600$' "${missing_config}"
assert_contains '^HEALTH_HTTP_TIMEOUT_SECONDS=5$' "${missing_config}"
assert_contains '^HEALTH_STARTUP_GRACE_SECONDS=90$' "${missing_config}"
assert_contains '^HEALTH_LOG_RETENTION_DAYS=3$' "${missing_config}"
assert_contains '^HEALTH_LOG_MAX_BYTES=5242880$' "${missing_config}"
assert_contains '^OFFLINE_PAGE_ENABLED=true$' "${missing_config}"
assert_contains '^OFFLINE_AFTER_SECONDS=45$' "${missing_config}"
assert_contains '^ONLINE_CONFIRM_SECONDS=30$' "${missing_config}"
assert_contains '^CONNECTIVITY_CHECK_URL="https://clients3.google.com/generate_204"$' "${missing_config}"
assert_contains '^CONNECTIVITY_TIMEOUT_SECONDS=5$' "${missing_config}"
assert_contains '^OFFLINE_PAGE_URL="file:///opt/digitalsignage/offline/index.html"$' "${missing_config}"
assert_contains '^DESKTOP_BACKGROUND_ENABLED=true$' "${missing_config}"
assert_contains '^DESKTOP_BACKGROUND_FILE="/opt/digitalsignage/assets/wallpapers/digitalsignage-background.png"$' "${missing_config}"
assert_contains '^DESKTOP_BACKGROUND_MODE=zoom$' "${missing_config}"
[ "$(count_active_key REFRESH_SECONDS "${missing_config}")" -eq 1 ]
[ "$(count_active_key CONTENT_MODE "${missing_config}")" -eq 1 ]
[ "$(count_active_key CONTENT_URL "${missing_config}")" -eq 1 ]
[ "$(count_active_key SCREENSHOT_CACHE_ENABLED "${missing_config}")" -eq 1 ]
[ "$(count_active_key SCREENSHOT_CACHE_REFRESH_SECONDS "${missing_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_WATERMARK_TEXT "${missing_config}")" -eq 1 ]
[ "$(count_active_key WEBSITE_OFFLINE_CAPTURE_MODE "${missing_config}")" -eq 1 ]
[ "$(count_active_key RESOURCE_LOG_RETENTION_DAYS "${missing_config}")" -eq 1 ]
[ "$(count_active_key HEALTH_CHECK_SECONDS "${missing_config}")" -eq 1 ]
[ "$(count_active_key HEALTH_FAILURE_THRESHOLD "${missing_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_PAGE_ENABLED "${missing_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_AFTER_SECONDS "${missing_config}")" -eq 1 ]
[ "$(count_active_key ONLINE_CONFIRM_SECONDS "${missing_config}")" -eq 1 ]
[ "$(count_active_key CONNECTIVITY_CHECK_URL "${missing_config}")" -eq 1 ]
[ "$(count_active_key CONNECTIVITY_TIMEOUT_SECONDS "${missing_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_PAGE_URL "${missing_config}")" -eq 1 ]
[ "$(count_active_key DESKTOP_BACKGROUND_ENABLED "${missing_config}")" -eq 1 ]
[ "$(count_active_key DESKTOP_BACKGROUND_FILE "${missing_config}")" -eq 1 ]
[ "$(count_active_key DESKTOP_BACKGROUND_MODE "${missing_config}")" -eq 1 ]
[ "$(stat -c '%a' "${missing_config}")" = "640" ]
ls "${missing_config}".backup.* >/dev/null

existing_config="${TEMP_DIR}/existing.conf"
cat > "${existing_config}" <<'EOF'
REFRESH_SECONDS=120
RESOURCE_LOG_RETENTION_DAYS=9
HEALTH_CHECK_SECONDS=30
HEALTH_FAILURE_THRESHOLD=5
HEALTH_RESTART_COOLDOWN_SECONDS=900
HEALTH_HTTP_TIMEOUT_SECONDS=7
HEALTH_STARTUP_GRACE_SECONDS=120
HEALTH_LOG_RETENTION_DAYS=4
HEALTH_LOG_MAX_BYTES=1048576
OFFLINE_PAGE_ENABLED=false
OFFLINE_AFTER_SECONDS=120
ONLINE_CONFIRM_SECONDS=45
CONNECTIVITY_CHECK_URL="https://example.org/check"
CONNECTIVITY_TIMEOUT_SECONDS=4
OFFLINE_PAGE_URL="file:///tmp/offline/index.html"
DESKTOP_BACKGROUND_ENABLED=false
DESKTOP_BACKGROUND_FILE="/eigen/achtergrond.png"
DESKTOP_BACKGROUND_MODE=fit
EOF
run_merge "${existing_config}"
assert_contains '^REFRESH_SECONDS=120$' "${existing_config}"
assert_contains '^RESOURCE_LOG_RETENTION_DAYS=9$' "${existing_config}"
assert_contains '^HEALTH_CHECK_SECONDS=30$' "${existing_config}"
assert_contains '^HEALTH_FAILURE_THRESHOLD=5$' "${existing_config}"
assert_contains '^HEALTH_RESTART_COOLDOWN_SECONDS=900$' "${existing_config}"
assert_contains '^HEALTH_HTTP_TIMEOUT_SECONDS=7$' "${existing_config}"
assert_contains '^HEALTH_STARTUP_GRACE_SECONDS=120$' "${existing_config}"
assert_contains '^HEALTH_LOG_RETENTION_DAYS=4$' "${existing_config}"
assert_contains '^HEALTH_LOG_MAX_BYTES=1048576$' "${existing_config}"
assert_contains '^OFFLINE_PAGE_ENABLED=false$' "${existing_config}"
assert_contains '^OFFLINE_AFTER_SECONDS=120$' "${existing_config}"
assert_contains '^ONLINE_CONFIRM_SECONDS=45$' "${existing_config}"
assert_contains '^CONNECTIVITY_CHECK_URL="https://example.org/check"$' "${existing_config}"
assert_contains '^CONNECTIVITY_TIMEOUT_SECONDS=4$' "${existing_config}"
assert_contains '^OFFLINE_PAGE_URL="file:///tmp/offline/index.html"$' "${existing_config}"
assert_contains '^DESKTOP_BACKGROUND_ENABLED=false$' "${existing_config}"
assert_contains '^DESKTOP_BACKGROUND_FILE="/eigen/achtergrond.png"$' "${existing_config}"
assert_contains '^DESKTOP_BACKGROUND_MODE=fit$' "${existing_config}"
[ "$(count_active_key REFRESH_SECONDS "${existing_config}")" -eq 1 ]
[ "$(count_active_key RESOURCE_LOG_RETENTION_DAYS "${existing_config}")" -eq 1 ]
[ "$(count_active_key HEALTH_CHECK_SECONDS "${existing_config}")" -eq 1 ]
[ "$(count_active_key HEALTH_FAILURE_THRESHOLD "${existing_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_PAGE_ENABLED "${existing_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_AFTER_SECONDS "${existing_config}")" -eq 1 ]
[ "$(count_active_key ONLINE_CONFIRM_SECONDS "${existing_config}")" -eq 1 ]
[ "$(count_active_key CONNECTIVITY_CHECK_URL "${existing_config}")" -eq 1 ]
[ "$(count_active_key CONNECTIVITY_TIMEOUT_SECONDS "${existing_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_PAGE_URL "${existing_config}")" -eq 1 ]
[ "$(count_active_key DESKTOP_BACKGROUND_ENABLED "${existing_config}")" -eq 1 ]
[ "$(count_active_key DESKTOP_BACKGROUND_FILE "${existing_config}")" -eq 1 ]
[ "$(count_active_key DESKTOP_BACKGROUND_MODE "${existing_config}")" -eq 1 ]

run_merge "${missing_config}"
[ "$(count_active_key REFRESH_SECONDS "${missing_config}")" -eq 1 ]
[ "$(count_active_key CONTENT_MODE "${missing_config}")" -eq 1 ]
[ "$(count_active_key CONTENT_URL "${missing_config}")" -eq 1 ]
[ "$(count_active_key SCREENSHOT_CACHE_ENABLED "${missing_config}")" -eq 1 ]
[ "$(count_active_key SCREENSHOT_CACHE_REFRESH_SECONDS "${missing_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_WATERMARK_TEXT "${missing_config}")" -eq 1 ]
[ "$(count_active_key WEBSITE_OFFLINE_CAPTURE_MODE "${missing_config}")" -eq 1 ]
[ "$(count_active_key RESOURCE_LOG_RETENTION_DAYS "${missing_config}")" -eq 1 ]
[ "$(count_active_key HEALTH_CHECK_SECONDS "${missing_config}")" -eq 1 ]
[ "$(count_active_key HEALTH_FAILURE_THRESHOLD "${missing_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_PAGE_ENABLED "${missing_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_AFTER_SECONDS "${missing_config}")" -eq 1 ]
[ "$(count_active_key ONLINE_CONFIRM_SECONDS "${missing_config}")" -eq 1 ]
[ "$(count_active_key CONNECTIVITY_CHECK_URL "${missing_config}")" -eq 1 ]
[ "$(count_active_key CONNECTIVITY_TIMEOUT_SECONDS "${missing_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_PAGE_URL "${missing_config}")" -eq 1 ]
[ "$(count_active_key DESKTOP_BACKGROUND_ENABLED "${missing_config}")" -eq 1 ]
[ "$(count_active_key DESKTOP_BACKGROUND_FILE "${missing_config}")" -eq 1 ]
[ "$(count_active_key DESKTOP_BACKGROUND_MODE "${missing_config}")" -eq 1 ]

commented_config="${TEMP_DIR}/commented.conf"
cat > "${commented_config}" <<'EOF'
#REFRESH_SECONDS=60
#RESOURCE_LOG_RETENTION_DAYS=12
#HEALTH_CHECK_SECONDS=15
#HEALTH_FAILURE_THRESHOLD=9
#OFFLINE_PAGE_ENABLED=false
#OFFLINE_AFTER_SECONDS=15
#DESKTOP_BACKGROUND_ENABLED=false
#DESKTOP_BACKGROUND_MODE=center
SWAP_LOG_MAX_BYTES=5242880
EOF
run_merge "${commented_config}"
assert_contains '^#REFRESH_SECONDS=60$' "${commented_config}"
assert_contains '^#RESOURCE_LOG_RETENTION_DAYS=12$' "${commented_config}"
assert_contains '^#HEALTH_CHECK_SECONDS=15$' "${commented_config}"
assert_contains '^#HEALTH_FAILURE_THRESHOLD=9$' "${commented_config}"
assert_contains '^#OFFLINE_PAGE_ENABLED=false$' "${commented_config}"
assert_contains '^#OFFLINE_AFTER_SECONDS=15$' "${commented_config}"
assert_contains '^#DESKTOP_BACKGROUND_ENABLED=false$' "${commented_config}"
assert_contains '^#DESKTOP_BACKGROUND_MODE=center$' "${commented_config}"
assert_contains '^REFRESH_SECONDS=300$' "${commented_config}"
assert_contains '^RESOURCE_LOG_RETENTION_DAYS=3$' "${commented_config}"
assert_contains '^HEALTH_CHECK_SECONDS=60$' "${commented_config}"
assert_contains '^HEALTH_FAILURE_THRESHOLD=3$' "${commented_config}"
assert_contains '^OFFLINE_PAGE_ENABLED=true$' "${commented_config}"
assert_contains '^OFFLINE_AFTER_SECONDS=300$' "${commented_config}"
assert_contains '^DESKTOP_BACKGROUND_ENABLED=true$' "${commented_config}"
assert_contains '^DESKTOP_BACKGROUND_MODE=zoom$' "${commented_config}"
[ "$(count_active_key REFRESH_SECONDS "${commented_config}")" -eq 1 ]
[ "$(count_active_key RESOURCE_LOG_RETENTION_DAYS "${commented_config}")" -eq 1 ]
[ "$(count_active_key HEALTH_CHECK_SECONDS "${commented_config}")" -eq 1 ]
[ "$(count_active_key HEALTH_FAILURE_THRESHOLD "${commented_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_PAGE_ENABLED "${commented_config}")" -eq 1 ]
[ "$(count_active_key OFFLINE_AFTER_SECONDS "${commented_config}")" -eq 1 ]
[ "$(count_active_key DESKTOP_BACKGROUND_ENABLED "${commented_config}")" -eq 1 ]
[ "$(count_active_key DESKTOP_BACKGROUND_MODE "${commented_config}")" -eq 1 ]

health_dropin_body="$(awk '/^write_health_timer_dropin\(\)/,/^}/' "${ROOT_DIR}/install/upgrade.sh")"
printf '%s\n' "${health_dropin_body}" | grep -q '^OnBootSec=$'
printf '%s\n' "${health_dropin_body}" | grep -q '^OnActiveSec=2min$'
printf '%s\n' "${health_dropin_body}" | grep -q '^OnUnitInactiveSec=${interval}s$'
! printf '%s\n' "${health_dropin_body}" | grep -q '^OnUnitActiveSec='
! printf '%s\n' "${health_dropin_body}" | grep -q '^OnUnitInactiveSec=$'

echo "Upgradeconfiguratie-merge OK."
