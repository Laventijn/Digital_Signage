# Problemen Oplossen

## Kiosk start niet

```bash
systemctl --user status digitalsignage-kiosk.service
journalctl --user -u digitalsignage-kiosk.service -n 100
```

Controleer bij Wayland-problemen als kioskgebruiker:

```bash
echo "$XDG_RUNTIME_DIR"
ls -l /run/user/$(id -u)/wayland-0
ls -l /run/user/$(id -u)/bus
```

## Geen netwerk

```bash
scripts/show-network-info.sh
scripts/check-network.sh
```

## Chromium hangt vast

```bash
scripts/restart-chromium.sh
```

`scripts/refresh-kiosk.sh` is alleen nog een compatibiliteitswrapper naar `refresh-presentation.py`. De wrapper stuurt geen F5, Ctrl+R, SIGHUP of toetsen meer.

## Presentatie Refresh

De refresh gebeurt via Chrome DevTools Protocol op `127.0.0.1:9222`. Dit is betrouwbaarder dan F5, Ctrl+R of gesimuleerde toetsen, omdat Google Slides tijdens het afspelen `&slide=id...` aan de URL kan toevoegen. `Page.navigate` stuurt het bestaande Google Slides-tabblad terug naar de oorspronkelijke `PRESENTATION_URL`.

Timerstatus bekijken als kioskgebruiker:

```bash
systemctl --user status digitalsignage-refresh.timer
```

Handmatig een refresh starten:

```bash
systemctl --user start digitalsignage-refresh.service
```

## RAM- En Swaplog

RAM- en swaplogging staat los van de presentatie-refresh. De presentatie wordt
standaard iedere 30 seconden vernieuwd, terwijl `digitalsignage-resource-log.timer`
iedere 10 minuten een compacte regel schrijft naar:

```bash
~/.local/state/digitalsignage/swap.log
```

Status bekijken:

```bash
systemctl --user status digitalsignage-resource-log.timer
```

Handmatig een logregel schrijven:

```bash
systemctl --user start digitalsignage-resource-log.service
```

Live meekijken:

```bash
tail -f ~/.local/state/digitalsignage/swap.log
```

Bij uninstall wordt dit log niet standaard verwijderd. Handmatig opruimen kan met:

```bash
rm -f ~/.local/state/digitalsignage/swap.log ~/.local/state/digitalsignage/swap.log.1
```

Logregels ouder dan 3 dagen worden automatisch verwijderd.

## Fontconfig-Waarschuwing

Deze melding is als observatie bekend:

```text
Fontconfig error: Cannot load default config file: No such file: (null)
```

Wijzig hiervoor niet direct Chromium-flags, desktop-pakketten of fontconfigbestanden. Onderzoek dit pas verder wanneer de kioskweergave zichtbare problemen met lettertypes toont.
