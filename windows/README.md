# NoiseTorch for Windows (native port)

This directory contains a **native Windows port** of NoiseTorch. It does not use
PulseAudio or PipeWire. Instead it uses:

- **WASAPI** (via `github.com/gen2brain/malgo`, a cgo binding to miniaudio) for
  capture and playback.
- **RNNoise** (the same vendored `c/rnnoise` submodule used by the Linux build)
  for noise suppression.
- **NT-VAD**, a PortCls virtual audio driver in `driver/`, which exposes a
  `NoiseTorch Virtual Microphone` recording endpoint and a matching render
  endpoint. The engine plays denoised audio into the render endpoint and the
  driver loops it to the capture endpoint, exactly like a virtual audio cable.

```
 physical mic ──WASAPI capture──► RNNoise ──WASAPI playback──► NT-VAD render
                                                                     │
                                                       kernel loopback ring
                                                                     │
 app (Teams/Zoom/...) ◄──WASAPI capture── NT-VAD capture ◄────────────┘
```

## Status

| Component | State |
|-----------|-------|
| Go engine (`internal/audio`, `internal/rnnoise`) | Compiles for `windows/amd64` (cgo + MinGW). |
| GUI (`cmd/noisetorch`, `lxn/walk`) | Compiles for `windows/amd64`. |
| Kernel driver (`driver/`) | **Reference scaffold** — must be built with the WDK and validated on a test machine. See `driver/README.md`. |

The Go binary was cross-compiled in CI-style on Linux (`CGO_ENABLED=1
GOOS=windows CC=x86_64-w64-mingw32-gcc`). It has not been runtime-tested on a
Windows machine as part of this change.

## Build the application

Requirements: Go 1.21+, MinGW-w64 (`x86_64-w64-mingw32-gcc`), PowerShell.

```powershell
cd windows
.\build-app.ps1
# -> ..\dist\noisetorch-windows.exe
```

Or manually:

```powershell
$env:CGO_ENABLED = "1"
go build -ldflags "-s -w -H windowsgui" -o noisetorch.exe .\cmd\noisetorch
```

## Build & install the driver

See [`driver/README.md`](driver/README.md). In short, on a Windows machine with
Visual Studio 2022 + WDK:

```powershell
cd windows\driver
.\build.ps1 -Platform x64 -TestSign   # development only, enables testsigning
# reboot, then:
.\install.ps1
```

For distribution you must sign `NTVad.sys` and `NTVad.cat` with a Microsoft
attested/EV certificate; test signing is for development machines only.

## Usage

1. Install the NT-VAD driver.
2. Run `noisetorch-windows.exe`.
3. Select your physical microphone as **Microphone**.
4. Select `NoiseTorch Virtual Microphone` as **Virtual microphone (output)**.
5. Press **Start**.
6. In your conferencing app choose **NoiseTorch Virtual Microphone** as input.

The voice-activation threshold mirrors NoiseTorch's 0–100 slider (default 95):
frames whose RNNoise VAD probability is below the threshold are muted.

## Why a driver is required

Unlike Linux, Windows does not let user-mode applications create audio
endpoints. A virtual microphone therefore requires a kernel-mode audio driver
(PortCls miniport). `driver/` provides the project structure, INF, and the
loopback ring buffer; the WaveRT miniport is a reference implementation that
still needs to be completed and signed on Windows.
