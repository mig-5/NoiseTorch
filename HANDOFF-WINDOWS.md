# Handoff — NoiseTorch para Windows (continuar na máquina Windows)

Documento de retomada da sessão. Gerado em 2026-11-20.

## 1. Objetivo

Fork do [NoiseTorch](https://github.com/noisetorch/NoiseTorch) modificado para
rodar **nativamente no Windows**, usando **WASAPI + RNNoise** e um **driver de
áudio virtual próprio** (NT-VAD) em vez de PulseAudio/PipeWire.

## 2. Onde está o código

- Fork: `https://github.com/mig-5/NoiseTorch`
- Branch: `windows-native`
- Commit da sessão: `1de1069` — "Add native Windows port (WASAPI + RNNoise + NT-VAD driver)"
- Repositório local desta máquina: `/home/miguel/Documentos/programação/noisetorch-windows`

### Retomar em outra máquina

```powershell
git clone -b windows-native https://github.com/mig-5/NoiseTorch.git
cd NoiseTorch
git submodule update --init --recursive   # OBRIGATÓRIO (c/rnnoise, c/c-ringbuf)
```

## 3. Arquitetura implementada

```
 mic físico ──WASAPI capture──► RNNoise ──WASAPI playback──► NT-VAD (render)
                                                                    │
                                                        ring buffer no kernel
                                                                    │
 app (Teams/Zoom) ◄──WASAPI capture── NT-VAD (capture) ◄────────────┘
```

- O app Windows captura o microfone, aplica RNNoise e **reproduz** no endpoint
  de render do driver NT-VAD.
- O driver faz o **loopback** render→capture num ring buffer no kernel.
- Os apps enxergam o endpoint de **capture** como "NoiseTorch Virtual Microphone".

## 4. O que foi criado (tudo em `windows/`)

Módulo Go próprio em `windows/go.mod` (não afeta o build Linux original).

| Caminho | O que é |
|---|---|
| `windows/internal/audio/audio.go` | Engine WASAPI duplex via `github.com/gen2brain/malgo` (miniaudio). Captura mono F32 48kHz, processa RNNoise e reproduz. Lista dispositivos. |
| `windows/internal/rnnoise/rnnoise.go` | Binding cgo sobre o submódulo `c/rnnoise`. `Denoiser.ProcessFrame` (480 samples) retorna VAD. |
| `windows/internal/rnnoise/bridge.c` | Inclui os `.c` do RNNoise numa única TU para o cgo compilar. |
| `windows/cmd/noisetorch/main.go` | GUI nativa Win32 com `lxn/walk`: escolha de mic/saída, slider de threshold, Start/Stop, status de VAD e log. |
| `windows/noisetorch.manifest` | Common Controls v6 + DPI per-monitor. |
| `windows/build-app.ps1` | Gera `.syso` do manifest (`rsrc`) e compila o exe windowed. |
| `windows/driver/loopback.h` | Ring buffer SPSC mono float32 (render→capture). Código pronto e independente. |
| `windows/driver/miniport.h/.cpp` | Miniport WaveRT de referência (render+capture compartilhando o ring). **Scaffold.** |
| `windows/driver/adapter.cpp` | DriverEntry + registro de subdevices (stub parcial). **Scaffold.** |
| `windows/driver/NTVad.inf` | Dispositivo MEDIA root-enumerado `Root\NTVad`. |
| `windows/driver/NTVad.vcxproj` | Projeto WDK (kernel-mode driver). |
| `windows/driver/build.ps1` | Build + inf2cat + (opcional) test-sign + habilita testsigning. |
| `windows/driver/install.ps1` | Instala/remove via `devcon`. |
| `windows/README.md`, `windows/driver/README.md` | Documentação detalhada. |

O README raiz ganhou uma nota apontando para `windows/`. O código Linux
(`main.go`, `ui.go`, `module.go`, etc.) **não foi alterado**.

## 5. Status real (verificado x não verificado)

### Verificado nesta sessão (Linux → Windows, cross-compile)
- RNNoise compila para `linux/amd64` e `windows/amd64` (cgo + MinGW).
- O app completo compila para `windows/amd64`:
  `CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc go build ...`
  Produziu `PE32+ executable (GUI), x86-64`.
- Dependências fixadas: `go 1.21`, `malgo v0.11.28`, `walk` (commit de 2021),
  `golang.org/x/sys v0.20.0`.

### NÃO verificado
- **Execução em Windows** (não havia máquina Windows; o exe não foi rodado).
- **Driver** não foi compilado nem testado (precisa de Visual Studio + WDK).
  `miniport.cpp`/`adapter.cpp` são referência, com TODOs; o caminho WaveRT usa
  um timer simplificado (não position-accurate) e `adapter.cpp` não registra os
  subdevices de fato ainda.

## 6. Próximos passos (na máquina Windows)

### 6.1 Build do app
Requisitos: Go 1.21+, MinGW-w64 (`x86_64-w64-mingw32-gcc` no PATH), PowerShell.

```powershell
cd windows
.\build-app.ps1
# gera ..\dist\noisetorch-windows.exe
```

Ou manual:

```powershell
$env:CGO_ENABLED = "1"
go run github.com/akavel/rsrc@latest -manifest noisetorch.manifest -o rsrc_windows_amd64.syso
go build -trimpath -ldflags "-s -w -H windowsgui" -o noisetorch.exe .\cmd\noisetorch
```

Teste rápido sem driver: rode o app e selecione, como "Virtual microphone",
qualquer saída de áudio real (ex.: seus fones) — você deve **ouvir** o mic
filtrado (modo monitoração), confirmando que o pipeline WASAPI+RNNoise funciona.

### 6.2 Driver — decisão importante

O scaffold atual **não está pronto para produção**. Recomendação do próprio
`driver/README.md`: partir do sample **SYSVAD** da Microsoft (WaveRT completo e
position-accurate) e **substituir apenas o caminho de hardware** pelas funções de
`windows/driver/loopback.h`:

- Render: copiar do buffer WaveRT para o ring → `NTVadLoopbackWrite`.
- Capture: copiar do ring para o buffer WaveRT → `NTVadLoopbackRead`.
- Manter o INF (`NTVad.inf`) e o `loopback.h` como estão.

Alternativa: completar `miniport.cpp`/`adapter.cpp` (mais trabalhoso e arriscado).

### 6.3 Build/instalação do driver

Requisitos: Visual Studio 2022 (C++) + WDK.

```powershell
cd windows\driver
.\build.ps1 -Platform x64 -TestSign   # dev: assina com cert local + testsigning
# reiniciar o Windows
.\install.ps1 -Path .\build\x64\Release
```

Depois: Configurações de Som → deve aparecer "NoiseTorch Virtual Microphone"
como reprodução **e** gravação.

Produção: assinar `NTVad.sys` e `NTVad.cat` com certificado Microsoft
Attestation/EV (Partner Center). Test-signing só serve para desenvolvimento.

## 7. Cuidados / pegadinhas

- **Submódulos**: sem `git submodule update --init --recursive`, o build cgo do
  RNNoise falha (faltam `c/rnnoise/src/*.c`).
- **cgo**: precisa de gcc MinGW no PATH e `CGO_ENABLED=1`.
- **`go` directive**: mantido em `1.21` via `go mod tidy -go=1.21`. Não rode
  `go get`/`tidy` sem `-go=1.21` se quiser manter compatibilidade.
- **`rsrc`**: gera `rsrc_windows_amd64.syso` (ignorado pelo `.gitignore`).
- **Driver**: `exe` e artefatos de driver estão no `windows/.gitignore`.
- O endpoint virtual só existe **depois de instalar o driver**; sem ele o app
  ainda funciona apontando para uma saída real (monitoração).

## 8. Prompt sugerido para retomar com o assistente

> Estou retomando o port do NoiseTorch para Windows no fork
> `mig-5/NoiseTorch`, branch `windows-native` (commit `1de1069`). Leia
> `HANDOFF-WINDOWS.md` e `windows/README.md`. O app Go já cross-compila para
> windows/amd64. Agora quero [completar o driver NT-VAD a partir do sample
> SYSVAD / rodar e depurar o app no Windows / empacotar um instalador].
