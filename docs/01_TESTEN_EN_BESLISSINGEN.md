# Testen En Beslissingen

Dit compatibiliteitsdocument verwijst naar de huidige genummerde documentatie:

- projectkeuzes en acceptatiecriteria: `docs/01-projectoverzicht.md`;
- installatie vanaf lege SD-kaart of SSD: `docs/03-os-installatie.md`;
- probleemoplossing en beheercommando's: `docs/10-problemen-oplossen.md`.

Fase 2B voegt `digitalsignage-health.timer` toe als systemd user-timer. De
health-check controleert kioskservice, Chromium MainPID, DevTools-poort 9222
en het geldige kiosk-paginatarget. Een enkele fout herstart niets; standaard
zijn drie opeenvolgende fouten nodig. Na herstel geldt 600 seconden cooldown
en 90 seconden startup-grace.
