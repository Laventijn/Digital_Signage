# Kiosk-installatie

De kiosk wordt geïnstalleerd met:

```bash
sudo bash install/install.sh
```

De installer kopieert scripts, webbestanden, configuratie en systemd-units naar de juiste locaties.
Daarnaast installeert de installer `python3` en `python3-websocket` wanneer `apt-get` beschikbaar is.

De Chromium-kiosk draait als systemd user-service van `KIOSK_USER`, niet als globale systeemservice. De healthcheck-units blijven voorlopig globale systemd-units.

Na installatie van de globale healthcheck:

```bash
sudo systemctl enable --now digitalsignage-healthcheck.timer
```

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

## Refresh Timer En Resource-Logtimer

De Google Slides-refresh gebruikt een systemd user-timer voor de kioskgebruiker. RAM- en swaplogging gebruikt een aparte user-timer, zodat de presentatie vaak kan vernieuwen zonder iedere refresh een logregel te schrijven. De unitbestanden worden geinstalleerd onder:

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
```

Status bekijken:

```bash
systemctl --user status digitalsignage-refresh.timer
systemctl --user status digitalsignage-resource-log.timer
```

Handmatig een refresh uitvoeren:

```bash
systemctl --user start digitalsignage-refresh.service
```

Handmatig een RAM- en swaplogregel schrijven:

```bash
systemctl --user start digitalsignage-resource-log.service
```
