# AGENTS.md

Richtlijnen voor Codex, andere agents en ontwikkelaars die aan deze repository werken.

## 1. Projectdoel

Dit project bouwt een stabiele en eenvoudig beheerbare Digital Signage-kiosk voor Raspberry Pi.

De kiosk:

* draait op Raspberry Pi OS 64-bit Trixie;
* gebruikt Chromium in kioskmodus;
* toont voornamelijk een Google Slides-presentatie;
* vernieuwt de presentatie standaard iedere 30 seconden;
* moet automatisch herstellen na een Chromium-crash;
* moet netwerk- en IP-informatie duidelijk kunnen tonen;
* moet later eenvoudig door een ICT-medewerker beheerd kunnen worden.

## 2. Ondersteund platform

Primair doelplatform:

* Raspberry Pi 3B+
* Raspberry Pi 4
* Raspberry Pi OS 64-bit Trixie met Desktop
* systemd
* NetworkManager
* Wayland/labwc
* Bash

Gebruik geen oplossingen die uitsluitend afhankelijk zijn van:

* X11;
* LXDE-autostart;
* `xdotool`;
* handmatige wijzigingen aan `wpa_supplicant.conf`;
* verouderde Raspberry Pi OS-versies.

## 3. Algemene werkafspraken

* Maak kleine en controleerbare wijzigingen.
* Pas bestaande bestanden gericht aan.
* Vermijd brede refactors zonder duidelijke noodzaak.
* Leg eerst uit waarom een ingrijpende wijziging nodig is.
* Verwijder geen bestaande functionaliteit zonder expliciete toestemming.
* Verwijder of schakel geen systeemservice uit zonder expliciete toestemming.
* Maak geen aannames over actieve gebruikersnamen, netwerkinterfaces of installatiepaden.
* Gebruik duidelijke foutmeldingen en veilige standaardwaarden.
* Voeg duidelijke Nederlandstalige commentaren toe aan scripts en configuratiebestanden.
* Documenteer zichtbare wijzigingen in `CHANGELOG.md`.
* Werk relevante bestanden onder `docs/` bij wanneer de installatie of werking verandert.

## 4. Belangrijke beveiligingsregels

* Plaats nooit wachtwoorden in Git.
* Plaats nooit Wi-Fi-wachtwoorden in Git.
* Plaats nooit API-tokens, OAuth-bestanden, privésleutels of andere geheimen in Git.
* Voeg voorbeeldconfiguraties toe met fictieve waarden.
* Gebruik voor echte configuratie bestanden buiten de repository.
* Bewerk `/etc/sudoers` nooit rechtstreeks.
* Gebruik alleen afzonderlijke bestanden onder `/etc/sudoers.d/`.
* Geef scripts alleen de minimaal noodzakelijke sudo-rechten.
* Laat webprocessen nooit onbeperkt willekeurige shellcommando’s als root uitvoeren.

## 5. Netwerkregels

* Gebruik NetworkManager voor netwerkbeheer.
* Gebruik `nmcli` voor Wi-Fi-informatie en Wi-Fi-configuratie.
* Schrijf niet rechtstreeks naar `/etc/wpa_supplicant/wpa_supplicant.conf`.
* Ga niet automatisch uit van netwerkinterface `wlan0`.
* Zoek actieve interfaces dynamisch op.
* Gebruik bij voorkeur de hostname, bijvoorbeeld `signage-01.local`.
* Toon waar mogelijk zowel hostname als huidig IP-adres.
* Wijzig geen statisch IP-adres zonder expliciete toestemming.

## 6. Projectstructuur

Bronbestanden blijven in de Git-repository.

Belangrijke mappen:

* Configuratievoorbeelden: `config/`
* Installatiescripts: `install/`
* Uitvoerende scripts: `scripts/`
* systemd-units: `services/`
* Offline webpagina: `web/offline/`
* Documentatie: `docs/`
* Tests: `tests/`
* Windows-hulpmiddelen: `tools/windows/`

Geïnstalleerde locaties op de Raspberry Pi:

* Configuratie: `/etc/digitalsignage/`
* Hoofdconfiguratie: `/etc/digitalsignage/digitalsignage.conf`
* Programmabestanden: `/opt/digitalsignage/`
* Scripts: `/opt/digitalsignage/scripts/`
* Offlinepagina: `/opt/digitalsignage/web/offline/index.html`
* systemd-units: `/etc/systemd/system/`

Wijzig geïnstalleerde bestanden niet als primaire broncode. Wijzig eerst de repository en laat het installatie- of updatescript de bestanden installeren.

## 7. Configuratie

Instellingen die een ICT-medewerker mag aanpassen, horen in:

`/etc/digitalsignage/digitalsignage.conf`

Een voorbeeldbestand hoort in:

`config/digitalsignage.conf.example`

Gebruik geen geheime gegevens in het voorbeeldbestand.

Verwachte instellingen kunnen onder andere zijn:

```ini
PRESENTATION_URL=""
REFRESH_SECONDS=30
CACHE_SIZE_MB=100
HOSTNAME_LABEL="signage-01"
```

