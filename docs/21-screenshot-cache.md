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

`digitalsignage-refresh.timer` en `digitalsignage-screenshot-cache.timer` hebben een verschillend doel:

* `digitalsignage-refresh.timer` vernieuwt alleen de actieve kioskpagina via DevTools op poort `9222`;
* `digitalsignage-screenshot-cache.timer` start periodiek de offline-cacheopname via de aparte service en poort `9333`;
* `REFRESH_SECONDS` bepaalt de gewone presentatie-refresh;
* `SCREENSHOT_CACHE_REFRESH_SECONDS` bepaalt het interval voor de offline screenshotcache.

Een mislukte screenshotcapture mag de gewone presentatierefresh niet blokkeren of opnieuw starten. De normale periodieke capture-start komt alleen van `digitalsignage-screenshot-cache.timer`, niet van `refresh-presentation.py`.

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
systemctl --user stop digitalsignage-screenshot-cache.service
systemctl --user start digitalsignage-screenshot-cache.service
systemctl --user status digitalsignage-screenshot-cache.service
tail -50 ~/.local/state/digitalsignage/screenshot-cache.log
systemctl --user start digitalsignage-screenshot-cache.timer
```

Gebruik `Ctrl+C` niet als stopmechanisme voor een lopende user-service. Stop een lopende opname gecontroleerd met:

```bash
systemctl --user stop digitalsignage-screenshot-cache.service
```

Bij zo'n bewuste annulering ruimt het script de tijdelijke werkmap, het lockbestand en het eigen headless Chromium-proces op. De bestaande actieve cache blijft behouden. Als Chromium nog kort bestanden vasthoudt, probeert de cleanup de werkmap begrensd opnieuw te verwijderen; een al verdwenen werkmap wordt niet als waarschuwing gelogd.

Voor een Pi-hertest zonder timerinterferentie:

```bash
systemctl --user stop digitalsignage-screenshot-cache.timer
systemctl --user reset-failed digitalsignage-screenshot-cache.service
systemctl --user start digitalsignage-screenshot-cache.service
journalctl --user -u digitalsignage-screenshot-cache.service -n 80 --no-pager
tail -80 ~/.local/state/digitalsignage/screenshot-cache.log
systemctl --user list-timers digitalsignage-screenshot-cache.timer
systemctl --user start digitalsignage-screenshot-cache.timer
```

Een melding `active_capture_lock` betekent dat er al een opname loopt. De service start dan geen tweede Chromium en eindigt normaal. Bij instabiele dia-overgangen staan de eerste diagnostische pogingen in `screenshot-cache.log` met `candidate=unstable`; dat is geen technische fout en bewaart de bestaande cache tot er een stabiele dia is. Tijdelijke DevTools-timeouts bij het lezen van de slide-ID worden als onbekende slide-ID behandeld en mogen geen rauwe `Connection timed out` als eindreden geven. Een bijna leeg donker overgangsbeeld wordt apart gelogd met `phase=transition_or_blank_frame` en `candidate=transition_or_blank`.

Wanneer Google Slides de `slide=`-URL al wijzigt maar Chromium nog het vorige beeld teruggeeft, wacht de capture op een werkelijk veranderde raw screenshot voordat een nieuwe dia stabiel kan worden geaccepteerd. Zodra meerdere niet-lege slide-ID's gezien zijn, wordt een 1-slidecache niet meer als `single_slide_confirmed` gepubliceerd; bij een onvolledige ronde blijft de bestaande cache behouden.

Voor een gerichte Pi-debugtest kan tijdelijk extra A/B-diagnostiek worden ingeschakeld:

```ini
SCREENSHOT_DEBUG_STABILITY=true
```

Zet deze waarde na de test opnieuw op `false`. Bij mislukte stabiliteitsparen bewaart de lopende opname maximaal vijf paren onder de tijdelijke werkmap `~/.local/share/digitalsignage/screenshot-cache/work/capture-*/debug/`, bijvoorbeeld `stability-001-a.png` en `stability-001-b.png`. Deze beelden worden niet naar `versions/current` gepubliceerd en verdwijnen bij normale cleanup.

Een stabiliteitspaar wordt als korte A/B-operatie genomen: slide-ID A lezen, screenshot A nemen, alleen de ingestelde stable gap wachten, slide-ID B lezen en screenshot B nemen. De log vermeldt onder meer `configured_stable_gap_ms`, `actual_sleep_ms`, `actual_stable_gap_ms`, `capture_a_duration_ms`, `capture_b_duration_ms` en eventuele `slow_operation`. Voor trage screenshots staan daarnaast per A/B-screenshot aparte velden voor `cdp_capture_wait_ms`, `base64_decode_ms`, `png_decode_ms`, `debug_write_ms` en `total_capture_ms`.

## Pi-controle: refresh start geen capture

Met deze controle bewijs je dat de gewone refreshtimer actief blijft zonder screenshotcapture te starten:

```bash
systemctl --user stop digitalsignage-screenshot-cache.timer
systemctl --user disable digitalsignage-screenshot-cache.timer
systemctl --user stop digitalsignage-screenshot-cache.service
systemctl --user start digitalsignage-refresh.timer

systemctl --user show digitalsignage-screenshot-cache.service \
  --property=InvocationID \
  --property=ActiveState \
  --property=ExecMainStartTimestamp
tail -1 ~/.local/state/digitalsignage/screenshot-cache.log
ss -ltnp | grep ':9333' || true
```

Wacht minstens twee gewone refreshcycli en voer dezelfde drie controles opnieuw uit. `InvocationID`, `ExecMainStartTimestamp` en de laatste `cache=running`-logregel mogen niet gewijzigd zijn. Poort `9333` mag niet verschijnen. De kioskrefresh zelf controleer je apart met:

```bash
systemctl --user status digitalsignage-refresh.service
journalctl --user -u digitalsignage-refresh.service -n 50 --no-pager
```

Verwijder `~/.local/state/digitalsignage/screenshot-cache.lock` nooit handmatig terwijl `digitalsignage-screenshot-cache.service` `activating` of `active` is, of terwijl poort `9333` actief is. Een lock mag alleen als stale lock verwijderd worden nadat de screenshotcachetimer gestopt is, de service gestopt is, geen capture-Chromium meer draait en geen `capture-content-cache.py`-proces meer actief is.

Een verdwenen tijdelijke werkmap na succesvolle publicatie is normaal: de publicatiestap verplaatst en ruimt die map al op. Alleen andere cleanupfouten worden nog als `cleanup_warning` gelogd.

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
