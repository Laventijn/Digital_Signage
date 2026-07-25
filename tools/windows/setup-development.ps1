Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "VS Digital Signage development setup"

$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
    Write-Warning "Bash was not found. Install Git Bash or WSL to run the shell tests on Windows."
    exit 0
}

& bash tests/test-shell-syntax.sh
& bash tests/test-installation.sh
