# VS Digital Signage

Project voor het installeren en beheren van een eenvoudige Digital Signage kiosk op een Linux-toestel, typisch een Raspberry Pi of mini-pc.
Het doelplatform is Raspberry Pi OS Trixie 64-bit met Wayland/labwc en Chromium via `/usr/bin/chromium`.

## Inhoud

- Documentatie staat in `docs/`.
- Installatie- en beheerscripts staan in `install/` en `scripts/`.
- Systemd servicebestanden staan in `services/`.
- Voorbeeldconfiguratie staat in `config/`.
- Offline fallbackpagina staat in `web/offline/`.

## Snelle start

1. Kopieer `config/digitalsignage.conf.example` naar `/etc/digitalsignage/digitalsignage.conf`.
2. Pas `PRESENTATION_URL` en kiosk-instellingen aan.
3. Voer de installatie uit:

```bash
sudo bash install/install.sh
```

## Google Slides Refresh En Resource-Logging

Google Slides speelt zelf af en loopt door via `loop=true` in de presentatie-URL. De periodieke refresh haalt alleen wijzigingen aan de online presentatie op. Dit gebeurt via Chrome DevTools Protocol en gebruikt geen F5, Ctrl+R of gesimuleerde toetsen. Google Slides voegt tijdens het afspelen vaak `&slide=id...` toe aan de URL; `Page.navigate` stuurt het bestaande tabblad terug naar de oorspronkelijke `PRESENTATION_URL`.

De kiosk draait als systemd user-service. Chromium gebruikt Wayland, een afzonderlijke profielmap en een afzonderlijke cachemap. De cachegrootte wordt begrensd via `CACHE_SIZE_MB`.

Bekijk de kioskservice als kioskgebruiker:

```bash
systemctl --user status digitalsignage-kiosk.service
```

Bekijk de user-timer als kioskgebruiker:

```bash
systemctl --user status digitalsignage-refresh.timer
```

Voer handmatig een presentatie-refresh uit:

```bash
systemctl --user start digitalsignage-refresh.service
```

RAM- en swaplogging staat in:

```bash
~/.local/state/digitalsignage/swap.log
```

Live meekijken:

```bash
tail -f ~/.local/state/digitalsignage/swap.log
```

Die resource-log staat los van de presentatie-refresh. De presentatie-refresh
draait standaard ongeveer iedere vijf minuten (`REFRESH_SECONDS=300`), terwijl
RAM en swap iedere 10 minuten worden opgeslagen via
`digitalsignage-resource-log.timer`. Logregels ouder dan 3 dagen worden
automatisch opgeruimd.

## Automatische Health-Check

`digitalsignage-health.timer` controleert standaard iedere minuut of de
kioskservice actief is, het Chromium-hoofdproces bestaat, poort
`127.0.0.1:9222` antwoordt en er een geldig Chromium-paginatarget bestaat.
Een enkele tijdelijke fout veroorzaakt geen restart. Standaard zijn drie
opeenvolgende fouten nodig; daarna wordt alleen
`digitalsignage-kiosk.service` herstart. Na een restart geldt tien minuten
cooldown en een startup-graceperiode van 90 seconden.

Status en logs:

```bash
systemctl --user status digitalsignage-health.timer --no-pager
systemctl --user list-timers --all | grep digitalsignage
tail -20 ~/.local/state/digitalsignage/health.log
cat ~/.local/state/digitalsignage/health-state.json
journalctl --user -u digitalsignage-health.service -n 50 --no-pager
```

Tijdelijk uitschakelen:

```bash
systemctl --user disable --now digitalsignage-health.timer
```

Opnieuw inschakelen:

```bash
systemctl --user enable --now digitalsignage-health.timer
```

## Documentatie

Begin met [docs/01-projectoverzicht.md](docs/01-projectoverzicht.md).

## Automatische installatietesten

Voer voor en na installatie deze controles uit:

```bash
bash tests/run-tests.sh pre
sudo bash install/install.sh
sudo bash tests/run-tests.sh post
```

De pre-installatietest draait bewust zonder `sudo`, omdat die de
systemd-user-units in de gebruikersomgeving moet verifieren.

De testlogs worden opgeslagen onder:

```bash
test-logs/
```

Als `test-logs/` verkeerde rechten heeft:

```bash
sudo chown -R "$USER":"$(id -gn)" test-logs
```

Python-cache blijft buiten Git via `.gitignore` (`__pycache__/` en `*.py[cod]`).
