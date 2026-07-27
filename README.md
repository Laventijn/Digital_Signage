# VS Digital Signage

Project voor het installeren en beheren van een eenvoudige Digital Signage kiosk op een Linux-toestel, typisch een Raspberry Pi of mini-pc.
Het doelplatform is Raspberry Pi OS Trixie 64-bit met Wayland/labwc en Chromium via `/usr/bin/chromium`.

## Inhoud

- Documentatie staat in `docs/`.
- Installatie- en beheerscripts staan in `install/` en `scripts/`.
- Systemd servicebestanden staan in `services/`.
- Voorbeeldconfiguratie staat in `config/`.
- De vaste desktopachtergrond staat in `assets/wallpapers/`.
- Offline fallbackpagina staat in `assets/offline/` en wordt geinstalleerd naar `/opt/digitalsignage/offline/`.
- Lokale screenshotcache wordt uitgelegd in `docs/21-screenshot-cache.md`.

## Snelle start

1. Kopieer `config/digitalsignage.conf.example` naar `/etc/digitalsignage/digitalsignage.conf`.
2. Pas `CONTENT_MODE`, `CONTENT_URL` en kiosk-instellingen aan. Oudere installaties kunnen `PRESENTATION_URL` blijven gebruiken als fallback.
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
cat ~/.local/state/digitalsignage/connectivity.state
journalctl --user -u digitalsignage-health.service -n 50 --no-pager
```

## Offline Gedrag

De health-check controleert internet via NetworkManager en een HTTP-controle.
Alleen `nmcli -t -f CONNECTIVITY general` met waarde `full` plus een geslaagde
HTTP-controle naar `CONNECTIVITY_CHECK_URL` telt als online. Bij kort
internetverlies blijft de huidige Chromium-pagina zichtbaar. Na standaard
`OFFLINE_AFTER_SECONDS=300` seconden bevestigd offline navigeert Chromium een
keer naar:

```bash
file:///opt/digitalsignage/offline/index.html
```

Wanneer internet terug is, wacht de kiosk standaard
`ONLINE_CONFIRM_SECONDS=30` seconden voordat hij teruggaat naar
`PRESENTATION_URL`. Uitschakelen kan met:

```ini
OFFLINE_PAGE_ENABLED=false
```

Tijdelijk uitschakelen:

```bash
systemctl --user disable --now digitalsignage-health.timer
```

Opnieuw inschakelen:

```bash
systemctl --user enable --now digitalsignage-health.timer
```

## Desktopachtergrond

De installer stelt een vaste Digital Signage-achtergrond in voor de kioskgebruiker.
Die achtergrond is zichtbaar voordat Chromium start, tijdens een korte
Chromium-herstart en wanneer de kioskservice niet actief is. Raspberry Pi OS
Trixie met Desktop gebruikt hiervoor de per-user pcmanfm-configuratie:

```bash
~/.config/pcmanfm/LXDE-pi/desktop-items-0.conf
```

Instellingen:

```ini
DESKTOP_BACKGROUND_ENABLED=true
DESKTOP_BACKGROUND_FILE="/opt/digitalsignage/assets/wallpapers/digitalsignage-background.png"
DESKTOP_BACKGROUND_MODE=zoom
```

Tijdelijk uitschakelen kan door `DESKTOP_BACKGROUND_ENABLED=false` te zetten en
daarna `sudo bash install/upgrade.sh` uit te voeren.

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
