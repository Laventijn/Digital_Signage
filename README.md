# VS Digital Signage

Project voor het installeren en beheren van een eenvoudige Digital Signage kiosk op een Linux-toestel, typisch een Raspberry Pi of mini-pc.

## Inhoud

- Documentatie staat in `docs/`.
- Installatie- en beheerscripts staan in `install/` en `scripts/`.
- Systemd servicebestanden staan in `services/`.
- Voorbeeldconfiguratie staat in `config/`.
- Offline fallbackpagina staat in `web/offline/`.

## Snelle start

1. Kopieer `config/digitalsignage.conf.example` naar `/etc/digitalsignage/digitalsignage.conf`.
2. Pas de URL en kiosk-instellingen aan.
3. Voer de installatie uit:

```bash
sudo bash install/install.sh
```

## Documentatie

Begin met [docs/01-projectoverzicht.md](docs/01-projectoverzicht.md).
