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

Iedere refreshpoging schrijft exact een compacte regel naar:

```bash
~/.local/state/digitalsignage/swap.log
```

Live meekijken:

```bash
tail -f ~/.local/state/digitalsignage/swap.log
```

Bij uninstall wordt dit log niet standaard verwijderd. Handmatig opruimen kan met:

```bash
rm -f ~/.local/state/digitalsignage/swap.log ~/.local/state/digitalsignage/swap.log.1
```
