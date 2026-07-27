# Lokale presentatiecache

## Doel

Deze uitbreiding is alleen actief wanneer de kiosk een Google Presentatie toont:

```ini
CONTENT_MODE="presentation"
```

De Pi bewaart dan een lokale kopie van de zichtbare dia's. Bij langdurig internetverlies opent de bestaande health-check nog steeds:

```text
file:///opt/digitalsignage/offline/index.html
```

Na een geslaagde synchronisatie toont dat vaste pad de laatst gedownloade presentatie. Zonder bruikbare cache toont het de gewone offlineboodschap.

Voor een latere websitemodus wordt gebruikt:

```ini
CONTENT_MODE="website"
```

In die modus downloadt de presentatiecache geen Google Slides en wordt de algemene offlinepagina gebruikt. De downloadlogica blijft dus gescheiden van de toekomstige websitekiosk.

## Verborgen dia's

Google Slides markeert verborgen dia's met `isSkipped`. Standaard staat:

```ini
PRESENTATION_CACHE_INCLUDE_SKIPPED_SLIDES=false
```

Verborgen dia's worden dan niet gedownload en niet afgespeeld. Alleen wanneer deze waarde bewust op `true` wordt gezet, worden ze opgenomen.

## Installeren op een bestaande Fase 3-Pi

Werk eerst op de featurebranch en voer daarna uit:

```bash
sudo bash install/upgrade-presentation-cache.sh
```

Het script:

- maakt een configuratieback-up;
- voegt ontbrekende cachevelden toe zonder bestaande waarden te overschrijven;
- installeert `python3-requests` en `python3-google-auth`;
- installeert de cache-engine en lokale speler;
- installeert en activeert een systemd user-timer;
- laat de bestaande Fase 3-health-check en kioskservice ongemoeid.

## Google-serviceaccount

De echte Google Slides-download vereist een Google Cloud-serviceaccount.

1. Maak een Google Cloud-project en serviceaccount.
2. Schakel de Google Slides API in.
3. Maak een JSON-sleutel.
4. Kopieer die sleutel naar de Pi. Zet het bestand nooit in Git en plak het niet in chat:

```bash
sudo install -m 0640 -o root -g "$(id -gn bloemkool)" \
  google-service-account.json \
  /etc/digitalsignage/google-service-account.json
```

5. Zoek in het JSON-bestand het veld `client_email`.
6. Deel de Google Presentatie als lezer met dat e-mailadres.

Belangrijke configuratie:

```ini
CONTENT_MODE="presentation"
PRESENTATION_CACHE_ENABLED=true
PRESENTATION_CACHE_REFRESH_SECONDS=900
PRESENTATION_CACHE_INCLUDE_SKIPPED_SLIDES=false
PRESENTATION_CACHE_SLIDE_SECONDS=5
PRESENTATION_CACHE_HTTP_TIMEOUT_SECONDS=20
GOOGLE_SERVICE_ACCOUNT_FILE="/etc/digitalsignage/google-service-account.json"
```

## Synchroniseren en controleren

```bash
systemctl --user start digitalsignage-presentation-cache.service
journalctl --user -u digitalsignage-presentation-cache.service -n 50 --no-pager
cat /opt/digitalsignage/offline/cache-manifest.json
find /opt/digitalsignage/offline/versions -maxdepth 3 -type f -print
```

Een geslaagde synchronisatie meldt bijvoorbeeld:

```text
cache=updated slides=12 skipped=3 include_skipped=false
```

## Veilig gedrag bij fouten

De nieuwe versie wordt eerst volledig in een tijdelijke map opgebouwd. Het vaste offlinepad wordt pas omgeschakeld wanneer alle geselecteerde dia's geldig gedownload zijn.

Bij een netwerk-, authenticatie- of downloadfout:

- blijft de laatst werkende cache bestaan;
- meldt de service `cache=stale`;
- gebruikt de service exitcode 10, die systemd als toegestane toestand behandelt.

Wanneer nog nooit een cache kon worden gemaakt, blijft de gewone offlineboodschap beschikbaar.

## Tests zonder Google-account

Voor de installatie:

```bash
bash tests/test-presentation-cache.sh
```

Na de installatie op de Pi:

```bash
sudo bash tests/post-presentation-cache-test.sh
```

De posttest gebruikt tijdelijke fixture-dia's. Hij verandert de echte actieve cache niet en controleert:

- dat verborgen dia's standaard worden overgeslagen;
- dat de manifestvolgorde klopt;
- dat `CONTENT_MODE="website"` de presentatiedownload uitschakelt;
- dat de algemene offlinepagina dan wordt gebruikt.

## Sneller naar de lokale cache

Na afzonderlijke validatie kan de offlineweergave sneller worden gemaakt met bijvoorbeeld:

```ini
HEALTH_CHECK_SECONDS=15
OFFLINE_AFTER_SECONDS=30
CONNECTIVITY_TIMEOUT_SECONDS=5
ONLINE_CONFIRM_SECONDS=30
```

Maak daarvoor eerst een configuratieback-up. Pas de bestaande Fase 3-timer daarna toe met:

```bash
sudo bash install/upgrade.sh
```

De lokale cache verschijnt dan doorgaans ongeveer 30 tot 50 seconden nadat de storing bevestigd is.
