# Configuratie

Kopieer het voorbeeldbestand:

```bash
sudo mkdir -p /etc/digitalsignage
sudo cp config/digitalsignage.conf.example /etc/digitalsignage/digitalsignage.conf
```

Pas minstens `PRESENTATION_URL` aan.

Zie `config/digitalsignage.conf.example` voor alle opties.

## Belangrijke Instellingen

- `PRESENTATION_URL`: oorspronkelijke Google Slides-presentatie-URL.
- `REMOTE_DEBUG_HOST`: standaard `127.0.0.1`.
- `REMOTE_DEBUG_PORT`: standaard `9222`.
- `WAYLAND_DISPLAY`: standaard `wayland-0`.
- `CHROMIUM_BIN`: standaard `/usr/bin/chromium`.
- `CHROMIUM_PROFILE_DIR`: profielmap relatief aan de home van de kioskgebruiker.
- `CHROMIUM_CACHE_DIR`: cachemap relatief aan de home van de kioskgebruiker.
- `REFRESH_SECONDS`: gewenste refreshinterval in seconden; standaard `300`.
- `CACHE_SIZE_MB`: begrensde Chromium-cachegrootte in MiB.
- `KIOSK_USER`: lokale kioskgebruiker.
- `SWAP_LOG_MAX_BYTES`: maximale grootte van `swap.log` voor rotatie.
- `RESOURCE_LOG_RETENTION_DAYS`: aantal dagen dat RAM- en swaplogregels bewaard blijven.

De installer en upgrader schrijven `digitalsignage-refresh.timer` op basis van `REFRESH_SECONDS`. Een bestaande aangepaste waarde wordt bij upgrade niet overschreven.
De resource-logtimer staat standaard op 10 minuten in `digitalsignage-resource-log.timer`.

Plaats geen wachtwoorden, Wi-Fi-sleutels, tokens of andere geheimen in dit configuratiebestand wanneer het in Git terecht kan komen.

## Google Slides URL

Google Slides voegt tijdens het afspelen vaak `&slide=id...` aan de URL toe. De refresh gebruikt daarom geen F5 of gesimuleerde toetsen, maar stuurt het bestaande tabblad via Chrome DevTools Protocol terug naar de oorspronkelijke `PRESENTATION_URL`. Gebruik voor automatisch doorlopen `loop=true` in de URL.

## Chromium Op Wayland

De kiosk gebruikt Wayland/labwc, niet X11. Gebruik daarom geen oude X11-variabelen, toetsenbordautomatisering of verouderde Chromium-binarynamen. Chromium start met `/usr/bin/chromium`, `WAYLAND_DISPLAY=wayland-0`, een afzonderlijke profielmap en een afzonderlijke cachemap.
