#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_files=(
  "config/digitalsignage.conf.example"
  "install/install.sh"
  "scripts/start-kiosk.sh"
  "services/digitalsignage-kiosk.service"
  "web/offline/index.html"
)

for file in "${required_files[@]}"; do
  if [ ! -f "${ROOT_DIR}/${file}" ]; then
    echo "Missing required file: ${file}" >&2
    exit 1
  fi
done

echo "Installation file layout OK."
