#!/usr/bin/env bash

# ============================================================
# Digital Signage - geautomatiseerde Fase 2-test
# Dit script wordt door test-fase1-pi.bat op de Raspberry Pi
# geplaatst en uitgevoerd.
# ============================================================

set -u
export TERM="${TERM:-dumb}"
export NO_COLOR="${NO_COLOR:-1}"
export GIT_PAGER="${GIT_PAGER:-cat}"
export SYSTEMD_COLORS=0

FAILURES=0
WARNINGS=0

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

ok() {
    echo "[OK] $1"
}

warning() {
    echo "[WAARSCHUWING] $1"
    WARNINGS=$((WARNINGS + 1))
}

failure() {
    echo "[FOUT] $1"
    FAILURES=$((FAILURES + 1))
}

# ============================================================
# 1. Algemene systeeminformatie
# ============================================================

section "1. Systeeminformatie"

date
hostname
uname -a

echo "Gebruiker: $(whoami)"
echo "Home: $HOME"

# ============================================================
# 2. Projectmap zoeken
# ============================================================

section "2. Projectmap zoeken"

PROJECT_DIR=""

POSSIBLE_DIRECTORIES=(
    "$HOME/DigitalSignage"
    "$HOME/Digital_Signage"
    "$HOME/Digital-Signage"
    "$HOME/VS_Digital_Signage"
    "$HOME/digitalsignage"
)

if [[ -n "${DIGITALSIGNAGE_PROJECT_PATH:-}" && -d "${DIGITALSIGNAGE_PROJECT_PATH}/.git" ]]; then
    PROJECT_DIR="${DIGITALSIGNAGE_PROJECT_PATH}"
fi

for directory in "${POSSIBLE_DIRECTORIES[@]}"; do
    [[ -n "$PROJECT_DIR" ]] && break
    if [[ -d "$directory/.git" ]]; then
        PROJECT_DIR="$directory"
        break
    fi
done

if [[ -z "$PROJECT_DIR" ]]; then
    failure "Geen Git-repository gevonden in de bekende projectmappen."

    echo
    echo "Mappen onder $HOME:"
    find "$HOME" -maxdepth 2 -type d -name ".git" 2>/dev/null || true

    echo
    echo "Pas de lijst POSSIBLE_DIRECTORIES in het testscript aan."
    exit 1
fi

cd "$PROJECT_DIR" || {
    failure "Kan projectmap niet openen: $PROJECT_DIR"
    exit 1
}

ok "Projectmap gevonden: $PROJECT_DIR"

# ============================================================
# 3. Git controleren
# ============================================================

section "3. Git-controle"

echo "Branch:"
git --no-pager branch --show-current || true

echo
echo "Remote:"
git --no-pager remote -v || true

echo
echo "Laatste drie commits:"
git --no-pager -c color.ui=false log --oneline -3 || true

echo
echo "Git-status:"
git -c color.ui=false status || true

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    warning "De repository op de Raspberry Pi bevat lokale wijzigingen."
else
    ok "De Git-working-tree is schoon."
fi

# ============================================================
# 4. Nieuwste wijzigingen ophalen
# ============================================================

section "4. Git pull"

if git -c color.ui=false pull --ff-only; then
    ok "git pull --ff-only is geslaagd."
else
    failure "git pull is mislukt."
fi

echo
echo "Huidige laatste commit:"
git --no-pager -c color.ui=false log --oneline -1 || true

# ============================================================
# 5. Pre-test
# ============================================================

section "5. Pre-test"

if [[ ! -f "tests/run-tests.sh" ]]; then
    failure "tests/run-tests.sh bestaat niet."
else
    if bash tests/run-tests.sh pre; then
        ok "Pre-test is geslaagd."
    else
        failure "Pre-test meldde een fout."
    fi
fi

# ============================================================
# 6. Upgrade uitvoeren
# ============================================================

section "6. Upgrade"

if [[ ! -f "install/upgrade.sh" ]]; then
    failure "install/upgrade.sh bestaat niet."
