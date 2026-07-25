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
assert_contains '^RESOURCE_LOG_RETENTION_DAYS=3$' "${missing_config}"
[ "$(count_active_key RESOURCE_LOG_RETENTION_DAYS "${missing_config}")" -eq 1 ]
[ "$(stat -c '%a' "${missing_config}")" = "640" ]
ls "${missing_config}".backup.* >/dev/null

existing_config="${TEMP_DIR}/existing.conf"
cat > "${existing_config}" <<'EOF'
RESOURCE_LOG_RETENTION_DAYS=9
EOF
run_merge "${existing_config}"
assert_contains '^RESOURCE_LOG_RETENTION_DAYS=9$' "${existing_config}"
[ "$(count_active_key RESOURCE_LOG_RETENTION_DAYS "${existing_config}")" -eq 1 ]

run_merge "${missing_config}"
[ "$(count_active_key RESOURCE_LOG_RETENTION_DAYS "${missing_config}")" -eq 1 ]

commented_config="${TEMP_DIR}/commented.conf"
cat > "${commented_config}" <<'EOF'
#RESOURCE_LOG_RETENTION_DAYS=12
SWAP_LOG_MAX_BYTES=5242880
EOF
run_merge "${commented_config}"
assert_contains '^#RESOURCE_LOG_RETENTION_DAYS=12$' "${commented_config}"
assert_contains '^RESOURCE_LOG_RETENTION_DAYS=3$' "${commented_config}"
[ "$(count_active_key RESOURCE_LOG_RETENTION_DAYS "${commented_config}")" -eq 1 ]

echo "Upgradeconfiguratie-merge OK."
