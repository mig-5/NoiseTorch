# NT-VAD — NoiseTorch Virtual Audio Device

A PortCls virtual audio driver that presents a render endpoint and a capture
endpoint that are connected by a kernel ring buffer, so audio played into the
device can be captured as a virtual microphone.

## ⚠️ Status: reference scaffold

The files here define the architecture, INF, build tooling and the loopback data
path (`loopback.h`). The WaveRT miniport (`miniport.cpp`, `adapter.cpp`) is a
**reference implementation that has not been compiled or validated**. Windows
kernel audio drivers are not compiled as part of the Go build. Before this can
be shipped you must, on a Windows development machine:

1. Build with the WDK (`build.ps1`) and fix any WDK-version API differences.
2. Replace the timer-driven data path with a position-accurate WaveRT
   implementation (or wire the loopback into the WaveRT notification model).
3. Complete the filter/pin descriptors and `PcRegisterSubdevice` calls in
   `adapter.cpp` (currently stubbed).
4. Test signing, then production signing.

The intended, simplest robust alternative is to adapt the Microsoft **SYSVAD**
sample's WaveRT miniport (which is complete and position-accurate) and replace
its hardware data path with `NTVadLoopbackWrite` / `NTVadLoopbackRead` from
`loopback.h`. That keeps the proven WaveRT plumbing and adds only the virtual
cable loopback.

## Files

| File | Purpose |
|------|---------|
| `loopback.h` | Lock-free single-producer/single-consumer mono float32 ring buffer. |
| `miniport.h/.cpp` | WaveRT miniport + stream (render and capture share one ring). |
| `adapter.cpp` | DriverEntry and subdevice registration. |
| `NTVad.inf` | Root-enumerated MEDIA device `Root\NTVad`. |
| `NTVad.vcxproj` | WDK kernel-mode driver project. |
| `build.ps1` | Builds, catalogs and (optionally) test-signs the driver. |
| `install.ps1` | Installs/removes the device using `devcon`. |

## Requirements

- Visual Studio 2022 with **Desktop development with C++**
- **Windows Driver Kit (WDK)** for Windows 10/11
- Administrator PowerShell for build signing and install

## Build

```powershell
.\build.ps1 -Platform x64 -TestSign
```

`-TestSign` creates a local self-signed certificate, signs `NTVad.sys` and
`NTVad.cat`, and runs `bcdedit /set testsigning on` (reboot required).

## Install

```powershell
.\install.ps1 -Path .\build\x64\Release
```

Then open **Sound settings**; you should see:

- Playback: `NoiseTorch Virtual Microphone` (render side, used by the engine)
- Recording: `NoiseTorch Virtual Microphone` (capture side, used by apps)

## Uninstall

```powershell
.\install.ps1 -Path .\build\x64\Release -Uninstall
```
