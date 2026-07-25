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

Een upgrade vult ontbrekende configuratiewaarden, zoals `REFRESH_SECONDS=300`
en `RESOURCE_LOG_RETENTION_DAYS=3`, idempotent aan. Bestaande aangepaste waarden
worden niet overschreven.
