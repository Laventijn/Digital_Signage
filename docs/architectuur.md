# Architectuur

## Componenten

- `digitalsignage-kiosk.service`: start Chromium in kioskmodus.
- `digitalsignage-healthcheck.timer`: voert periodieke controles uit.
- `health-check.sh`: controleert netwerk en kioskproces.
- `web/offline/`: lokale fallbackpagina.

## Configuratieflow

1. Configuratie wordt gelezen uit `/etc/digitalsignage/digitalsignage.conf`.
2. `start-kiosk.sh` opent de ingestelde URL.
3. Bij problemen kan de offlinepagina gebruikt worden.
