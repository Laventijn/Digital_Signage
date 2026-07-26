# Architectuur

## Componenten

- `digitalsignage-kiosk.service`: start Chromium in kioskmodus.
- `digitalsignage-refresh.timer`: vernieuwt de presentatie via Chrome DevTools Protocol.
- `digitalsignage-resource-log.timer`: logt RAM- en swapgebruik iedere 10 minuten.
- `digitalsignage-health.timer`: controleert kiosk, Chromium MainPID, debugpoort en paginatarget.
- `health-check.py`: herstart alleen de kioskservice na meerdere opeenvolgende fouten en respecteert cooldown.
- `web/offline/`: lokale fallbackpagina.

## Configuratieflow

1. Configuratie wordt gelezen uit `/etc/digitalsignage/digitalsignage.conf`.
2. `start-kiosk.sh` opent de ingestelde URL.
3. `refresh-presentation.py` navigeert het bestaande tabblad terug naar `PRESENTATION_URL`.
4. `log-resources.py` schrijft naar `~/.local/state/digitalsignage/swap.log`.
5. `health-check.py` schrijft naar `~/.local/state/digitalsignage/health.log` en `health-state.json`.
