#requires -RunAsAdministrator
<#
.SYNOPSIS
    Builds the NoiseTorch Virtual Audio Device (NT-VAD) with the WDK.

.DESCRIPTION
    Requires Visual Studio 2022 + Windows Driver Kit (WDK) installed.
    Produces NTVad.sys and NTVad.cat in .\build\<Platform>\Release.

.PARAMETER Platform
    x64 (default) or ARM64.

.PARAMETER TestSign
    Self-sign the driver with a local test certificate and enable test signing.
    ONLY use this on a development machine. Production drivers require a
    Microsoft-attested / EV signature obtained through Partner Center.
#>
param(
    [ValidateSet('x64', 'ARM64')]
    [string]$Platform = 'x64',
    [switch]$TestSign
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$outDir = Join-Path $root "build\$Platform\Release"

Write-Host "==> Locating MSBuild / WDK" -ForegroundColor Cyan
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found. Install Visual Studio 2022 with the C++ and WDK workloads."
}
$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
    -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw "MSBuild not found." }

$wdkRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
if (-not (Test-Path $wdkRoot)) { throw "Windows Kits not found. Install the WDK." }
$inf2cat = Get-ChildItem $wdkRoot -Recurse -Filter inf2cat.exe |
    Where-Object FullName -like '*x86*' | Select-Object -First 1 -ExpandProperty FullName
$signtool = Get-ChildItem $wdkRoot -Recurse -Filter signtool.exe |
    Select-Object -First 1 -ExpandProperty FullName

Write-Host "==> Building NTVad ($Platform)" -ForegroundColor Cyan
& $msbuild (Join-Path $root 'NTVad.vcxproj') `
    /p:Configuration=Release /p:Platform=$Platform /m /v:minimal
if ($LASTEXITCODE -ne 0) { throw "MSBuild failed." }

$sys = Get-ChildItem -Recurse $root -Filter NTVad.sys | Select-Object -First 1 -ExpandProperty FullName
if (-not $sys) { throw "NTVad.sys was not produced." }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Copy-Item $sys $outDir -Force
Copy-Item (Join-Path $root 'NTVad.inf') $outDir -Force

Write-Host "==> Generating catalog" -ForegroundColor Cyan
& $inf2cat /driver:"$outDir" /os:10_X64,10_ARM64
if ($LASTEXITCODE -ne 0) { throw "inf2cat failed." }

if ($TestSign) {
    Write-Host "==> Creating self-signed test certificate" -ForegroundColor Yellow
    $cert = New-SelfSignedCertificate -Type CodeSigningCert `
        -Subject "CN=NoiseTorch Test Signing" `
        -CertStoreLocation Cert:\LocalMachine\My `
        -KeyUsage DigitalSignature `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3')
    $pwd = ConvertTo-SecureString -String 'noisetorch' -Force -AsPlainText
    $pfx = Join-Path $outDir 'NTVad-test.pfx'
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pwd | Out-Null
    Import-PfxCertificate -FilePath $pfx -CertStoreLocation Cert:\LocalMachine\Root -Password $pwd | Out-Null

    & $signtool sign /fd SHA256 /f $pfx /p noisetorch /t http://timestamp.digicert.com "$sys"
    & $signtool sign /fd SHA256 /f $pfx /p noisetorch /t http://timestamp.digicert.com (Join-Path $outDir 'NTVad.cat')

    Write-Host "==> Enabling Windows test signing (reboot required)" -ForegroundColor Yellow
    bcdedit /set testsigning on
} else {
    Write-Host "Built unsigned. Sign NTVad.sys and NTVad.cat with an Attestation/EV certificate." -ForegroundColor Yellow
}

Write-Host "==> Done: $outDir" -ForegroundColor Green
