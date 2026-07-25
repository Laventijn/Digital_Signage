# Fase 1 afsluiten

De scripts staan in `tools/windows/`.

Gebruik bij voorkeur de batch-wrapper. Die vraagt eerst om het commitbericht en werkt ook wanneer lokale PowerShell execution policies unsigned `.ps1`-bestanden blokkeren.

De batch-wrapper controleert Git, toont alle wijzigingen, voert `git diff --check` uit, vraagt bevestiging, maakt een commit, pusht naar GitHub en toont de eindstatus.

Controleer voor bevestiging dat `test-logs/`, tijdelijke bestanden, wachtwoorden en lokale configuratie niet per ongeluk worden toegevoegd.

PowerShell-gebruik:

```powershell
.\tools\windows\fase1-afsluiten.ps1
```

Met een eigen commitbericht:

```powershell
.\tools\windows\fase1-afsluiten.ps1 -CommitMessage "Rond fase 1 resource logging af"
```

Batch-gebruik:

```powershell
.\tools\windows\fase1-afsluiten.bat
```

Wanneer je na `git add` toch wilt stoppen:

```powershell
git restore --staged .
```