Valideer configuratiewaarden voordat ze worden gebruikt.

## 8. Shellscripts

Nieuwe Bash-scripts beginnen met:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
```

Aanvullende regels:

* Quote variabelen altijd waar nodig.
* Gebruik geen `eval`.
* Gebruik tijdelijke bestanden veilig met `mktemp`.
* Controleer vooraf of vereiste commando’s bestaan.
* Controleer of bestanden en mappen bestaan voordat ze worden gewijzigd.
* Geef bij fouten een duidelijke Nederlandstalige melding.
* Laat scripts met een niet-nul exitcode stoppen bij een echte fout.
* Zorg dat installatiescripts opnieuw uitgevoerd kunnen worden zonder schade.
* Hardcode geen gebruikersnaam zoals `pi`.
* Hardcode geen thuisdirectory.
* Hardcode geen Wi-Fi-interface.
* Gebruik absolute paden in systemd-gerelateerde scripts.

## 9. systemd

* Gebruik systemd voor achtergrondprocessen en geplande taken.
* Gebruik timers voor periodieke taken wanneer dat passend is.
* Maak geen extra service wanneer een bestaande service dezelfde taak al uitvoert.
* Controleer op dubbele refresh-, watchdog- of kioskmechanismen.
* Voeg herstartbeleid toe waar dat nodig is.
* Gebruik beperkte rechten waar mogelijk.
* Gebruik geen rootrechten wanneer die niet noodzakelijk zijn.
* Controleer iedere aangepaste unit met:

```bash
systemd-analyze verify services/*.service services/*.timer
```

Verwijder of disable geen bestaande systeemunit zonder expliciete toestemming.

## 10. Chromium

* Gebruik één afzonderlijke Chromium-profielmap voor de kiosk.
* Gebruik een afzonderlijke en begrensde cachemap.
* Verwijder niet automatisch het volledige Chromium-profiel.
* Bewaar gebruikersinstellingen en cache als afzonderlijke onderdelen.
* Gebruik geen meerdere parallelle watchdog- of refreshmechanismen.
* Herstart Chromium gecontroleerd wanneer dat nodig is.
* Zorg dat een mislukte Chromium-start zichtbaar in de logging verschijnt.

## 11. Testen

Voer voor afronding minimaal deze controles uit:

```bash
bash -n install/*.sh
find scripts -type f -name "*.sh" -print0 | xargs -0 -r -n1 bash -n
```

Wanneer ShellCheck beschikbaar is:

```bash
shellcheck install/*.sh
find scripts -type f -name "*.sh" -print0 | xargs -0 -r shellcheck
```

Voor systemd-units:

```bash
systemd-analyze verify services/*.service services/*.timer
```

Controleer daarnaast:

* of alle genoemde bestanden werkelijk bestaan;
* of alle paden onderling overeenkomen;
* of scripts geen oude gebruikersnaam gebruiken;
* of geen geheimen in de repository staan;
* of installatie en verwijdering elkaars wijzigingen correct spiegelen.

Wanneer een controle niet kan worden uitgevoerd, vermeld dat duidelijk in het eindverslag.

## 12. Documentatie

Werk minstens deze bestanden bij wanneer dat relevant is:

* `README.md`
* `CHANGELOG.md`
* `docs/02_Installatie.md`
* `docs/05_WiFi.md`
* `docs/06_Kiosk.md`
* `docs/08_Troubleshooting.md`

Documenteer opdrachten stap voor stap voor een ICT-medewerker die weinig Linux-ervaring heeft.

## 13. Werkwijze bij bestaande code

Voordat bestaande code wordt aangepast:

1. Inventariseer alle bestanden.
2. Beschrijf de huidige architectuur.
3. Zoek dubbele of overlappende functies.
4. Controleer installatiepaden.
5. Controleer systemd-units.
6. Controleer netwerkbeheer.
7. Controleer beveiligingsrisico’s.
8. Controleer op wachtwoorden, tokens en sleutels.
9. Voer beschikbare syntaxiscontroles uit.
10. Maak eerst een rapport met voorgestelde wijzigingen.

Wijzig de code pas nadat de analyse duidelijk is.

## 14. Verboden automatische wijzigingen

Voer deze wijzigingen niet zelfstandig uit:

* systeemservices verwijderen;
* SSH uitschakelen;
* firewallregels wijzigen;
* sudoersrechten uitbreiden;
* gebruikers verwijderen;
* netwerkverbindingen verwijderen;
* schijfpartities aanpassen;
* wachtwoorden veranderen;
* Git-geschiedenis herschrijven;
* geheimen toevoegen;
* grote mappen verwijderen;
* de volledige architectuur herschrijven.

Vraag hiervoor eerst expliciete toestemming.

## 15. Verwacht eindverslag

Na iedere taak vermeldt de agent:

* welke bestanden zijn bekeken;
* welke bestanden zijn gewijzigd;
* waarom die wijzigingen nodig waren;
* welke tests zijn uitgevoerd;
* welke tests niet konden worden uitgevoerd;
* welke risico’s of openstaande vragen overblijven.
