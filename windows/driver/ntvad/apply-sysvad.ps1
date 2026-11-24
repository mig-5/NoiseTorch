#requires -Version 5.1
<#
.SYNOPSIS
    Derives the NoiseTorch NT-VAD sources from the Microsoft SYSVAD sample.

.DESCRIPTION
    A correct WaveRT/PortCls miniport is large and position-accurate; writing
    one from scratch is not sensible. Instead this script fetches the SYSVAD
    sample at a pinned commit and applies the small NoiseTorch delta:

      1. Only the Speaker (render) and MicIn (capture) endpoints are kept.
      2. The render stream feeds a kernel ring instead of a dump file.
      3. The capture stream is produced from that ring instead of a sine tone.
      4. The loopback module is added to the driver project.

    The generated tree lives in .\src and is not meant to be edited by hand:
    re-run this script to regenerate it. All other SYSVAD plumbing (WaveRT
    position reporting, notifications, topology, power, INF interfaces) is
    untouched, which is exactly why this base was chosen.

.PARAMETER WorkDir
    Where to clone Windows-driver-samples. Defaults to .\sysvad.

.PARAMETER Source
    Use an existing checkout of Windows-driver-samples instead of cloning.

.PARAMETER Commit
    Pinned upstream commit. Defaults to the commit this delta was written
    against.

.EXAMPLE
    .\apply-sysvad.ps1
    .\apply-sysvad.ps1 -Source C:\src\Windows-driver-samples
#>
param(
    [string]$WorkDir = (Join-Path $PSScriptRoot 'sysvad'),
    [string]$Source,
    [string]$Commit = 'd49bb7d72f3651952b2b6e4ad28d14fe2247eb69'
)

$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'src'
$repoUrl = 'https://github.com/microsoft/Windows-driver-samples.git'

function Update-Text {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Replacement,
        [Parameter(Mandatory)][string]$Description,
        [int]$ExpectedCount = 1
    )

    $text = [System.IO.File]::ReadAllText($Path)
    $regex = [System.Text.RegularExpressions.Regex]::new(
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline)

    $matches = $regex.Matches($text)
    if ($matches.Count -ne $ExpectedCount) {
        throw ("Patch '{0}' matched {1} time(s), expected {2} in {3}. " +
               "The pinned SYSVAD source may have changed.") -f
            $Description, $matches.Count, $ExpectedCount, $Path
    }

    $updated = $regex.Replace($text, $Replacement)
    [System.IO.File]::WriteAllText($Path, $updated, [System.Text.UTF8Encoding]::new($false))
    Write-Host ("  patched: {0}" -f $Description) -ForegroundColor DarkGray
}

function Replace-InText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Replacement,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][int]$ExpectedCount
    )

    $regex = [System.Text.RegularExpressions.Regex]::new(
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $matches = $regex.Matches($Text)
    if ($matches.Count -ne $ExpectedCount) {
        throw ("Format patch '{0}' matched {1} time(s), expected {2}. " +
               "The pinned SYSVAD source may have changed.") -f
            $Description, $matches.Count, $ExpectedCount
    }
    Write-Host ("  patched: {0}" -f $Description) -ForegroundColor DarkGray
    return $regex.Replace($Text, $Replacement)
}

# Applies $Transform to the initializer body of "Type Name[] =" in $Text.
function Edit-ArrayBody {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ArrayName,
        [Parameter(Mandatory)][scriptblock]$Transform
    )

    $open = [regex]::Match($Text, [regex]::Escape($ArrayName) + '\s*\[\]\s*=')
    if (-not $open.Success) { throw "Array $ArrayName not found." }
    $start = $open.Index + $open.Length
    $end = $Text.IndexOf('};', $start)
    if ($end -lt 0) { throw "Unterminated array $ArrayName." }

    $body = $Text.Substring($start, $end - $start)
    $newBody = & $Transform $body
    return $Text.Substring(0, $start) + $newBody + $Text.Substring($end)
}

