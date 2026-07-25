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

## Google Slides Refresh

De presentatie wordt vernieuwd via Chrome DevTools Protocol. Dit gebruikt geen F5, Ctrl+R of gesimuleerde toetsen. Google Slides voegt tijdens het afspelen vaak `&slide=id...` toe aan de URL; `Page.navigate` stuurt het bestaande tabblad telkens terug naar de oorspronkelijke `PRESENTATION_URL`.

De kiosk draait als systemd user-service. Chromium gebruikt Wayland, een afzonderlijke profielmap en een afzonderlijke cachemap. De cachegrootte wordt begrensd via `CACHE_SIZE_MB`.

Bekijk de kioskservice als kioskgebruiker:

```bash
systemctl --user status digitalsignage-kiosk.service
```

Bekijk de user-timer als kioskgebruiker:

```bash
systemctl --user status digitalsignage-refresh.timer
```

Voer handmatig een refresh uit:

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

## Documentatie

Begin met [docs/01-projectoverzicht.md](docs/01-projectoverzicht.md).

## Automatische installatietesten

Voer voor en na installatie deze controles uit:

```bash
sudo bash tests/run-tests.sh pre
sudo bash install/install.sh
sudo bash tests/run-tests.sh post
```

De testlogs worden opgeslagen onder:

```bash
test-logs/
```