else
    if sudo bash install/upgrade.sh; then
        ok "Upgrade is geslaagd."
    else
        failure "Upgrade is mislukt."
    fi
fi

# ============================================================
# 7. Configuratie controleren
# ============================================================

section "7. Configuratie"

CONFIG_FILE="/etc/digitalsignage/digitalsignage.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    failure "Configuratiebestand ontbreekt: $CONFIG_FILE"
else
    echo "Relevante configuratieregels:"
    sudo grep -E \
        '^(REFRESH_SECONDS|RESOURCE_LOG_RETENTION_DAYS|SWAP_LOG_MAX_BYTES|PRESENTATION_URL)=' \
        "$CONFIG_FILE" || true

    RETENTION_COUNT="$(
        sudo grep -c '^RESOURCE_LOG_RETENTION_DAYS=' \
            "$CONFIG_FILE" 2>/dev/null || true
    )"

    if [[ "$RETENTION_COUNT" == "1" ]]; then
        ok "RESOURCE_LOG_RETENTION_DAYS staat exact eenmaal in de configuratie."
    else
        failure "RESOURCE_LOG_RETENTION_DAYS staat $RETENTION_COUNT keer in de configuratie."
    fi

    if sudo grep -q '^RESOURCE_LOG_RETENTION_DAYS=3$' "$CONFIG_FILE"; then
        ok "RESOURCE_LOG_RETENTION_DAYS=3 is correct."
    else
        failure "RESOURCE_LOG_RETENTION_DAYS=3 ontbreekt."
    fi

    if sudo grep -q '^REFRESH_SECONDS=300$' "$CONFIG_FILE"; then
        ok "REFRESH_SECONDS=300 is correct."
    else
        warning "REFRESH_SECONDS is niet 300; dit kan een bewuste lokale override zijn."
    fi

    if sudo grep -q '^SWAP_LOG_MAX_BYTES=5242880$' "$CONFIG_FILE"; then
        ok "SWAP_LOG_MAX_BYTES=5242880 is correct."
    else
        failure "SWAP_LOG_MAX_BYTES heeft niet de verwachte waarde."
    fi

    if sudo grep '^PRESENTATION_URL=' "$CONFIG_FILE" | grep -q 'loop=true'; then
        ok "PRESENTATION_URL bevat loop=true."
    else
        warning "PRESENTATION_URL bevat geen loop=true."
    fi
fi

# ============================================================
# 8. User-services en timers
# ============================================================

section "8. User-services en timers"

UNITS=(
    "digitalsignage-kiosk.service"
    "digitalsignage-refresh.timer"
    "digitalsignage-resource-log.timer"
)

for unit in "${UNITS[@]}"; do
    STATE="$(systemctl --user is-active "$unit" 2>/dev/null || true)"

    printf "%-45s %s\n" "$unit" "$STATE"

    if [[ "$STATE" == "active" ]]; then
        ok "$unit is actief."
    else
        failure "$unit is niet actief."
    fi
done

echo
echo "Digital Signage-timers:"
systemctl --user list-timers --all |
    grep digitalsignage || true

# ============================================================
# 9. Chromium DevTools en loop
# ============================================================

section "9. Chromium en presentatie-loop"

CDP_FILE="/tmp/digitalsignage-cdp.json"

if curl -fsS \
    "http://127.0.0.1:9222/json" \
    > "$CDP_FILE"; then

    ok "Chromium DevTools-poort 9222 reageert."

    if grep -q 'loop=true' "$CDP_FILE"; then
        ok "De geopende Chromium-pagina bevat loop=true."
    else
        warning "In Chromium werd loop=true niet gevonden."
    fi
else
    failure "Chromium DevTools-poort 9222 reageert niet."
fi

rm -f "$CDP_FILE"

# ============================================================
# 10. Oude healthcheck
# ============================================================

section "10. Oude healthcheck"

HEALTHCHECK_ENABLED="$(
    systemctl is-enabled \
        digitalsignage-healthcheck.timer \
        2>/dev/null || true
)"

