# Kiosk-installatie

De kiosk wordt geïnstalleerd met:

```bash
sudo bash install/install.sh
```

De installer kopieert scripts, webbestanden, configuratie en systemd-units naar de juiste locaties.

Na installatie:

```bash
sudo systemctl enable --now digitalsignage-kiosk.service
sudo systemctl enable --now digitalsignage-healthcheck.timer
```
