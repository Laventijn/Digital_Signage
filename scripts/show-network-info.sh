#!/usr/bin/env bash
set -euo pipefail

echo "Hostname: $(hostname)"
echo "IP addresses:"
hostname -I || true
echo
echo "Routes:"
ip route || true
echo
echo "DNS:"
cat /etc/resolv.conf || true
