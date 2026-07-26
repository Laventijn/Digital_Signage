#!/usr/bin/env bash
set -Eeuo pipefail

systemctl --user restart digitalsignage-kiosk.service
