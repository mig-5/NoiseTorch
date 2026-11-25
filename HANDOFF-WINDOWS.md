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

### 6.2 Driver — abordagem adotada (sessão 3)

O scaffold manual foi **descartado e removido**: era incompilável
(`CUnknown::NonDelegatingAddRef`, `IMiniportWaveRTStream::Init` inexistente,
`GetDescription` com tipo errado). A solução agora é uma **derivação
reproduzível do sample SYSVAD**, em `windows/driver/ntvad/`:

- `apply-sysvad.ps1` clona o commit pinado
  `d49bb7d72f3651952b2b6e4ad28d14fe2247eb69`, copia `audio/sysvad` para
  `ntvad/src/` e aplica deltas verificados (endpoints só Speaker/MicIn, ring no
  lugar do tom/dump, init no `DriverEntry`, projeto inclui `ntvad_loopback.cpp`).
- `NTVad.inf` escrito à mão: `Root\NTVad`, MEDIA, KMDF 1.15, interfaces de
  Wave/Topology para reprodução e gravação.
- Ring de 64 KiB em `ntvad_loopback.{h,cpp}` (PCM bruto, spin lock); o lado de
  captura descarta backlog acima de 4 KiB para não herdar latência permanente.

### 6.3 Build/instalação do driver

Requisitos: Visual Studio 2022 (C++) + WDK.

```powershell
cd windows\driver\ntvad
.\apply-sysvad.ps1              # gera src/ a partir do SYSVAD pinado
.\build.ps1 -TestSign           # MSBuild + inf2cat + cert local + testsigning
# reiniciar o Windows
.\install.ps1                   # devcon install Root\NTVad
```

Depois: Configurações de Som → deve aparecer "NoiseTorch Virtual Cable
(Playback)" e "(Recording)".

> Ambos os endpoints precisam negociar o **mesmo formato** (taxa/canais/bit
> depth), pois o ring guarda PCM bruto. O app abre o render no mix format do
> capture.

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

## 8. Sessão 2 — retomada em Windows (2026-11-22)

### Ambiente preparado nesta máquina
- Go 1.27.4 (`winget install GoLang.Go`).
- MinGW-w64 16.2 POSIX/UCRT (`winget install BrechtSanders.WinLibs.POSIX.UCRT`);
  fornece `x86_64-w64-mingw32-gcc`.

### Verificado em Windows 11
- `go vet ./...` e `go test ./...` passam (inclui testes novos do RNNoise).
- App compila nativo (não só cross-compile) e gera
  `dist\noisetorch-windows.exe`.
- GUI abre, fica responsiva e fecha limpa (3 execuções).
- `dist\ntdiag.exe -list` enumera microfones e saídas WASAPI reais.
- `dist\ntdiag.exe -monitor 3s` executou o pipeline completo
  captura → RNNoise → reprodução, com RMS/VAD/gate por callback.

### Correções feitas nesta sessão
- **Bug crítico do build**: o `.syso` do manifest era gerado em `windows/`, mas
  `package main` está em `windows/cmd/noisetorch/`; o linker ignorava o manifest
  e a GUI morria com `TTM_ADDTOOL failed`. `build-app.ps1` agora gera em
  `cmd/noisetorch/` e também compila o `ntdiag`.
- Paridade de VAD com `c/ladspa/module.c`: escala 32767 (não 32768), threshold
  limitado a 95, grace period de 20 frames (400 ms) e threshold 0 desliga o
  gate. GUI usa o estado real do gate (`LastStats`).
- Guards de buffer no callback duplex e exposição de `LastLevel`/`LastStats`.
- Novos: `cmd/ntdiag` (diagnóstico console) e `internal/rnnoise/rnnoise_test.go`.
- `README.md` do `windows/` atualizado (status real, uso do `ntdiag`, aviso
  inofensivo de manifest duplicado do MinGW).

### Pendências (inalteradas)
1. **Driver NT-VAD**: continua scaffold. Próximo passo recomendado é adaptar o
   sample SYSVAD (WaveRT position-accurate) e trocar o caminho de hardware por
   `NTVadLoopbackWrite`/`NTVadLoopbackRead` de `driver/loopback.h`. Requer
   Visual Studio 2022 + WDK nesta máquina.
2. Sem o driver, o `ntdiag`/GUI só validam em modo monitoração (mic → saída real).
3. Empacotamento/instalador e assinatura de produção ainda não feitos.

## 9. Sessão 3 — driver derivado do SYSVAD (2026-11-23)

### Decisão
- "Só escrever o driver agora": código pronto, **sem compilar** (VS/WDK
  ausentes). Validação de build fica para quando o WDK for instalado.
- Scaffold manual deletado; driver passou a ser derivação do SYSVAD.

### Verificado nesta sessão
- `apply-sysvad.ps1 -Source <clone>` executou e **todos os patches casaram**
  contra o commit pinado (asserts de contagem de match).
