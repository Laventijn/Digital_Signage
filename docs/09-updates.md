# Updates

Update de installatie met:

```bash
bash tests/run-tests.sh pre
sudo bash install/upgrade.sh
sudo bash tests/run-tests.sh post
```

De pre-installatietest draait zonder `sudo`, omdat de systemd-user-units in de
gebruikersomgeving gecontroleerd worden.

Herstart daarna de kioskservice als kioskgebruiker:

```bash
systemctl --user restart digitalsignage-kiosk.service
```

Een upgrade vult ontbrekende configuratiewaarden, zoals `REFRESH_SECONDS=300`,
`RESOURCE_LOG_RETENTION_DAYS=3` en de offlinevelden, idempotent aan. Bestaande
aangepaste waarden worden niet overschreven.

Nieuwe offlinebestanden worden bij elke upgrade bijgewerkt:

```bash
/opt/digitalsignage/offline/index.html
/opt/digitalsignage/offline/offline.css
```

Ook de desktopachtergrond wordt bij een upgrade idempotent bijgewerkt. Nieuwe
installaties krijgen standaard:

```ini
DESKTOP_BACKGROUND_ENABLED=true
DESKTOP_BACKGROUND_FILE="/opt/digitalsignage/assets/wallpapers/digitalsignage-background.png"
DESKTOP_BACKGROUND_MODE=zoom
```

Een bestaande pcmanfm-configuratie van de kioskgebruiker wordt eerst geback-upt
naast het originele bestand als `desktop-items-0.conf.backup.*`. De actieve
desktop wordt niet geforceerd herstart.
