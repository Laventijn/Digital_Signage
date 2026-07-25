@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "DEFAULT_COMMIT_MESSAGE=Rond Fase 2A - Stabiliteit, tests en repository-opruiming af"

echo.
echo === Fase 2 afsluiten ===
echo.
set /p "COMMIT_MESSAGE=Commitbericht [%DEFAULT_COMMIT_MESSAGE%]: "

if "%COMMIT_MESSAGE%"=="" (
  set "COMMIT_MESSAGE=%DEFAULT_COMMIT_MESSAGE%"
)

where git >nul 2>nul
if errorlevel 1 (
  echo.
  echo [FOUT] Git is niet gevonden. Installeer Git of voeg Git toe aan PATH.
  exit /b 1
)

for /f "usebackq delims=" %%R in (`git rev-parse --show-toplevel 2^>nul`) do set "REPO_ROOT=%%R"
if "%REPO_ROOT%"=="" (
  echo.
  echo [FOUT] Dit script staat niet in een Git-repository.
  exit /b 1
)

cd /d "%REPO_ROOT%"
echo [OK] Repository: %REPO_ROOT%

for /f "usebackq delims=" %%B in (`git branch --show-current 2^>nul`) do set "BRANCH=%%B"
if "%BRANCH%"=="" (
  echo.
  echo [FOUT] Git staat in detached HEAD. Schakel eerst naar een gewone branch.
  exit /b 1
)

echo [INFO] Huidige branch: %BRANCH%
if /i not "%BRANCH%"=="main" (
  echo [WAARSCHUWING] Je werkt niet op branch main.
  set /p "CONTINUE_BRANCH=Toch doorgaan op branch '%BRANCH%'? (j/n): "
  if /i not "!CONTINUE_BRANCH!"=="j" if /i not "!CONTINUE_BRANCH!"=="ja" (
    echo Gestopt zonder wijzigingen.
    exit /b 0
  )
)

echo.
echo === Lokale wijzigingen bekijken ===
git status --short
git status --porcelain > "%TEMP%\fase1-git-status.txt"
for %%A in ("%TEMP%\fase1-git-status.txt") do set "STATUS_SIZE=%%~zA"
del "%TEMP%\fase1-git-status.txt" >nul 2>nul

if "%STATUS_SIZE%"=="0" (
  echo [INFO] Er zijn geen lokale wijzigingen om te committen.
  echo.
  echo === Controleren of push nodig is ===
  git push
  if errorlevel 1 (
    echo [FOUT] Push is mislukt.
    exit /b 1
  )
  git status
  exit /b 0
)

echo.
echo === Diff-controle ===
git diff --check
if errorlevel 1 (
  echo [FOUT] git diff --check vond fouten.
  exit /b 1
)
echo [OK] git diff --check geslaagd.

echo.
echo === Samenvatting van wijzigingen ===
git diff --stat
echo.
echo Niet-gevolgde bestanden:
git ls-files --others --exclude-standard

echo.
echo Controleer dat test-logs, tijdelijke bestanden en persoonlijke configuratie niet per ongeluk worden toegevoegd.
set /p "STAGE=Alle getoonde wijzigingen toevoegen aan de commit? (j/n): "
if /i not "%STAGE%"=="j" if /i not "%STAGE%"=="ja" (
  echo Gestopt zonder bestanden toe te voegen.
  exit /b 0
)

echo.
echo === Bestanden toevoegen ===
git add -A
if errorlevel 1 (
  echo [FOUT] git add is mislukt.
  exit /b 1
)

git status

echo.
set /p "CONFIRM_COMMIT=Klopt deze lijst voor de commit? (j/n): "
if /i not "%CONFIRM_COMMIT%"=="j" if /i not "%CONFIRM_COMMIT%"=="ja" (
  echo Commit geannuleerd. Bestanden blijven staged.
  echo Ongedaan maken kan met: git restore --staged .
  exit /b 0
)

if "%COMMIT_MESSAGE%"=="" (
  echo [FOUT] Commitbericht mag niet leeg zijn.
  exit /b 1
)

echo.
echo === Commit maken ===
git commit -m "%COMMIT_MESSAGE%"
if errorlevel 1 (
  echo [FOUT] Commit is mislukt.
  exit /b 1
)

echo.
echo === Naar GitHub pushen ===
git push origin "%BRANCH%"
if errorlevel 1 (
  echo [FOUT] Push is mislukt. De commit bestaat wel lokaal.
  exit /b 1
)

echo.
echo === Eindcontrole ===
git status
git log --oneline -3

git status --porcelain > "%TEMP%\fase1-git-status.txt"
for %%A in ("%TEMP%\fase1-git-status.txt") do set "FINAL_STATUS_SIZE=%%~zA"
del "%TEMP%\fase1-git-status.txt" >nul 2>nul

if "%FINAL_STATUS_SIZE%"=="0" (
  echo [OK] Working tree is schoon.
) else (
  echo [WAARSCHUWING] De working tree is niet volledig schoon.
)

echo.
echo [KLAAR] De wijzigingen zijn gecommit en gepusht.
exit /b 0