HEALTHCHECK_ACTIVE="$(
    systemctl is-active \
        digitalsignage-healthcheck.timer \
        2>/dev/null || true
)"

echo "Enabled-status: $HEALTHCHECK_ENABLED"
echo "Active-status:  $HEALTHCHECK_ACTIVE"

if [[ "$HEALTHCHECK_ACTIVE" == "active" ]]; then
    failure "De oude digitalsignage-healthcheck.timer is nog actief."
else
    ok "De oude healthcheck-timer is niet actief."
fi

echo
echo "Gefaalde systeemservices:"
systemctl --failed --no-pager || true

FAILED_COUNT="$(
    systemctl --failed --no-legend 2>/dev/null |
        grep -c . || true
)"

if [[ "$FAILED_COUNT" == "0" ]]; then
    ok "Er zijn geen gefaalde systeemservices."
else
    failure "Er zijn $FAILED_COUNT gefaalde systeemservices."
fi

# ============================================================
# 11. Post-test
# ============================================================

section "11. Post-test"

if [[ -f "tests/run-tests.sh" ]]; then
    if sudo bash tests/run-tests.sh post; then
        ok "Post-test is geslaagd."
    else
        failure "Post-test meldde een fout."
    fi
fi

# ============================================================
# 12. Resource-logging testen
# ============================================================

section "12. Resource-logging"

SWAP_LOG="$HOME/.local/state/digitalsignage/swap.log"

if [[ ! -f "$SWAP_LOG" ]]; then
    failure "Swap-log ontbreekt: $SWAP_LOG"
else
    BEFORE="$(wc -l < "$SWAP_LOG")"

    echo "Regels voor refresh-test: $BEFORE"

    if systemctl --user start digitalsignage-refresh.service; then
        ok "Eerste handmatige refresh uitgevoerd."
    else
        failure "Eerste handmatige refresh mislukt."
    fi

    sleep 2

    if systemctl --user start digitalsignage-refresh.service; then
        ok "Tweede handmatige refresh uitgevoerd."
    else
        failure "Tweede handmatige refresh mislukt."
    fi

    sleep 2

    AFTER_REFRESH="$(wc -l < "$SWAP_LOG")"

    echo "Regels na refresh-test: $AFTER_REFRESH"

    if [[ "$BEFORE" == "$AFTER_REFRESH" ]]; then
        ok "Refresh voegt geen resource-regels toe."
    else
        failure "Refresh heeft het resource-log gewijzigd."
    fi

    if systemctl --user start digitalsignage-resource-log.service; then
        ok "Resource-logservice uitgevoerd."
    else
        failure "Resource-logservice kon niet gestart worden."
    fi

    sleep 2

    AFTER_RESOURCE="$(wc -l < "$SWAP_LOG")"

    echo "Regels na resource-logservice: $AFTER_RESOURCE"
    echo
    echo "Laatste drie logregels:"
    tail -3 "$SWAP_LOG"

    EXPECTED_RESOURCE_COUNT=$((AFTER_REFRESH + 1))

    if [[ "$AFTER_RESOURCE" -eq "$EXPECTED_RESOURCE_COUNT" ]]; then
        ok "Resource-logservice voegde exact één regel toe."
    else
        failure "Resource-logservice voegde niet exact één regel toe."
    fi

    if tail -1 "$SWAP_LOG" | grep -q 'resource=ok'; then
        ok "De laatste logregel bevat resource=ok."
    else
        failure "De laatste logregel bevat geen resource=ok."
    fi
fi

# ============================================================
# 13. Eindresultaat
# ============================================================

section "13. Eindresultaat"

echo "Waarschuwingen: $WARNINGS"
echo "Fouten:         $FAILURES"
echo

if [[ "$FAILURES" -eq 0 ]]; then
    echo "FASE 1 TEST: GESLAAGD"
    exit 0
else
    echo "FASE 1 TEST: NIET GESLAAGD"
    exit 1
fi
