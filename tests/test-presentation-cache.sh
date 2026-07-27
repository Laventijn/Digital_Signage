#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 -m py_compile \
  "${ROOT}/scripts/sync-presentation-cache.py" \
  "${ROOT}/tests/test-presentation-cache.py"

python3 -m unittest "${ROOT}/tests/test-presentation-cache.py"
bash -n "${ROOT}/install/upgrade-presentation-cache.sh"

grep -q '^CONTENT_MODE="presentation"$' "${ROOT}/config/digitalsignage.conf.example"
grep -q '^PRESENTATION_CACHE_INCLUDE_SKIPPED_SLIDES=false$' "${ROOT}/config/digitalsignage.conf.example"
grep -q '^SuccessExitStatus=0 10$' "${ROOT}/services/digitalsignage-presentation-cache.service"
grep -q 'content_mode\|cfg.mode' "${ROOT}/scripts/sync-presentation-cache.py"
grep -q 'isSkipped' "${ROOT}/scripts/sync-presentation-cache.py"

echo "Presentation cache tests OK."
