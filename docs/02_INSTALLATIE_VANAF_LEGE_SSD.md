# Installatie Vanaf Lege SSD

De actuele installatieprocedure staat in `docs/03-os-installatie.md`.

Gebruik voor Fase 2B:

```bash
sudo bash tests/run-tests.sh pre
sudo bash install/upgrade.sh
sudo bash tests/run-tests.sh post
```

Na installatie controleer je de health-check met:

```bash
systemctl --user status digitalsignage-health.timer --no-pager
systemctl --user list-timers --all | grep digitalsignage
tail -20 ~/.local/state/digitalsignage/health.log
cat ~/.local/state/digitalsignage/health-state.json
journalctl --user -u digitalsignage-health.service -n 50 --no-pager
```
