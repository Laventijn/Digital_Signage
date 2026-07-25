#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
  cat <<'HELP'
Gebruik:
  bash tests/run-tests.sh pre
  sudo bash tests/run-tests.sh post
  bash tests/run-tests.sh help

Commando's:
  pre    Voer pre-installatietests uit.
  post   Voer post-installatietests uit.
  help   Toon deze hulptekst.
HELP
}

rerun_pre_as_sudo_user() {
  local original_user="${SUDO_USER:-}" passwd_entry original_uid original_home user_runtime user_bus

  if [ "${DIGITALSIGNAGE_PRE_REEXEC:-}" = "1" ]; then
    echo "FOUT: pre-installatietest draait nog steeds als root na terugschakelen naar SUDO_USER." >&2
    echo "Voer uit als gewone gebruiker:" >&2
    echo "  bash tests/run-tests.sh pre" >&2
    exit 1
  fi

  if [ -z "${original_user}" ] || [ "${original_user}" = "root" ]; then
    echo "FOUT: de pre-installatietest heeft geen sudo nodig en kan de oorspronkelijke gebruiker niet bepalen." >&2
    echo "Voer uit als gewone gebruiker:" >&2
    echo "  bash tests/run-tests.sh pre" >&2
    exit 1
  fi

  passwd_entry="$(getent passwd "${original_user}" || true)"
  if [ -z "${passwd_entry}" ]; then
    echo "FOUT: oorspronkelijke gebruiker '${original_user}' bestaat niet volgens getent passwd." >&2
    echo "Voer uit als gewone gebruiker:" >&2
    echo "  bash tests/run-tests.sh pre" >&2
    exit 1
  fi

  original_uid="$(printf '%s' "${passwd_entry}" | cut -d: -f3)"
  original_home="$(printf '%s' "${passwd_entry}" | cut -d: -f6)"
  user_runtime="/run/user/${original_uid}"
  user_bus="${user_runtime}/bus"

  echo "[WAARSCHUWING] De pre-installatietest heeft geen sudo nodig."
  echo "[INFO] De test wordt opnieuw gestart als gebruiker ${original_user}."

  exec runuser -u "${original_user}" -- env \
    HOME="${original_home}" \
    USER="${original_user}" \
    LOGNAME="${original_user}" \
    XDG_RUNTIME_DIR="${user_runtime}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" \
    DIGITALSIGNAGE_PRE_REEXEC=1 \
    bash "$0" pre
}

case "${1:-help}" in
  pre)
    if [ "$(id -u)" -eq 0 ]; then
      rerun_pre_as_sudo_user
    fi
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
