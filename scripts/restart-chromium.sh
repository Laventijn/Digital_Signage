#!/usr/bin/env bash
set -euo pipefail

pkill chromium 2>/dev/null || true
pkill chromium-browser 2>/dev/null || true
systemctl restart digitalsignage-kiosk.service
