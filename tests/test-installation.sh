#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_files=(
  "config/digitalsignage.conf.example"
  "install/install.sh"
  "install/upgrade.sh"
  "scripts/start-kiosk.sh"
  "scripts/refresh-presentation.py"
  "scripts/log-resources.py"
  "services/digitalsignage-kiosk.service"
  "services/digitalsignage-refresh.service"
  "services/digitalsignage-refresh.timer"
  "services/digitalsignage-resource-log.service"
  "services/digitalsignage-resource-log.timer"
  "web/offline/index.html"
)

for file in "${required_files[@]}"; do
  if [ ! -f "${ROOT_DIR}/${file}" ]; then
    echo "Missing required file: ${file}" >&2
    exit 1
  fi
done

home_prefix="/home"
if grep -R -n -E "${home_prefix}/(pi|bloemkool)" "${ROOT_DIR}/install" "${ROOT_DIR}/scripts" "${ROOT_DIR}/services" "${ROOT_DIR}/config"; then
  echo "Hardcoded homepad gevonden." >&2
  exit 1
fi

if ! grep -q 'user_state_dir=.*\.local/state/digitalsignage' "${ROOT_DIR}/install/install.sh" ||
  ! grep -q 'install -d -m 0755 .*"${user_state_dir}"' "${ROOT_DIR}/install/install.sh"; then
  echo "Installer maakt de gebruikersstatusmap niet aan." >&2
  exit 1
fi

if ! grep -q 'user_state_dir=.*\.local/state/digitalsignage' "${ROOT_DIR}/install/upgrade.sh" ||
  ! grep -q 'install -d -m 0755 .*"${user_state_dir}"' "${ROOT_DIR}/install/upgrade.sh"; then
  echo "Upgrader maakt de gebruikersstatusmap niet aan." >&2
  exit 1
fi

if grep -q '^ReadWritePaths=' "${ROOT_DIR}/services/digitalsignage-resource-log.service"; then
  echo "Resource-logservice bevat nog een fragiele ReadWritePaths-instelling." >&2
  exit 1
fi

if ! grep -q '^StateDirectory=digitalsignage$' "${ROOT_DIR}/services/digitalsignage-resource-log.service"; then
  echo "Resource-logservice definieert geen StateDirectory=digitalsignage." >&2
  exit 1
fi

if grep -q 'Path.home() / ".local" / "state" / "digitalsignage"' "${ROOT_DIR}/scripts/refresh-presentation.py"; then
  echo "Refreshscript mag niet langer naar de gebruikersstatusmap loggen." >&2
  exit 1
fi

if ! grep -q 'Path.home() / ".local" / "state" / "digitalsignage"' "${ROOT_DIR}/scripts/log-resources.py"; then
  echo "Resource-logscript logt niet naar de verwachte gebruikersstatusmap." >&2
  exit 1
fi

echo "Installation file layout OK."