# Collapses every PCM rate in an array body to 48 kHz / 16-bit / stereo.
# Duplicate entries are harmless and keep all index references valid.
function Set-BodyTo48kStereo {
    param([string]$Body, [int]$ExpectedEntries, [bool]$ForceStereoChannels)

    if ($ForceStereoChannels) {
        $Body = Replace-InText -Text $Body -ExpectedCount $ExpectedEntries `
            -Pattern '(WAVE_FORMAT_EXTENSIBLE,\s*\r?\n\s*)1(,\s*\r?\n)' `
            -Replacement '${1}2${2}' `
            -Description 'capture channel count 1 -> 2'
        $Body = Replace-InText -Text $Body -ExpectedCount $ExpectedEntries `
            -Pattern '(,\s*\r?\n\s*)2(,\s*\r?\n\s*16,)' `
            -Replacement '${1}4${2}' `
            -Description 'capture block alignment 2 -> 4'
        $Body = Replace-InText -Text $Body -ExpectedCount $ExpectedEntries `
            -Pattern 'KSAUDIO_SPEAKER_MONO' `
            -Replacement 'KSAUDIO_SPEAKER_STEREO' `
            -Description 'capture channel mask mono -> stereo'
    }

    return Replace-InText -Text $Body -ExpectedCount $ExpectedEntries `
        -Pattern '^([ \t]*)\d{4,6},\r?\n([ \t]*)\d+,\r?$' `
        -Replacement ('${1}48000,' + "`r`n" + '${2}192000,') `
        -Description 'PCM formats -> 48 kHz / 16-bit / stereo'
}

Write-Host '==> Acquiring SYSVAD' -ForegroundColor Cyan
if ($Source) {
    if (-not (Test-Path (Join-Path $Source 'audio\sysvad'))) {
        throw "$Source does not look like a Windows-driver-samples checkout."
    }
    $sampleRoot = $Source
} else {
    if (-not (Test-Path (Join-Path $WorkDir 'audio\sysvad'))) {
        if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
        git clone --sparse --filter=blob:none $repoUrl $WorkDir
        if ($LASTEXITCODE -ne 0) { throw 'git clone failed.' }
        git -C $WorkDir sparse-checkout set audio/sysvad
        git -C $WorkDir fetch --depth 1 origin $Commit
        if ($LASTEXITCODE -ne 0) { throw "Could not fetch pinned commit $Commit." }
        git -C $WorkDir checkout --detach FETCH_HEAD
        if ($LASTEXITCODE -ne 0) { throw 'git checkout failed.' }
    }
    $sampleRoot = $WorkDir
}

$upstream = Join-Path $sampleRoot 'audio\sysvad'
if (-not (Test-Path (Join-Path $upstream 'adapter.cpp'))) {
    throw "SYSVAD sources missing under $upstream."
}

Write-Host '==> Copying SYSVAD base into .\src' -ForegroundColor Cyan
if (Test-Path $src) { Remove-Item -Recurse -Force $src }
New-Item -ItemType Directory -Force -Path $src | Out-Null
Copy-Item (Join-Path $upstream '*') $src -Recurse -Force

Copy-Item (Join-Path $PSScriptRoot 'ntvad_loopback.h') $src -Force
Copy-Item (Join-Path $PSScriptRoot 'ntvad_loopback.cpp') $src -Force

Write-Host '==> Applying the NoiseTorch delta' -ForegroundColor Cyan

$pairs = Join-Path $src 'TabletAudioSample\minipairs.h'
Update-Text -Path $pairs -Description 'render endpoint table (Speaker only)' `
    -Pattern 'PENDPOINT_MINIPAIR\s+g_RenderEndpoints\[\]\s*=\s*\{[^}]*\}' `
    -Replacement @'
PENDPOINT_MINIPAIR  g_RenderEndpoints[] = 
{
    &SpeakerMiniports,
}
'@

Update-Text -Path $pairs -Description 'capture endpoint table (MicIn only)' `
    -Pattern 'PENDPOINT_MINIPAIR\s+g_CaptureEndpoints\[\]\s*=\s*\{[^}]*\}' `
    -Replacement @'
PENDPOINT_MINIPAIR  g_CaptureEndpoints[] = 
{
    &MicInMiniports,
}
'@

$stream = Join-Path $src 'EndpointsCommon\minwavertstream.cpp'

Update-Text -Path $stream -Description 'include loopback header' `
    -Pattern '(#include "AudioModuleHelper\.h")' `
    -Replacement "`$1`r`n#include `"ntvad_loopback.h`""

Update-Text -Path $stream -Description 'capture produces audio from the loopback ring' `
    -Pattern 'm_ToneGenerator\.GenerateSine\(m_pDmaBuffer \+ bufferOffset, runWrite\);' `
    -Replacement 'NtvadLoopbackRead(NtvadLoopbackInstance(), m_pDmaBuffer + bufferOffset, runWrite);'

Update-Text -Path $stream -Description 'render publishes audio to the loopback ring' `
    -Pattern 'm_SaveData\.WriteData\(m_pDmaBuffer \+ bufferOffset, runWrite\);' `
    -Replacement 'NtvadLoopbackWrite(NtvadLoopbackInstance(), m_pDmaBuffer + bufferOffset, runWrite);'

Update-Text -Path $stream -Description 'always consume render buffers (drop dump-file guard)' `
    -Pattern 'if \(!g_DoNotCreateDataFiles\)\s*\{\s*//[^\r\n]*\r?\n\s*ReadBytes\(ByteDisplacement\);\s*\}' `
    -Replacement 'ReadBytes(ByteDisplacement);'

$adapter = Join-Path $src 'adapter.cpp'

Update-Text -Path $adapter -Description 'include loopback header in the adapter' `
    -Pattern '(#include "a2dphpminipairs\.h")' `
    -Replacement "`$1`r`n#include `"ntvad_loopback.h`""

Update-Text -Path $adapter -Description 'initialize the loopback ring in DriverEntry' `
    -Pattern 'DPF\(D_TERSE, \(\"\[DriverEntry\]\"\)\);' `
    -Replacement @'
DPF(D_TERSE, ("[DriverEntry]"));

    NtvadLoopbackInitialize(NtvadLoopbackInstance());
'@

$project = Join-Path $src 'TabletAudioSample\TabletAudioSample.vcxproj'
Update-Text -Path $project -Description 'compile ntvad_loopback.cpp' `
    -Pattern '<ClCompile Include="\.\.\\adapter\.cpp" />' `
    -Replacement @'
<ClCompile Include="..\adapter.cpp" />
    <ClCompile Include="..\ntvad_loopback.cpp" />
'@

# The cable carries raw PCM, so both endpoints must expose exactly one format.
# Windows picks each endpoint's mix format independently; identical format
# lists are not enough, so every supported PCM rate is collapsed to 48 kHz /
# 16-bit / stereo and the capture endpoint is switched from mono to stereo.
$speakerTable = Join-Path $src 'EndpointsCommon\speakerwavtable.h'
$speakerText = [System.IO.File]::ReadAllText($speakerTable)
$speakerText = Edit-ArrayBody -Text $speakerText -ArrayName 'SpeakerHostPinSupportedDeviceFormats' `
    -Transform { param($body) Set-BodyTo48kStereo -Body $body -ExpectedEntries 6 -ForceStereoChannels $false }
$speakerText = Edit-ArrayBody -Text $speakerText -ArrayName 'SpeakerAudioEngineSupportedDeviceFormats' `
    -Transform { param($body) Set-BodyTo48kStereo -Body $body -ExpectedEntries 5 -ForceStereoChannels $false }
$speakerText = Edit-ArrayBody -Text $speakerText -ArrayName 'SpeakerOffloadPinSupportedDeviceFormats' `
    -Transform { param($body) Set-BodyTo48kStereo -Body $body -ExpectedEntries 2 -ForceStereoChannels $false }
$speakerText = Replace-InText -Text $speakerText -ExpectedCount 1 `
    -Pattern '(#define SPEAKER_HOST_MIN_SAMPLE_RATE\s+)\d+' `
    -Replacement '${1}48000' -Description 'speaker min rate -> 48 kHz'
$speakerText = Replace-InText -Text $speakerText -ExpectedCount 1 `
    -Pattern '(#define SPEAKER_HOST_MAX_SAMPLE_RATE\s+)\d+' `
    -Replacement '${1}48000' -Description 'speaker max rate -> 48 kHz'
$speakerText = Replace-InText -Text $speakerText -ExpectedCount 1 `
    -Pattern '(#define SPEAKER_OFFLOAD_MIN_SAMPLE_RATE\s+)\d+' `
    -Replacement '${1}48000' -Description 'offload min rate -> 48 kHz'
$speakerText = Replace-InText -Text $speakerText -ExpectedCount 1 `
    -Pattern '(#define SPEAKER_OFFLOAD_MAX_SAMPLE_RATE\s+)\d+' `
    -Replacement '${1}48000' -Description 'offload max rate -> 48 kHz'
[System.IO.File]::WriteAllText($speakerTable, $speakerText, [System.Text.UTF8Encoding]::new($false))

$micTable = Join-Path $src 'TabletAudioSample\micinwavtable.h'
$micText = [System.IO.File]::ReadAllText($micTable)
$micText = Edit-ArrayBody -Text $micText -ArrayName 'MicInPinSupportedDeviceFormats' `
    -Transform { param($body) Set-BodyTo48kStereo -Body $body -ExpectedEntries 8 -ForceStereoChannels $true }
$micText = Replace-InText -Text $micText -ExpectedCount 1 `
    -Pattern '(#define MICIN_DEVICE_MAX_CHANNELS\s+)1\b' `
    -Replacement '${1}2' -Description 'capture max channels 1 -> 2'
$micText = Replace-InText -Text $micText -ExpectedCount 1 `
    -Pattern '(#define MICIN_MIN_SAMPLE_RATE\s+)\d+' `
    -Replacement '${1}48000' -Description 'capture min rate -> 48 kHz'
$micText = Replace-InText -Text $micText -ExpectedCount 1 `
    -Pattern '(#define MICIN_MAX_SAMPLE_RATE\s+)\d+' `
    -Replacement '${1}48000' -Description 'capture max rate -> 48 kHz'
[System.IO.File]::WriteAllText($micTable, $micText, [System.Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host '==> Derived driver ready:' -ForegroundColor Green
Write-Host ('    {0}' -f $src)
Write-Host '    Build it with .\build.ps1 (requires Visual Studio 2022 + WDK).'