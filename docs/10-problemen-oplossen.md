# Problemen Oplossen

## Kiosk start niet

```bash
systemctl --user status digitalsignage-kiosk.service
journalctl --user -u digitalsignage-kiosk.service -n 100
```

Wanneer `journalctl --user` geen regels toont, controleer dan de systeemjournal
op de user-unitnaam:

```bash
sudo journalctl _SYSTEMD_USER_UNIT=digitalsignage-kiosk.service --no-pager -n 20
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

## Desktopachtergrond Niet Zichtbaar

Controleer eerst of de achtergrond is geinstalleerd:

```bash
ls -l /opt/digitalsignage/assets/wallpapers/digitalsignage-background.png
```

Controleer daarna als kioskgebruiker de pcmanfm-configuratie:

```bash
grep -E '^(wallpaper|wallpaper_mode)=' ~/.config/pcmanfm/LXDE-pi/desktop-items-0.conf
```

De instelling wordt niet met een geforceerde desktoprestart afgedwongen. Als de
huidige desktop nog de oude achtergrond toont, meld de kioskgebruiker opnieuw
aan of herstart de Raspberry Pi gecontroleerd.

Tijdelijk uitschakelen kan via:

```ini
DESKTOP_BACKGROUND_ENABLED=false
```

Voer daarna uit:

```bash
sudo bash install/upgrade.sh
```

## Automatische Health-Check

De health-check draait als systemd user-timer. Een enkele tijdelijke fout
veroorzaakt geen restart; standaard zijn drie opeenvolgende fouten nodig. Na
een automatische kioskrestart geldt tien minuten cooldown en 90 seconden
startup-grace.

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

## Presentatie Refresh

De refresh gebeurt via Chrome DevTools Protocol op `127.0.0.1:9222`. Dit is betrouwbaarder dan F5, Ctrl+R of gesimuleerde toetsen, omdat Google Slides tijdens het afspelen `&slide=id...` aan de URL kan toevoegen. `Page.navigate` stuurt het bestaande Google Slides-tabblad terug naar de oorspronkelijke `PRESENTATION_URL`. Google Slides speelt zelf af en loopt via `loop=true`; de refresh haalt standaard ongeveer iedere vijf minuten wijzigingen op.

Timerstatus bekijken als kioskgebruiker:

```bash
systemctl --user status digitalsignage-refresh.timer
```

Handmatig een refresh starten:

```bash
systemctl --user start digitalsignage-refresh.service
```

## RAM- En Swaplog

RAM- en swaplogging staat los van de presentatie-refresh. De presentatie-refresh
draait standaard ongeveer iedere vijf minuten, terwijl
`digitalsignage-resource-log.timer` iedere 10 minuten een compacte regel
schrijft naar:

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

## Testlogs En Python-Cache

Testlogs staan in `test-logs/`. Als de pre-test meldt dat die map niet
schrijfbaar is:

```bash
sudo chown -R "$USER":"$(id -gn)" test-logs
```

Python-cachebestanden zoals `__pycache__/` en `*.pyc` horen niet in Git en
worden door `.gitignore` uitgesloten.

## Windows Fase-2A-Test

Vanaf Windows kan de Raspberry Pi-test gestart worden met:

```powershell
cmd /c "tools\windows\test-fase2a-pi.bat"
```

Pas zo nodig bovenaan in `tools\windows\test-fase2a-pi.bat` `PI_USER`,
`PI_HOST` en `PI_PROJECT_PATH` aan. De oude `test-fase1-pi.bat` blijft bestaan
als compatibiliteitswrapper. De batch gebruikt Windows `ssh` en `scp`, slaat
alle uitvoer op onder `tools\windows\logs\` en bewaart geen wachtwoorden.

## Fontconfig-Waarschuwing

Deze melding is als observatie bekend:

```text
Fontconfig error: Cannot load default config file: No such file: (null)
```

Wijzig hiervoor niet direct Chromium-flags, desktop-pakketten of fontconfigbestanden. Onderzoek dit pas verder wanneer de kioskweergave zichtbare problemen met lettertypes toont.
