#requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs or removes the NoiseTorch NT-VAD root-enumerated audio device.

.PARAMETER Path
    Directory containing NTVad.inf, NTVad.sys and NTVad.cat.

.PARAMETER Uninstall
    Remove the device and delete the driver package.
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
    throw "devcon.exe not found (install the WDK), or create the root device manually and use 'pnputil /add-driver $Path\NTVad.inf /install'."
}

if ($Uninstall) {
    Write-Host '==> Removing NT-VAD' -ForegroundColor Cyan
    & $devcon remove $hwid
    & $devcon dp_delete (Join-Path $Path 'NTVad.inf')
    Write-Host 'Uninstalled. A reboot may be required.' -ForegroundColor Green
    exit 0
}

$inf = Join-Path $Path 'NTVad.inf'
foreach ($f in @($inf, (Join-Path $Path 'NTVad.sys'), (Join-Path $Path 'NTVad.cat'))) {
    if (-not (Test-Path $f)) { throw "Missing $f. Run build.ps1 first." }
}

Write-Host "==> Installing NT-VAD from $Path" -ForegroundColor Cyan
& $devcon install $inf $hwid
if ($LASTEXITCODE -ne 0) { throw "devcon install failed (code $LASTEXITCODE)." }

Write-Host "==> Installed. Look for 'NoiseTorch Virtual Cable' in Sound settings." -ForegroundColor Green
