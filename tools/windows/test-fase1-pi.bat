@echo off
setlocal EnableExtensions

REM ============================================================
REM Digital Signage - geautomatiseerde Fase 2-test
REM ============================================================

REM Pas deze waarden aan voor jouw Raspberry Pi.
set "PI_USER=bloemkool"
set "PI_HOST=fmg-pi05.local"
set "PI_PROJECT_PATH="

set "LOCAL_SCRIPT=%~dp0digitalsignage-fase1-test.sh"
set "REMOTE_SCRIPT=/tmp/digitalsignage-fase1-test.sh"
set "LOG_DIR=%~dp0logs"
set "TERM=dumb"
set "NO_COLOR=1"
set "GIT_PAGER=cat"

title Digital Signage - Fase 2-test

echo.
echo ============================================================
echo Digital Signage - Fase 2-test
echo ============================================================
echo Raspberry Pi: %PI_USER%@%PI_HOST%
if not "%PI_PROJECT_PATH%"=="" echo Projectpad: %PI_PROJECT_PATH%
echo.

REM Controleer of het Linux-testscript bestaat.
if not exist "%LOCAL_SCRIPT%" (
    echo [FOUT] Het volgende bestand ontbreekt:
    echo.
    echo %LOCAL_SCRIPT%
    echo.
    echo Plaats digitalsignage-fase1-test.sh in dezelfde map
    echo als deze batchfile.
    echo.
    pause
    exit /b 1
)

REM Controleer of SSH op Windows beschikbaar is.
where ssh >nul 2>&1
if errorlevel 1 (
    echo [FOUT] De Windows SSH-client is niet gevonden.
    echo.
    echo Installeer OpenSSH Client via:
    echo Instellingen ^> Systeem ^> Optionele onderdelen
    echo.
    pause
    exit /b 1
)

REM Controleer of SCP op Windows beschikbaar is.
where scp >nul 2>&1
if errorlevel 1 (
    echo [FOUT] De Windows SCP-client is niet gevonden.
    echo.
    echo Installeer OpenSSH Client via:
    echo Instellingen ^> Systeem ^> Optionele onderdelen
    echo.
    pause
    exit /b 1
)

REM Maak de logmap wanneer deze nog niet bestaat.
if not exist "%LOG_DIR%" (
    mkdir "%LOG_DIR%"
)

REM Veilige datum en tijd ophalen via PowerShell.
for /f %%i in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do (
    set "DATUMTIJD=%%i"
)

set "LOG_FILE=%LOG_DIR%\fase1-test-%DATUMTIJD%.log"

echo [1/4] Verbinding met Raspberry Pi testen...
echo.

ssh -o ConnectTimeout=10 "%PI_USER%@%PI_HOST%" "echo SSH-verbinding geslaagd"
if errorlevel 1 (
    echo.
    echo [FOUT] Er kon geen SSH-verbinding worden gemaakt.
    echo.
    echo Controleer:
    echo - staat de Raspberry Pi aan?
    echo - zit hij op hetzelfde netwerk?
    echo - klopt de hostnaam?
    echo - staat SSH aan?
    echo.
    pause
    exit /b 1
)

echo.
echo [2/4] Testscript naar Raspberry Pi kopieren...
echo.

scp "%LOCAL_SCRIPT%" "%PI_USER%@%PI_HOST%:%REMOTE_SCRIPT%"
if errorlevel 1 (
    echo.
    echo [FOUT] Het testscript kon niet worden gekopieerd.
    echo.
    pause
    exit /b 1
)

echo.
echo [3/4] Fase 2-test uitvoeren...
echo.
echo Mogelijk wordt je Raspberry Pi-wachtwoord gevraagd.
echo Bij sudo kan het wachtwoord opnieuw gevraagd worden.
echo.
echo De uitvoer wordt ook opgeslagen in:
echo %LOG_FILE%
echo.

REM Schrijf de volledige SSH-uitvoer rechtstreeks naar het logbestand.
REM Daarna tonen we het logbestand in de console. Zo vermijden we kwetsbare
REM PowerShell-quoting rond 2>&1 en de remote &&-opdracht.
ssh -t "%PI_USER%@%PI_HOST%" "TERM=dumb NO_COLOR=1 GIT_PAGER=cat DIGITALSIGNAGE_PROJECT_PATH='%PI_PROJECT_PATH%' bash -lc 'chmod +x %REMOTE_SCRIPT% && bash %REMOTE_SCRIPT%'" > "%LOG_FILE%" 2>&1

set "TEST_RESULT=%ERRORLEVEL%"

type "%LOG_FILE%"

echo.
echo [4/4] Tijdelijk testscript opruimen...
echo.

ssh "%PI_USER%@%PI_HOST%" "rm -f %REMOTE_SCRIPT%" >nul 2>&1

echo.
echo ============================================================

if "%TEST_RESULT%"=="0" (
    echo [KLAAR] De testopdracht is uitgevoerd.
) else (
    echo [WAARSCHUWING] De testopdracht gaf foutcode %TEST_RESULT%.
)

echo.
echo Logbestand:
echo %LOG_FILE%
echo.
echo Upload dit logbestand of plak de inhoud in ChatGPT.
echo ============================================================
echo.

pause

exit /b %TEST_RESULT%