- Árvore gerada confere: tabelas de endpoints só com Speaker/MicIn; capture lê o
  ring; render escreve no ring; `ReadBytes` sem guarda de dump; `DriverEntry`
  inicializa o ring; `.vcxproj` inclui `ntvad_loopback.cpp`.
- Formato unificado: as 3 tabelas PCM do speaker (host/offload/audio engine) e
  as 8 entradas do mic ficaram 48 kHz/16-bit/estéreo; o pin de captura virou
  estéreo (`MICIN_DEVICE_MAX_CHANNELS 2`, `KSAUDIO_SPEAKER_STEREO`, blockAlign 4)
  e os ranges de taxa foram fixados em 48000. Assim os dois endpoints só expõem
  um formato e o PCM cru no ring sempre casa.
- `apply-sysvad.ps1` falha de forma explícita se o upstream mudar (âncoras).

### Arquivos novos em `windows/driver/ntvad/`
`ntvad_loopback.h`, `ntvad_loopback.cpp`, `apply-sysvad.ps1`, `NTVad.inf`,
`build.ps1`, `install.ps1`; `windows/driver/README.md` reescrito; `.gitignore`
ignora `src/`, `sysvad/`, `build/`.

### Não verificado
- Instalação do driver e funcionamento em tempo real (o build assina, mas
  falta reiniciar com testsigning e correr `install.ps1`).
- Se o PortCls aceita o INF hand-written e a lista de formatos com entradas
  48 kHz duplicadas sem reclamar.

### Próximo passo
1. Reiniciar (testsigning já ativado) e correr `ntvad\install.ps1`.
2. Validar os dois endpoints em Configurações de Som (48 kHz/16/estéreo) e o
   pipeline completo app → ring → app de conferência.

## 9b. Sessão 4 — toolchain e build do driver (2026-11-24)

### Toolchain instalada
- VS 2022 Build Tools 17.14.45 (`C:\Program Files (x86)\Microsoft Visual
  Studio\2022\BuildTools`) + Windows SDK 10.0.26100 + WDK 10.1.26100.6584
  (`wdksetup.exe /q /features + /ceip off /norestart /log <log>`; o
  `winget install Microsoft.WindowsWDK` falhou com exit 1001).
- Componentes VS necessários (via `setup.exe modify --add ...`):
  `Component.Microsoft.Windows.DriverKit.BuildTools` (instala o PlatformToolset
  `WindowsKernelModeDriver10.0`) e
  `Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre` (o projecto
  exige libs Spectre — erro MSB8040). `Microsoft.VisualStudio.Component.WDK`
  não existe no catálogo do Build Tools.

### Pegadinhas de ambiente resolvidas no `build.ps1`
- Repo em `C:\Windows\System32`: ferramentas 32-bit do WDK (`stampinf`,
  `inf2cat`) são redirecionadas para SysWOW64 e falham ao escrever. Solução:
  espelhar `src` para `%TEMP%\ntvad-build` (robocopy /MIR) e compilar lá;
  `inf2cat` corre sempre num staging em `%TEMP%`.
- Usar MSBuild/signtool x64 (`Bin\amd64\MSBuild.exe`).
- KMDF headers ficam em `Windows Kits\10\Include\wdf\kmdf\1.x` (não em
  `Include\<ver>\wdf`).
- Compilar só `EndpointsCommon.vcxproj` + `TabletAudioSample.vcxproj`; a
  solução completa inclui APOs que precisam de ATL.
- O build produz `TabletAudioSample.sys`, copiado como `NTVad.sys`.

### Verificado nesta sessão
- `build.ps1 -TestSign` completo: `.sys` e `.cat` assinados (`signtool verify
  /pa` OK), INF reescrito para KMDF 1.35, `inf2cat` sem erros/avisos,
  `testsigning` ativado (`bcdedit` → Yes).
- Artefactos em `build\x64\Release\`: `NTVad.sys` (235 KB), `NTVad.inf`,
  `NTVad.cat`, `NTVad-test.pfx`.
- Correções de código: `ntvad_loopback.*` usa `UCHAR` (kernel não define
  `BYTE`); include do header no `adapter.cpp` movido para fora do
  `#ifdef SYSVAD_A2DP_SIDEBAND`.

## 10. Prompt sugerido para retomar com o assistente

> Estou retomando o port do NoiseTorch para Windows no fork
> `mig-5/NoiseTorch`, branch `windows-native`. Leia `HANDOFF-WINDOWS.md` e
> `windows/README.md`. O app já compila e roda no Windows (GUI + `ntdiag`);
> o pipeline WASAPI+RNNoise foi validado em modo monitoração. Agora quero
> [completar o driver NT-VAD a partir do sample SYSVAD / empacotar um
> instalador / adicionar captura de dispositivo por padrão na GUI].
