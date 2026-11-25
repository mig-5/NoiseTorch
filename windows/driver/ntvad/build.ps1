#requires -RunAsAdministrator
<#
.SYNOPSIS
    Builds the NoiseTorch NT-VAD driver from the generated SYSVAD derivation.

.DESCRIPTION
    Requires:
      - Visual Studio 2022 with the C++ desktop workload and the WDK extension
      - Windows Driver Kit 10.0.22621 or newer

    Run .\apply-sysvad.ps1 first (or pass -Prepare) to generate .\src.
    Produces NTVad.sys, NTVad.inf and NTVad.cat in .\build\x64\Release.

.PARAMETER Platform
    x64 only; the INF is NTamd64.

.PARAMETER TestSign
    Create a local test certificate, sign the driver/catalog and enable test
    signing. Development machines only.
#>
param(
    [ValidateSet('x64')]
    [string]$Platform = 'x64',
    [switch]$TestSign,
    [switch]$Prepare
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$src = Join-Path $root 'src'
$outDir = Join-Path $root "build\$Platform\Release"

if ($Prepare -or -not (Test-Path (Join-Path $src 'TabletAudioSample\TabletAudioSample.vcxproj'))) {
    & (Join-Path $root 'apply-sysvad.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'apply-sysvad.ps1 failed.' }
}

Write-Host '==> Locating MSBuild / WDK' -ForegroundColor Cyan
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw 'vswhere.exe not found. Install Visual Studio 2022 with the C++ workload and the WDK.'
}
$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
    -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw 'MSBuild not found.' }
# 32-bit MSBuild is WOW64-redirected away from System32; this tree may live there.
$msbuild64 = Join-Path (Split-Path $msbuild) 'amd64\MSBuild.exe'
if (Test-Path $msbuild64) { $msbuild = $msbuild64 }

$wdkRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
if (-not (Test-Path $wdkRoot)) {
    throw 'Windows Kits not found. Install the WDK (winget install Microsoft.WindowsWDK.10.0.22621).'
}
$inf2cat = Get-ChildItem $wdkRoot -Recurse -Filter inf2cat.exe -ErrorAction SilentlyContinue |
    Where-Object FullName -like '*x86*' | Select-Object -First 1 -ExpandProperty FullName
$signtool = Get-ChildItem $wdkRoot -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
    Where-Object FullName -like '*x64*' | Select-Object -First 1 -ExpandProperty FullName
if (-not $signtool) {
    $signtool = Get-ChildItem $wdkRoot -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}

$project = Join-Path $src 'TabletAudioSample\TabletAudioSample.vcxproj'

# The WDK build tools (stampinf, inf2cat, ...) are 32-bit. Under a 32-bit
# process C:\Windows\System32 is redirected to SysWOW64, so a tree that lives
# there cannot be built in place. Mirror it to a temp directory and build there.
$needsMirror = $src -like "$env:SystemRoot\System32\*"
$buildRoot = $src
if ($needsMirror) {
    $buildRoot = Join-Path $env:TEMP 'ntvad-build'
    Write-Host "==> Mirroring src to $buildRoot" -ForegroundColor Cyan
    if (Test-Path $buildRoot) { Remove-Item -Recurse -Force $buildRoot }
    $null = robocopy $src $buildRoot /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:1
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with $LASTEXITCODE." }
}

Write-Host '==> Building NTVad.sys' -ForegroundColor Cyan
# The full SYSVAD solution also contains APOs and a keyword-detector DLL that
# need ATL; NTVad only needs the shared endpoint library plus the driver.
& $msbuild (Join-Path $buildRoot 'EndpointsCommon\EndpointsCommon.vcxproj') `
    /p:Configuration=Release /p:Platform=$Platform /m /v:minimal
if ($LASTEXITCODE -ne 0) { throw 'MSBuild failed (EndpointsCommon).' }
& $msbuild (Join-Path $buildRoot 'TabletAudioSample\TabletAudioSample.vcxproj') `
    /p:Configuration=Release /p:Platform=$Platform /m /v:minimal
if ($LASTEXITCODE -ne 0) { throw 'MSBuild failed.' }

