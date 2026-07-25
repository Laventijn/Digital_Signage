#!/usr/bin/env bash
set -Eeuo pipefail

# Compatibiliteitswrapper: de echte refresh gebeurt via Chrome DevTools Protocol.
exec /opt/digitalsignage/scripts/refresh-presentation.py
