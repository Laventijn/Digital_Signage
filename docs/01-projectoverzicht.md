# Projectoverzicht

VS Digital Signage toont automatisch een Google Slides-presentatie op een Raspberry Pi in Chromium-kioskmodus.

Het project is bedoeld voor een stabiele, onderhoudbare kiosk die door een ICT-medewerker opnieuw geinstalleerd, getest en beheerd kan worden.

## Doel

De installatie moet:

- automatisch starten na aanmelden van de kioskgebruiker;
- Raspberry Pi OS Trixie 64-bit met Wayland/labwc gebruiken;
- Chromium openen via `/usr/bin/chromium`;
- de presentatie in kioskmodus tonen;
- regelmatig terug navigeren naar de basis-URL van de Google Slides-presentatie;
- verborgen of gewijzigde dia's correct verwerken;
- RAM- en swapgebruik compact loggen;
- automatisch controleren of kiosk, Chromium en debugpoort gezond zijn;
- zonder F5, Ctrl+R, Ctrl+L of gesimuleerde toetsen blijven werken;
- veilig opnieuw geinstalleerd of bijgewerkt kunnen worden.

## Referentieomgeving

De huidige referentieomgeving is:

- Raspberry Pi 3B+ of Raspberry Pi 4;
- Raspberry Pi OS 64-bit Trixie met Desktop;
- Wayland;
- labwc als compositor;
- LightDM;
- NetworkManager;
- systemd-user-services;
- Bash;
- Python 3;
- Chromium via `/usr/bin/chromium`.

Andere Raspberry Pi-modellen kunnen werken, maar moeten apart getest worden.

## Technische Beslissingen

### Wayland En labwc

Raspberry Pi OS Trixie gebruikt standaard Wayland/labwc. Daarom gebruikt de kiosk geen oude X11-aanpak.

Niet gebruiken in uitvoerende scripts:

```text
DISPLAY=:0
export DISPLAY
xdotool
chromium-browser
```

### Chromium

Chromium wordt gestart met onder andere:

```text
--ozone-platform=wayland
--disable-gpu
--password-store=basic
--kiosk
--no-first-run
--disable-session-crashed-bubble
--remote-debugging-address=127.0.0.1
--remote-debugging-port=9222
```

De debugpoort is alleen lokaal bereikbaar op `127.0.0.1`.

### Google Slides Refresh

Een gewone refresh met F5 of Ctrl+R is onvoldoende. Google Slides voegt tijdens het afspelen vaak `&slide=id...` toe aan de URL.

Daarom gebruikt het project Chrome DevTools Protocol:

1. Chromium luistert lokaal op poort `9222`.
2. `refresh-presentation.py` vraagt de actieve targets op via `/json`.
3. Het script zoekt bij voorkeur het Google Slides-tabblad.
4. Het stuurt `Page.navigate` naar exact `PRESENTATION_URL`.

Google Slides speelt zelf door en gebruikt `loop=true`. De refresh is dus geen
afspeelmechanisme, maar haalt periodiek wijzigingen aan de online presentatie
op.

### systemd User-Services

De kiosk draait als gewone kioskgebruiker, niet als root.

Deze units horen onder `~/.config/systemd/user/`:

```text
digitalsignage-kiosk.service
digitalsignage-refresh.service
digitalsignage-refresh.timer
digitalsignage-resource-log.service
digitalsignage-resource-log.timer
digitalsignage-health.service
digitalsignage-health.timer
```

Er hoort geen `User=`-regel in deze user-units te staan.

### Statusmap En Logging

De presentatie-refresh en resource-logging zijn gescheiden. De refreshtimer
navigeert de presentatie standaard iedere vijf minuten terug naar
`PRESENTATION_URL`. De resource-logtimer schrijft iedere 10 minuten RAM- en
swapgebruik naar:

```text
~/.local/state/digitalsignage/swap.log
```

Logregels ouder dan 3 dagen worden automatisch verwijderd.

`digitalsignage-health.timer` draait standaard iedere minuut. De health-check
controleert de kioskservice, het door systemd gemelde Chromium-hoofdproces,
de lokale DevTools-poort `127.0.0.1:9222` en het Chromium-paginatarget. Een
tijdelijke fout telt mee, maar veroorzaakt nog geen herstelactie. Standaard
wordt de kioskservice pas na drie opeenvolgende fouten herstart. Na een
automatische restart geldt tien minuten cooldown en 90 seconden startup-grace.
De volledige Raspberry Pi wordt nooit automatisch herstart.

Health-state en health-log staan in:

```text
~/.local/state/digitalsignage/health-state.json
~/.local/state/digitalsignage/health.log
```

De installer en upgrader maken deze map vooraf aan op basis van `KIOSK_USER` en `getent passwd`. Hardcoded homefolders zoals `/home/pi` of `/home/bloemkool` zijn niet toegestaan.

## Testframework

Het project bevat automatische tests:

```text
tests/test-library.sh
tests/pre-install-test.sh
tests/post-install-test.sh
tests/run-tests.sh
```

Gebruik:

```bash
bash tests/run-tests.sh pre
sudo bash install/install.sh
sudo bash tests/run-tests.sh post
```

De pre-installatietest draait zonder `sudo`, zodat `systemd-analyze --user`
de user-units in de echte gebruikersomgeving controleert.

Logs komen terecht in:

```text
test-logs/
```

Wanneer die map niet schrijfbaar is voor de gewone gebruiker, herstel je dat
met:

```bash
sudo chown -R "$USER":"$(id -gn)" test-logs
```

Python-cachebestanden horen niet in Git. `.gitignore` sluit `__pycache__/` en
`*.py[cod]` uit.

Resultaatcategorieen:

- `OK`: test geslaagd;
- `WAARSCHUWING`: aandachtspunt;
- `FOUT`: installatie of werking is niet betrouwbaar;
- `OVERGESLAGEN`: test kon niet zinvol uitgevoerd worden.

## Acceptatiecriteria

Een installatie is pas klaar voor gebruik wanneer:

- de pre-installatietest zonder fouten eindigt;
- de installer zonder fouten eindigt;
- de post-installatietest zonder fouten eindigt;
- een volledige reboot succesvol getest is;
- Chromium automatisch opent;
- de presentatie correct geladen wordt;
- refresh via DevTools werkt;
- `swap.log` iedere 10 minuten wordt bijgewerkt;
- `digitalsignage-health.timer` actief is;
- een gezonde kiosk `health=ok action=none` logt;
- geen geheimen in Git staan;
- geen hardcoded homefolder gebruikt wordt.
