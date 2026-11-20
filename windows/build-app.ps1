#requires -RunAsAdministrator
<#
.SYNOPSIS
    Builds the NoiseTorch Windows desktop application.
.DESCRIPTION
    Requires Go 1.21+ and a MinGW-w64 gcc (cgo is used by RNNoise and by the
    WASAPI binding). The resulting exe is a windowed (no console) application
    with an embedded manifest.
#>
param(
    [string]$Out = (Join-Path $PSScriptRoot '..\dist\noisetorch-windows.exe')
)

$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    # Embed the application manifest so common controls v6 and per-monitor DPI
    # are active. rsrc produces a .syso consumed automatically by the Go linker.
    Write-Host "==> Generating resource manifest" -ForegroundColor Cyan
    go run github.com/akavel/rsrc@latest -manifest noisetorch.manifest -o rsrc_windows_amd64.syso

    Write-Host "==> Building" -ForegroundColor Cyan
    $env:CGO_ENABLED = '1'
    New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
    go build -trimpath -ldflags "-s -w -H windowsgui" -o $Out ./cmd/noisetorch
    if ($LASTEXITCODE -ne 0) { throw "go build failed." }

    Write-Host "==> Built $Out" -ForegroundColor Green
}
finally {
    Pop-Location
}
