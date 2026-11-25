# NT-VAD — NoiseTorch Virtual Audio Device

A PortCls/KMDF virtual audio adapter that exposes one render endpoint and one
capture endpoint joined by a kernel ring buffer. The NoiseTorch engine plays
denoised audio into the render endpoint; conferencing apps record from the
capture endpoint.

The driver is **not written from scratch**. A correct, position-accurate WaveRT
miniport is large and easy to get subtly wrong, so `ntvad/` is a small,
reproducible delta on top of Microsoft's SYSVAD sample:

| Delta | Effect |
|-------|--------|
| Endpoint tables keep only `SpeakerMiniports` / `MicInMiniports` | One playback + one recording endpoint instead of the sample's demo set |
| Capture `WriteBytes` reads the loopback ring (silence on underrun) | The microphone produces the cable's audio instead of a sine tone |
| Render `ReadBytes` writes the loopback ring | Audio played into the cable is published to the microphone side |
| `NtvadLoopbackInitialize` called from `DriverEntry` | Ring and spin lock are ready before any stream starts |
| All PCM format tables collapsed to 48 kHz/16-bit/stereo; capture pin switched to stereo | Both endpoints expose one identical format, so raw PCM in the ring always matches |
| `NTVad.inf` | Root-enumerated `Root\NTVad` MEDIA device, KMDF service, endpoint interfaces |

Everything else (WaveRT position reporting, notification timers, topology,
power management) comes from SYSVAD unchanged.

## Status

- The derivation script runs and all patches apply cleanly against upstream
  commit `d49bb7d72f3651952b2b6e4ad28d14fe2247eb69` (verified).
- **The driver compiles, links and test-signs** on VS 2022 Build Tools
  17.14 + Windows SDK 10.0.26100 + WDK 10.1.26100 (`build.ps1 -TestSign`
  produces `NTVad.sys`, `NTVad.inf`, `NTVad.cat`). Loading and runtime
  behaviour are not verified yet.

## Requirements

- Visual Studio 2022 with **Desktop development with C++**
- VS components: `Component.Microsoft.Windows.DriverKit.BuildTools` and
  `Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre`
- Windows Driver Kit 10.1.26100 (SDK 26100 required by the WDK)
- Administrator PowerShell for build signing and install

## Usage

```powershell
cd windows\driver\ntvad
.\apply-sysvad.ps1        # fetch pinned SYSVAD and generate .\src
.\build.ps1 -TestSign     # build NTVad.sys, catalog, sign, enable test signing
.\install.ps1             # devcon install Root\NTVad  (reboot after test signing)
```

`build.ps1 -Prepare` performs both steps. Regenerating `src` discards local
edits there by design; change the delta in `apply-sysvad.ps1` instead.

## Format contract

The ring stores raw PCM bytes, so both endpoints must negotiate the **same
format**. Windows chooses each endpoint's mix format independently, so the
derivation collapses every PCM entry in the speaker (host, offload, audio
engine) and microphone format tables to a single **48 kHz / 16-bit / stereo**
format and switches the microphone pin from mono to stereo. Both endpoints
therefore expose exactly one format and cannot disagree.

Apps in shared mode are resampled to 48 kHz stereo by the audio engine before
reaching the endpoints; the endpoints' Advanced format choice no longer affects
the cable. The NoiseTorch app opens the render endpoint using the capture
endpoint's mix format, which is now always 48 kHz/16-bit/stereo.

## Data path

```
apps --render--> WaveSpeaker DMA --ReadBytes--> NTVadLoopbackWrite --> ring
apps <--capture-- WaveMicIn DMA <--WriteBytes-- NtvadLoopbackRead  <-- ring
```

The ring is 64 KiB (≈341 ms of 48 kHz/16-bit/stereo). On overflow the oldest
bytes are dropped; on underrun the capture side reads silence. The capture side
also never replays more than 4 KiB (≈21 ms at that format) of backlog, so a
recorder that starts after playback does not inherit a permanent delay.

## Files

| File | Purpose |
|------|---------|
| `ntvad/ntvad_loopback.h/.cpp` | Kernel ring buffer (spin-locked, DISPATCH_LEVEL safe). |
| `ntvad/apply-sysvad.ps1` | Fetches the pinned SYSVAD and applies the delta into `src/`. |
| `ntvad/NTVad.inf` | Device/service/endpoint definitions for `Root\NTVad`. |
| `ntvad/build.ps1` | MSBuild + inf2cat + optional test signing. |
| `ntvad/install.ps1` | devcon install/remove. |

Generated `ntvad/src/`, `ntvad/sysvad/` and `ntvad/build/` are git-ignored.

## Signing and distribution

Test signing is development-only. A driver that loads on end-user machines
needs a Microsoft-attested (Partner Center) or WHQL signature; plan for EV
certificate onboarding before shipping.
