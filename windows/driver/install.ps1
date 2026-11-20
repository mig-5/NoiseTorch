#requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs / removes the NoiseTorch Virtual Audio Device (NT-VAD).
.PARAMETER Path
    Directory containing NTVad.inf, NTVad.sys and NTVad.cat.
.PARAMETER Uninstall
    Remove the device and its driver package.
#>
param(
    [string]$Path = (Join-Path $PSScriptRoot 'build\x64\Release'),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$hwid = 'Root\NTVad'

function Get-DevCon {
    $wdk = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    return Get-ChildItem $wdk -Recurse -Filter devcon.exe -ErrorAction SilentlyContinue |
        Where-Object FullName -like '*x64*' | Select-Object -First 1 -ExpandProperty FullName
}

$devcon = Get-DevCon
if (-not $devcon) {
    throw "devcon.exe not found (install the WDK). Alternatively use 'pnputil /add-driver NTVad.inf /install' after manually adding a root device."
}

if ($Uninstall) {
    Write-Host "==> Removing NT-VAD" -ForegroundColor Cyan
    & $devcon remove $hwid
    & $devcon dp_delete (Join-Path $Path 'NTVad.inf')
    Write-Host "Uninstalled. A reboot may be required." -ForegroundColor Green
    exit 0
}

if (-not (Test-Path (Join-Path $Path 'NTVad.inf'))) {
    throw "NTVad.inf not found in $Path. Build the driver first (build.ps1)."
}

Write-Host "==> Installing NT-VAD from $Path" -ForegroundColor Cyan
& $devcon install (Join-Path $Path 'NTVad.inf') $hwid
if ($LASTEXITCODE -ne 0) { throw "devcon install failed (code $LASTEXITCODE)." }

Write-Host "==> Installed. Look for 'NoiseTorch Virtual Microphone' in Sound settings." -ForegroundColor Green
