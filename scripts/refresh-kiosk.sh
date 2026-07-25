#!/usr/bin/env bash
set -euo pipefail

pkill -HUP chromium 2>/dev/null || true
pkill -HUP chromium-browser 2>/dev/null || true
