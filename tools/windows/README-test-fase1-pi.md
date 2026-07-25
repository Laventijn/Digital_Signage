# Geautomatiseerde Fase 2-test

Plaats deze bestanden samen in:

```text
tools\windows\
```

Bestanden:

- `test-fase1-pi.bat`
- `digitalsignage-fase1-test.sh`

Dubbelklik daarna op:

```text
test-fase1-pi.bat
```

De batchfile:

1. controleert of `ssh` en `scp` beschikbaar zijn;
2. kopieert het Linux-testscript tijdelijk naar de Raspberry Pi;
3. voert de Fase 2-controles op de Raspberry Pi uit;
4. slaat de volledige uitvoer op in `tools\windows\logs\`;
5. verwijdert het tijdelijke script van de Pi.

Standaardverbinding:

```text
bloemkool@fmg-pi05.local
```

Pas bovenaan in `test-fase1-pi.bat` eventueel `PI_USER`, `PI_HOST` en `PI_PROJECT_PATH` aan.

De test kan om het Raspberry Pi-wachtwoord en het sudo-wachtwoord vragen.

Na afloop geef je het nieuwe `.log`-bestand uit de map `logs` door.