$sys = Get-ChildItem -Recurse $buildRoot -Filter TabletAudioSample.sys -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $sys) { throw 'NTVad.sys was not produced (check that the WDK extension loaded).' }

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Copy-Item $sys (Join-Path $outDir 'NTVad.sys') -Force
Copy-Item (Join-Path $root 'NTVad.inf') $outDir -Force
$outSys = Join-Path $outDir 'NTVad.sys'
$outCat = Join-Path $outDir 'NTVad.cat'
$outInf = Join-Path $outDir 'NTVad.inf'

# The INF must declare the same KMDF minor version the binary was linked
# against, otherwise WdfLdr refuses to load it. Prefer the version directory
# shipped with the installed WDK; fall back to a version map.
function Get-KmdfVersion {
    # The WDK stores framework headers either at Include\wdf\kmdf\1.x
    # (seen with the 26100 kits) or under a versioned Include\<ver>\wdf\kmdf.
    $include = Join-Path $wdkRoot '..\Include'
    $roots = @((Join-Path $include 'wdf\kmdf')) + @(
        Get-ChildItem $include -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'wdf\kmdf' })
    $dirs = $roots |
        Where-Object { Test-Path $_ } |
        ForEach-Object { Get-ChildItem $_ -Directory -ErrorAction SilentlyContinue } |
        Where-Object Name -match '^1\.\d+$'
    if ($dirs) {
        return ($dirs | Sort-Object { [version]$_.Name } -Descending |
            Select-Object -First 1 -ExpandProperty Name)
    }
    return '1.33'
}

$kmdf = Get-KmdfVersion
$infText = [System.IO.File]::ReadAllText($outInf)
$infText = [regex]::Replace($infText, 'KmdfLibraryVersion\s*=\s*[0-9.]+',
    "KmdfLibraryVersion = $kmdf")
[System.IO.File]::WriteAllText($outInf, $infText, [System.Text.UTF8Encoding]::new($false))
Write-Host "==> INF declares KMDF $kmdf" -ForegroundColor Cyan

if ($TestSign) {
    Write-Host '==> Creating test certificate (development only)' -ForegroundColor Yellow
    $cert = New-SelfSignedCertificate -Type CodeSigningCert `
        -Subject 'CN=NoiseTorch Test Signing' `
        -CertStoreLocation Cert:\LocalMachine\My `
        -KeyUsage DigitalSignature
    $pwd = ConvertTo-SecureString -String 'noisetorch' -Force -AsPlainText
    $pfx = Join-Path $outDir 'NTVad-test.pfx'
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pwd | Out-Null
    Import-PfxCertificate -FilePath $pfx -CertStoreLocation Cert:\LocalMachine\Root -Password $pwd | Out-Null

    # The catalog hashes the .sys, so the binary is signed first.
    & $signtool sign /fd SHA256 /f $pfx /p noisetorch /t http://timestamp.digicert.com $outSys
    if ($LASTEXITCODE -ne 0) { throw 'signtool failed on NTVad.sys.' }
}

Write-Host '==> Generating catalog' -ForegroundColor Cyan
# inf2cat ships only as x86, so always run it outside System32 and copy the
# catalog back. The catalog hashes the .sys bytes, not the file location.
$staging = Join-Path $env:TEMP ('ntvad-catalog-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $staging | Out-Null
Copy-Item $outSys $staging -Force
Copy-Item $outInf $staging -Force
& $inf2cat /driver:"$staging" /os:10_X64
if ($LASTEXITCODE -ne 0) { throw 'inf2cat failed.' }
Copy-Item (Join-Path $staging 'NTVad.cat') $outDir -Force
Remove-Item -Recurse -Force $staging

if ($TestSign) {
    # inf2cat may re-create the catalog, so sign it after generation.
    & $signtool sign /fd SHA256 /f $pfx /p noisetorch /t http://timestamp.digicert.com $outCat
    if ($LASTEXITCODE -ne 0) { throw 'signtool failed on NTVad.cat.' }

    Write-Host '==> Enabling Windows test signing (reboot required)' -ForegroundColor Yellow
    bcdedit /set testsigning on
} else {
    Write-Host 'Built unsigned. Sign NTVad.sys, then generate and sign NTVad.cat.' -ForegroundColor Yellow
}

Write-Host "==> Done: $outDir" -ForegroundColor Green
