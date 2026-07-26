FMG-PI03 de SSD van 15 is maar 22mb/sec

Fase 2 — Automatisch herstel

Na minstens één à twee dagen stabiele monitoring voegen we herstelgedrag toe:

controleren of Chromium nog draait;
controleren of debugpoort 9222 bereikbaar is;
controleren of een Google Slides-pagina aanwezig is;
Chromium alleen herstarten wanneer het echt vastzit;
een wachttijd tussen herstartpogingen gebruiken;
geen oneindige snelle herstartlus veroorzaken.

Nieuwe onderdelen:

scripts/health-check.py
services/digitalsignage-health.service
services/digitalsignage-health.timer
Fase 3 — Offline gedrag

Daarna bouwen we een betrouwbare offlinewerking:

bij tijdelijk netwerkverlies blijft de huidige presentatie zichtbaar;
bij langdurig netwerkverlies verschijnt een lokale statische pagina;
wanneer internet terugkomt, wordt automatisch teruggekeerd naar Google Slides;
geen PHP of webserver nodig voor het offline scherm;
netwerkcontrole via NetworkManager en een HTTP-controle, niet alleen via ping.
Fase 4 — Installatie en upgrades

Vervolgens maken we het systeem onderhoudbaar:

versienummer bewaren;
upgrade uitvoeren zonder configuratie te overschrijven;
backup van configuratie voor iedere upgrade;
rollback bij een mislukte upgrade;
duidelijke installatie- en upgradelogs;
één eenvoudig commando voor installatie;
één eenvoudig commando voor upgrade;
één eenvoudig commando voor diagnose.

Bijvoorbeeld:

sudo bash install/install.sh
sudo bash install/upgrade.sh
sudo bash tests/run-tests.sh post
Fase 5 — Beheerpaneel

Een webdashboard komt pas daarna. Dat is bewust.

Een beheerpaneel dat services kan herstarten, Wi-Fi kan wijzigen of de Pi kan rebooten heeft beveiligingsrisico’s. We bouwen dat pas wanneer de kiosk, monitoring, offlinewerking en upgrades betrouwbaar zijn.

Het eerste dashboard kan alleen-lezen beginnen met:

kioskstatus;
laatste succesvolle refresh;
RAM- en swapgebruik;
IP-adres;
uptime;
laatste fouten;
huidige presentatie-URL zonder gevoelige informatie.

Pas later voegen we schrijfacties toe.

Concrete opdracht voor Codex