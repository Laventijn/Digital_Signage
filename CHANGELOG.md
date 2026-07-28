# Changelog

Alle noemenswaardige wijzigingen aan dit project worden hier bijgehouden.

## Fase 3.1

- Accountvrije lokale screenshotcache toegevoegd voor `presentation` en `website`.
- `CONTENT_MODE` en `CONTENT_URL` toegevoegd; `PRESENTATION_URL` blijft fallback voor bestaande installaties.
- Aparte headless Chromium-opname via `digitalsignage-screenshot-cache.service` en timer toegevoegd.
- Health-check toont bij offline eerst een geldige screenshotcache en anders de bestaande offlinepagina.
- Presentatieopname robuuster gemaakt met poll-gebaseerde diawisseling, raw/stored hashes, deadlinebewaking, lockcleanup en publicatie zonder Chromium-profieldata.
- Pi-hertestfix: instabiele A/B-samples worden opnieuw geprobeerd in plaats van als technische fout te falen, capturelogs tonen echte duur en extra diagnostiek, en screenshotcache-timers resetten oude intervalinstellingen.
- Screenshotcache ontkoppeld van de gewone presentatierefresh; alleen de screenshotcachetimer of een expliciete beheerstart activeert nog een capture.
- Slide-ID-wijzigingen wachten nu op een werkelijk nieuw raw frame; onbetrouwbare 1-slidepublicatie wordt geweigerd wanneer meerdere slide-ID's gezien zijn.
- Screenshotstabiliteit vergelijkt gedecodeerde RGB-pixels en kan tijdelijk begrensde A/B-debugbeelden bewaren met `SCREENSHOT_DEBUG_STABILITY=true`.
- A/B-stabiliteitsmetingen nemen geen lange URL- of renderwachten meer tussen screenshot A en B op en loggen afzonderlijke timingvelden.
- Documentatie toegevoegd in `docs/21-screenshot-cache.md`.

## 0.1.0

- Initiële projectstructuur toegevoegd.
- Basisdocumentatie, scripts, services, configuratievoorbeeld en tests toegevoegd.
- Configuratienaamgeving genormaliseerd naar `PRESENTATION_URL` en `REFRESH_SECONDS`.
- Kioskservice-gebruiker aangepast naar `bloemkool`.
- Permanent Google Slides-refreshmechanisme via Chrome DevTools Protocol toegevoegd.
- Compacte RAM- en swaplogging toegevoegd.
- RAM- en swaplogging losgekoppeld van presentatie-refresh: refresh blijft frequent, resource-logging draait iedere 10 minuten en bewaart 3 dagen.
- User-level systemd service en timer voor presentatie-refresh toegevoegd.
- Kioskstart gecorrigeerd naar Wayland/labwc met `/usr/bin/chromium` als systemd user-service.
- Chromium-profiel en cache gescheiden en cachebegrenzing via `CACHE_SIZE_MB` toegevoegd.
- Oude refreshscript omgezet naar compatibiliteitswrapper voor `refresh-presentation.py`.
- Ontbrekende gebruikersstatusmap voor `swap.log` opgelost, inclusief de systemd-fout `226/NAMESPACE`.
- Geautomatiseerd pre- en post-installatietestframework toegevoegd met logging onder `test-logs/`.
- Pre-installatietest gecorrigeerd voor systemd-user-verificatie zonder `sudo` en installatie van scripts met modus `0755`.
- Upgrade vult ontbrekende configuratievariabelen idempotent aan en post-installatietests corrigeren Chromium-, oneshot- en user-journalcontroles.
- Standaard Google Slides-presentatie-URL aangepast naar `loop=true`.
- Fase 2-stabiliteitswerk gestart: Python-cache uit Git, testlogrechten gecontroleerd, user-journalfallback toegevoegd en standaard presentatie-refresh naar vijf minuten verlaagd.
- Losse documentatienotities samengevoegd in de genummerde documentatie.
- Fase 2B toegevoegd: automatische user-level health-check met failure threshold, startup-grace, restart-cooldown, `health.log` en `health-state.json`.
- Fase 2C toegevoegd: vaste Digital Signage-desktopachtergrond via pcmanfm-configuratie, inclusief installatie-, upgrade-, uninstall- en testdekking.
- Healthtimer aangepast naar `OnActiveSec` plus `OnUnitInactiveSec`, en desktopachtergrond wordt waar mogelijk direct via actieve PCManFM toegepast.
- Fase 3 toegevoegd: connectiviteitsdetectie via NetworkManager en HTTP-controle, gevalideerde `connectivity.state`, lokale offlinepagina onder `/opt/digitalsignage/offline/` en automatisch herstel naar de kiosk-URL na stabiel netwerkherstel.
