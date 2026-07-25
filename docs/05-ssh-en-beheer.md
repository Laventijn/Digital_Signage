# SSH En Beheer

Activeer SSH alleen wanneer beheer op afstand nodig is.

## Aanbevolen

- Gebruik sterke wachtwoorden of SSH-sleutels.
- Beperk beheeraccounts.
- Documenteer hostname, IP-adres en locatie van het toestel.

## Handige commando's

```bash
hostname -I
systemctl status digitalsignage-kiosk.service
journalctl -u digitalsignage-kiosk.service -f
```
