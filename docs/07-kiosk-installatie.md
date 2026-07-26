# Kiosk-installatie

De kiosk wordt geïnstalleerd met:

```bash
bash tests/run-tests.sh pre
sudo bash install/install.sh
sudo bash tests/run-tests.sh post
```

De pre-installatietest gebruikt geen `sudo`, omdat de systemd-user-units in de
gebruikersomgeving gecontroleerd moeten worden.

De installer kopieert scripts, webbestanden, configuratie en systemd-units naar de juiste locaties.
Daarnaast installeert de installer `python3` en `python3-websocket` wanneer `apt-get` beschikbaar is.

De Chromium-kiosk en de automatische health-check draaien als systemd
user-services van `KIOSK_USER`, niet als globale systeemservices.

De installer stelt ook een vaste desktopachtergrond in voor de kioskgebruiker.
Die achtergrond is zichtbaar voordat Chromium start, tijdens een gecontroleerde
Chromium-herstart of wanneer de kioskservice niet actief is.

## Kiosk User-Service

De kiosk gebruikt Raspberry Pi OS Trixie met Wayland/labwc en start `/usr/bin/chromium` met `--ozone-platform=wayland`. De user-service wordt geinstalleerd onder:

```bash
~/.config/systemd/user/digitalsignage-kiosk.service
```

Als kioskgebruiker:

```bash
systemctl --user daemon-reload
systemctl --user enable --now digitalsignage-kiosk.service
```

Status bekijken:

```bash
systemctl --user status digitalsignage-kiosk.service
```

Kiosk tijdelijk stoppen:

```bash
systemctl --user stop digitalsignage-kiosk.service
```

Kiosk stoppen en voorkomen dat hij automatisch opnieuw start bij de volgende
usersessie:

```bash
systemctl --user disable --now digitalsignage-kiosk.service
```

Let op: als de health-check actief blijft, kan die de kiosk later opnieuw
starten. Stop daarom tijdelijk ook de healthtimer wanneer de kiosk bewust uit
moet blijven:

```bash
systemctl --user disable --now digitalsignage-health.timer
```

Kiosk opnieuw inschakelen:

```bash
systemctl --user enable --now digitalsignage-kiosk.service
```

Health-check opnieuw inschakelen:

```bash
systemctl --user enable --now digitalsignage-health.timer
```

## Refresh Timer, Resource-Logtimer En Healthtimer

De Google Slides-refresh gebruikt een systemd user-timer voor de kioskgebruiker. Google Slides speelt zelf af en loopt via `loop=true`; de refresh haalt alleen periodiek wijzigingen op. Standaard gebeurt dat ongeveer iedere vijf minuten via `REFRESH_SECONDS=300`. RAM- en swaplogging gebruikt een aparte user-timer van 10 minuten. De health-check gebruikt een aparte user-timer van standaard 60 seconden. De unitbestanden worden geinstalleerd onder:

```bash
~/.config/systemd/user/
```

Wanneer er tijdens installatie een actieve usersessie bestaat, wordt de timer automatisch geladen en gestart. Zonder actieve usersessie toont de installer handmatige vervolgstappen.

Als kioskgebruiker:

```bash
systemctl --user daemon-reload
systemctl --user enable --now digitalsignage-kiosk.service
systemctl --user enable --now digitalsignage-refresh.timer
systemctl --user enable --now digitalsignage-resource-log.timer
systemctl --user enable --now digitalsignage-health.timer
```

Status bekijken:

```bash
systemctl --user status digitalsignage-refresh.timer
systemctl --user status digitalsignage-resource-log.timer
systemctl --user status digitalsignage-health.timer
```

Op Raspberry Pi OS Trixie staan user-unitlogs soms vooral in de systeemjournal:

```bash
sudo journalctl _SYSTEMD_USER_UNIT=digitalsignage-kiosk.service --no-pager -n 20
```

Handmatig een refresh uitvoeren:

```bash
systemctl --user start digitalsignage-refresh.service
```

Handmatig een RAM- en swaplogregel schrijven:

```bash
systemctl --user start digitalsignage-resource-log.service
```

Handmatig een health-check uitvoeren zonder automatische herstelactie:

```bash
/opt/digitalsignage/scripts/health-check.py --check-only
```

## Desktopachtergrond

De achtergrond wordt geinstalleerd als:

```bash
/opt/digitalsignage/assets/wallpapers/digitalsignage-background.png
```

Voor Raspberry Pi OS Trixie met labwc wordt de desktopachtergrond ingesteld via
de pcmanfm-configuratie van de kioskgebruiker:

```bash
~/.config/pcmanfm/LXDE-pi/desktop-items-0.conf
```

Controleer de instelling als kioskgebruiker:

```bash
grep -E '^(wallpaper|wallpaper_mode)=' ~/.config/pcmanfm/LXDE-pi/desktop-items-0.conf
```

Tijdelijk uitschakelen:

```ini
DESKTOP_BACKGROUND_ENABLED=false
```

Voer daarna opnieuw uit:

```bash
sudo bash install/upgrade.sh
```
