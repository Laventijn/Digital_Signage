# Vereisten

Dit document beschrijft wat nodig is voor een installatie van VS Digital Signage op Raspberry Pi OS Trixie.

## Hardware

Minimaal:

- Raspberry Pi 3B+ of Raspberry Pi 4;
- geschikte voeding;
- monitor via HDMI;
- SD-kaart of SSD;
- netwerkverbinding via ethernet of wifi;
- toetsenbord voor noodgevallen.

Voor een Raspberry Pi 3B+ is een goede SD-kaart normaal voldoende. Een SSD kan ook gebruikt worden wanneer het gekozen model en de bootconfiguratie dit ondersteunen.

## Software

Benodigd op de Raspberry Pi:

- Raspberry Pi OS 64-bit Trixie met Desktop;
- Wayland/labwc;
- LightDM;
- NetworkManager;
- Bash;
- Python 3;
- systemd;
- systemd-user-services;
- Chromium via `/usr/bin/chromium`;
- Debian-pakket `python3-websocket`.

## Benodigde Commando's

De automatische pre-installatietest controleert minstens:

```text
bash
python3
systemctl
systemd-analyze
grep
find
getent
install
curl
git
/usr/bin/chromium
```

## Aanbevolen Raspberry Pi Imager-Instellingen

Gebruik Raspberry Pi Imager op Windows en kies:

1. het juiste Raspberry Pi-model;
2. Raspberry Pi OS 64-bit met desktop;
3. de juiste SD-kaart of SSD.

Stel in de geavanceerde opties in:

```text
Hostname: bijvoorbeeld signage-01
Gebruikersnaam: volgens de gewenste kioskgebruiker
Tijdzone: Europe/Brussels
Toetsenbord: Belgisch of de gewenste indeling
Wi-Fi-land: BE
SSH: ingeschakeld wanneer beheer op afstand nodig is
SSH-authenticatie: wachtwoord of eigen SSH-sleutel
```

Gebruik een sterk wachtwoord en bewaar het veilig. Plaats nooit wachtwoorden of Wi-Fi-sleutels in Git.

## Eerste Systeemcontrole

Na de eerste start:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

Controleer na de herstart:

```bash
systemctl --failed
command -v labwc
pgrep -a labwc
command -v chromium
nmcli device status
free -h
df -h /
```

Verwacht:

- geen gefaalde services;
- `/usr/bin/labwc`;
- een actief labwc-proces;
- `/usr/bin/chromium`;
- een verbonden netwerkinterface;
- minstens 300 MiB beschikbaar RAM;
- minstens 1 GiB vrije ruimte op `/`.

## Veilig Omgaan Met Ongebruikte Services

Schakel alleen services uit wanneer ze niet gebruikt worden. Verwijder geen pakketten zonder afhankelijkheidscontrole.

Voorbeeld van optioneel uitschakelen:

```bash
sudo systemctl disable --now bluetooth.service
sudo systemctl disable --now nfs-blkmap.service
sudo systemctl disable --now rpcbind.service rpcbind.socket
```

Niet doen als standaardoptimalisatie:

```bash
sudo apt purge bluez
sudo apt purge rpcbind
sudo apt autoremove
```

Deze commando's kunnen belangrijke desktoponderdelen zoals labwc of Raspberry Pi desktopcomponenten meenemen.
