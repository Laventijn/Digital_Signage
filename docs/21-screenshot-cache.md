# Lokale screenshotcache

De kiosk kan offline de laatst succesvol opgenomen inhoud tonen zonder Google-account, Google API, OAuth of serviceaccountbestand.

## Modus kiezen

Open `/etc/digitalsignage/digitalsignage.conf`.

Gebruik voor een Google Slides-presentatie:

```ini
CONTENT_MODE="presentation"
CONTENT_URL="https://docs.google.com/presentation/d/.../present?start=true&loop=true&delayms=5000"
```

Gebruik voor een gewone website:

```ini
CONTENT_MODE="website"
CONTENT_URL="https://voorbeeld.school/dashboard"
```

`PRESENTATION_URL` blijft voorlopig bestaan voor oudere installaties. Wanneer `CONTENT_URL` leeg is, gebruikt de kiosk automatisch `PRESENTATION_URL`.

## Hoe de opname werkt

De actieve kiosk gebruikt Chromium met DevTools-poort `9222`. De screenshotcache gebruikt een aparte headless Chromium met standaardpoort `9333`, een eigen tijdelijk profiel en een eigen cachemap. De opname bestuurt de actieve kioskbrowser niet.

De cache staat in:

```bash
~/.local/share/digitalsignage/screenshot-cache/
```

De log staat in:

```bash
~/.local/state/digitalsignage/screenshot-cache.log
```

## Handmatig starten

Voer dit uit als kioskgebruiker:

```bash
systemctl --user stop digitalsignage-screenshot-cache.timer
systemctl --user start digitalsignage-screenshot-cache.service
systemctl --user status digitalsignage-screenshot-cache.service
tail -50 ~/.local/state/digitalsignage/screenshot-cache.log
systemctl --user start digitalsignage-screenshot-cache.timer
```

Gebruik `Ctrl+C` niet als stopmechanisme voor een lopende user-service. Stop een lopende opname gecontroleerd met:

```bash
systemctl --user stop digitalsignage-screenshot-cache.service
```

Bij zo'n bewuste annulering ruimt het script de tijdelijke werkmap, het lockbestand en het eigen headless Chromium-proces op. De bestaande actieve cache blijft behouden.

## Offline gedrag

Bij bevestigd netwerkverlies controleert de health-check eerst of `current/index.html` en `manifest.json` geldig zijn. Is de cache geldig, dan navigeert Chromium naar de lokale speler. Is de cache ongeldig of ontbreekt ze, dan blijft de bestaande algemene offlinepagina de fallback.

In presentatiemodus toont de lokale speler de opgeslagen PNG's als slideshow. Verborgen dia's worden niet via een API gelezen; alleen wat de echte presentatiemodus tijdens normaal afspelen toont, kan worden opgenomen.

In websitemodus bewaart de cache exact een laatste screenshot. Er wordt geen slideshow van oude websitebeelden gemaakt.

## Watermerk

Iedere definitieve offlineafbeelding krijgt rechtsonder het watermerk uit `OFFLINE_WATERMARK_TEXT`, standaard `Offline modus`. Het watermerk wordt alleen in de aparte opnamebrowser toegevoegd en zit in de opgeslagen PNG.

## Beperkingen

Video, animaties en interactieve dashboards worden als stilstaand beeld opgeslagen. Een online URL moet zonder extra login zichtbaar zijn voor Chromium op de Pi.

De screenshotservice heeft een vaste systemd-bovengrens van 20 minuten. De scriptconfiguratie `SCREENSHOT_MAX_CAPTURE_SECONDS` blijft de normale inhoudelijke capturelimiet; systemd voorkomt daarnaast dat de service onbeperkt in `activating` blijft hangen.

## Cache verwijderen

Stop eerst de timer:

```bash
systemctl --user stop digitalsignage-screenshot-cache.timer
```

Verwijder daarna desgewenst de cache:

```bash
rm -rf ~/.local/share/digitalsignage/screenshot-cache
```
