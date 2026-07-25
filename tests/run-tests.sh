#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
  cat <<'HELP'
Gebruik:
  sudo bash tests/run-tests.sh pre
  sudo bash tests/run-tests.sh post
  bash tests/run-tests.sh help

Commando's:
  pre    Voer pre-installatietests uit.
  post   Voer post-installatietests uit.
  help   Toon deze hulptekst.
HELP
}

case "${1:-help}" in
  pre)
    bash "${SCRIPT_DIR}/pre-install-test.sh"
    exit $?
    ;;
  post)
    if [ "$(id -u)" -ne 0 ]; then
      echo "FOUT: post-installatietest heeft rootrechten nodig. Gebruik: sudo bash tests/run-tests.sh post" >&2
      exit 1
    fi
    bash "${SCRIPT_DIR}/post-install-test.sh"
    exit $?
    ;;
  help|-h|--help)
    show_help
    exit 0
    ;;
  *)
    echo "FOUT: onbekend argument: $1" >&2
    show_help >&2
    exit 1
    ;;
esac
