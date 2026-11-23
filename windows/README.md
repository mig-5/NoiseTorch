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
| Go engine (`internal/audio`, `internal/rnnoise`) | Built and **runtime-tested** on Windows 11 (`windows/amd64`, Go 1.27, MinGW-w64 16.2). |
| GUI (`cmd/noisetorch`, `lxn/walk`) | Built and launched/closed cleanly on Windows 11. |
| RNNoise binding | Unit-tested (`go test ./...`): silence, noise, wrong-size and closed-state behaviour. |
| Kernel driver (`driver/`) | **Reference scaffold** — must be built with the WDK and validated on a test machine. See `driver/README.md`. |

Verified in the Windows session:

- `go vet ./...` and `go test ./...` pass.
- `ntdiag -list` enumerates real WASAPI capture/playback endpoints.
- `ntdiag -monitor 3s` runs the full duplex capture → RNNoise → playback pipeline
  and prints per-callback RMS, VAD probability and gate state.
- The GUI starts, stays responsive and exits cleanly when the window is closed.

The RNNoise VAD gating matches the Linux LADSPA module: the threshold is capped
at 95, frames above it open a 400 ms grace window (`VAD_GRACE_PERIOD`), and a
threshold of 0 disables gating.

## Build the application

Requirements: Go 1.21+, MinGW-w64 (`x86_64-w64-mingw32-gcc`), PowerShell.

```powershell
cd windows
.\build-app.ps1
# -> ..\dist\noisetorch-windows.exe
# -> ..\dist\ntdiag.exe
```

Or manually:

```powershell
$env:CGO_ENABLED = "1"
go run github.com/akavel/rsrc@v0.10.2 -manifest noisetorch.manifest -o .\cmd\noisetorch\rsrc_windows_amd64.syso
go build -ldflags "-s -w -H windowsgui" -o noisetorch.exe .\cmd\noisetorch
```

> The manifest `.syso` **must** live next to `package main`
> (`cmd/noisetorch/`); a copy in `windows/` is ignored by the linker and the
> GUI then fails at startup with `TTM_ADDTOOL failed`. Modern MinGW-w64 emits a
> harmless `.rsrc merge failure: multiple non-default manifests` warning because
> GCC always links its own `default-manifest.o`; the embedded NoiseTorch
> manifest is still the one Windows loads (Common Controls v6 works).

### Diagnose without the GUI

`ntdiag` is a console tool for validating devices and the audio pipeline:

```powershell
.\dist\ntdiag.exe -list
.\dist\ntdiag.exe -list=false -monitor 5s -threshold 50 `
  -capture "Microphone" -playback "NoiseTorch Virtual Microphone"
```

`-capture`/`-playback` are case-insensitive name substrings; omit them to use
the system defaults. `-threshold 0` disables VAD gating.

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
