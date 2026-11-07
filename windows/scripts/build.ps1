param(
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [switch]$Installer
)
$ErrorActionPreference = 'Stop'
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $python) { throw 'Install Python 3.9 or newer to run the release packaging helper.' }
$arguments = @((Join-Path $PSScriptRoot 'package.py'), '--runtime', $Runtime)
if ($Installer) { $arguments += '--installer' }
& $python.Source @arguments
if ($LASTEXITCODE -ne 0) { throw 'ClipDiary packaging failed.' }
