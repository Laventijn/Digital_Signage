# Changelog

Alle noemenswaardige wijzigingen aan dit project worden hier bijgehouden.

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
- Healthtimer aangepast naar `OnUnitInactiveSec` met drop-in-reset van oude `OnUnitActiveSec`, en desktopachtergrond wordt waar mogelijk direct via actieve PCManFM toegepast.
