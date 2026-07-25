# OS-installatie

Dit document beschrijft de installatie vanaf een lege SD-kaart of SSD.

## 1. Raspberry Pi OS Schrijven

Open Raspberry Pi Imager op Windows.

Kies:

1. het juiste Raspberry Pi-model;
2. Raspberry Pi OS 64-bit met Desktop;
3. de juiste SD-kaart of SSD.

Gebruik de geavanceerde opties om hostname, gebruiker, tijdzone, toetsenbord, wifi-land en SSH in te stellen. Gebruik geen wachtwoorden of Wi-Fi-sleutels in deze repository.

## 2. Eerste Start

Plaats de SD-kaart of SSD in de Raspberry Pi en start het toestel.

Wacht tot de desktop volledig geladen is.

Verbind daarna via SSH, bijvoorbeeld:

```bash
ssh gebruiker@signage-01.local
```

Wanneer Windows meldt dat de SSH-hostsleutel veranderd is na een nieuwe image:

```bash
ssh-keygen -R signage-01.local
```

## 3. Besturingssysteem Bijwerken

Voer op de Raspberry Pi uit:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

Verbind na de herstart opnieuw via SSH.

Controleer:

```bash
systemctl --failed
command -v labwc
pgrep -a labwc
command -v chromium
nmcli device status
free -h
df -h /
```

## 4. Repository Klonen

Ga naar de homefolder:

```bash
cd ~
```

Kloon de repository:

```bash
git clone https://github.com/Laventijn/Digital_Signage.git ~/DigitalSignage
cd ~/DigitalSignage
```

Controleer:

```bash
git status
git log --oneline -3
ls
```

Verwachte hoofdmappen:

```text
config/
docs/
install/
scripts/
services/
tests/
web/
```

## 5. Pre-installatietest

Voer uit vanuit de repository-root:

```bash
bash tests/run-tests.sh pre
```

De test controleert onder andere:

- systeemvereisten;
- benodigde commando's;
- repositorystructuur;
- Bash- en Python-syntaxis;
- systemd-units;
- verboden hardcoded paden;
- configuratievariabelen;
- statusmapoplossing.

Installeer niet wanneer de test met fouten eindigt. Waarschuwingen moeten beoordeeld worden.
Gebruik voor deze pre-installatietest geen `sudo`: de test controleert
systemd-user-units in de gebruikersomgeving. Wanneer de test toch met `sudo`
wordt gestart, schakelt `tests/run-tests.sh` terug naar de oorspronkelijke
gebruiker uit `SUDO_USER`.

## 6. Installatie Uitvoeren

Voer uit:

```bash
sudo bash install/install.sh
```

De installer hoort onder andere:

- benodigde pakketten te installeren;
- projectbestanden naar `/opt/digitalsignage` te kopieren;
- configuratie onder `/etc/digitalsignage` te plaatsen;
- de kioskgebruiker uit `KIOSK_USER` te bepalen;
- de homefolder via `getent passwd` te bepalen;
- de statusmap aan te maken;
- systemd-user-units te installeren;
- kioskservice, refreshtimer en resource-logtimer te activeren wanneer een usersessie actief is.

De installer mag geen hardcoded homefolder gebruiken.

## 7. Actieve Configuratie Controleren

Bekijk:

```bash
sudo cat /etc/digitalsignage/digitalsignage.conf
```

Pas eventueel aan met:

```bash
sudo nano /etc/digitalsignage/digitalsignage.conf
```

Controleer minimaal:

```ini
PRESENTATION_URL="https://docs.google.com/presentation/.../present?start=true&loop=true&delayms=5000"
CHROMIUM_BIN="/usr/bin/chromium"
WAYLAND_DISPLAY="wayland-0"
REMOTE_DEBUG_HOST="127.0.0.1"
REMOTE_DEBUG_PORT=9222
CACHE_SIZE_MB=100
KIOSK_USER="bloemkool"
```

Na een configuratiewijziging:

```bash
systemctl --user restart digitalsignage-kiosk.service
```

## 8. Post-installatietest

Voer uit:

```bash
sudo bash tests/run-tests.sh post
```

De test controleert onder andere:

- installatiepaden;
- configuratie;
- statusmap;
- eigenaar en rechten;
- kioskservice;
- refreshtimer;
- resource-logtimer;
- Chromium-opdrachtregel;
- debugpoort `9222`;
- handmatige refresh;
- resource-log;
- namespacefouten;
- RAM, swap en schijfruimte.

Een succesvolle oneshot-refreshservice mag na uitvoering `inactive (dead)` zijn. De laatste uitvoering moet wel succesvol zijn.

Niet toegestaan:

```text
226/NAMESPACE
Failed to set up mount namespacing
No such file or directory
```

## 9. Handmatige Controles

Kioskservice:

```bash
systemctl --user status digitalsignage-kiosk.service --no-pager -l
```

Refreshtimer:

```bash
systemctl --user status digitalsignage-refresh.timer --no-pager
systemctl --user list-timers --all | grep digitalsignage
```

Chromium:

```bash
pgrep -a chromium | head
```

Debugpoort:

```bash
curl -s http://127.0.0.1:9222/json | grep -E '"type"|"url"|"webSocketDebuggerUrl"'
```

Resource-log:

```bash
systemctl --user status digitalsignage-resource-log.timer --no-pager
tail -10 ~/.local/state/digitalsignage/swap.log
```

## 10. Definitieve Reboottest

Herstart:

```bash
sudo reboot
```

Controleer na de reboot:

- Chromium opent automatisch;
- Google Slides verschijnt;
- kioskmodus is actief;
- kioskservice is actief;
- refreshtimer is actief;
- `swap.log` krijgt iedere 10 minuten nieuwe resource-logregels;
- er zijn geen gefaalde Digital Signage-services.

Aanvullende commando's:

```bash
systemctl --failed
systemctl --user status digitalsignage-kiosk.service --no-pager
systemctl --user status digitalsignage-refresh.timer --no-pager
systemctl --user status digitalsignage-resource-log.timer --no-pager
journalctl --user -u digitalsignage-refresh.service -n 20 --no-pager
journalctl --user -u digitalsignage-resource-log.service -n 20 --no-pager
tail -5 ~/.local/state/digitalsignage/swap.log
free -h
df -h /
```

## 11. Bij Problemen

Bewaar de logbestanden uit:

```text
test-logs/
```

Aanvullende logs:

```bash
journalctl --user -u digitalsignage-kiosk.service -n 50 --no-pager
journalctl --user -u digitalsignage-refresh.service -n 50 --no-pager
journalctl --user -u digitalsignage-refresh.timer -n 50 --no-pager
journalctl --user -u digitalsignage-resource-log.service -n 50 --no-pager
journalctl --user -u digitalsignage-resource-log.timer -n 50 --no-pager
systemctl --failed
```

Verwijder geen pakketten als snelle oplossing. Controleer eerst de foutmelding en afhankelijkheden.
