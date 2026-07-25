# Problemen Oplossen

## Kiosk start niet

```bash
systemctl status digitalsignage-kiosk.service
journalctl -u digitalsignage-kiosk.service -n 100
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
