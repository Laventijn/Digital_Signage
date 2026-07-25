#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find "${ROOT_DIR}/install" "${ROOT_DIR}/scripts" "${ROOT_DIR}/tests" -name "*.sh" -print0 |
  while IFS= read -r -d '' file; do
    bash -n "${file}"
  done

echo "Shell syntax OK."
