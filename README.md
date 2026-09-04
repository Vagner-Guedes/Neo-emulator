# NeoNews Runtime

Runtime Windows para sinalizacao digital com guest Android-x86 7.1.2/API 25, QEMU/WHPX, kiosk, launcher WPF, supervisor, diagnostico e benchmarks.

## Estado atual

O runtime usa backend QEMU x86_64 com disco persistente, ADB TCP privado e ferramentas empacotadas. A homologacao completa continua condicionada a WebView 119, Native Bridge ARM, RHVoice, NeoNews, estabilidade, publicacao e testes em PC limpo. APKs proprietarios e componentes externos permanecem fora do Git.

Consulte [docs/FINAL-HOMOLOGATION-REPORT.md](docs/FINAL-HOMOLOGATION-REPORT.md) para evidencias e pendencias.
Para a otimizacao controlada do guest e a protecao do RHVoice, consulte [docs/ANDROID-PACKAGE-OPTIMIZATION.md](docs/ANDROID-PACKAGE-OPTIMIZATION.md).

## Primeira execucao

```powershell
.\scripts\provision\Provision-QemuAndroidRuntime.ps1 -RequireInstallerImage `
  -QemuOrigin "<origem aprovada/licenca do QEMU>" `
  -AdbOrigin "<origem aprovada/licenca do ADB>" `
  -AndroidImageOrigin "<origem aprovada/licenca da imagem Android-x86>"
```

Forneca o APK em `packages/neonews/neonews.apk` e execute os validadores. O APK WebView homologado, quando disponivel, deve estar em `packages/webview/webview.apk` com manifesto, origem e SHA-256 registrados.

```powershell
.\scripts\validation\Test-NativeBridge.ps1
.\scripts\validation\Test-WebViewProvider.ps1
.\scripts\validation\Test-WebViewContent.ps1
.\scripts\validation\Test-TtsSynthesis.ps1
.\scripts\validation\Test-GuestNetworkMedia.ps1 -HlsUrl https://seu-host/aprovado/playlist.m3u8
.\scripts\validation\Test-QemuPersistence.ps1
```

Para a estabilidade integrada, use pelo menos 600 segundos no mesmo runtime publicado:

```powershell
.\scripts\validation\Test-RuntimeStability.ps1 `
  -ExecutablePath .\dist\NeoNewsRuntime\NeoNewsRuntime.exe `
  -DurationSeconds 600
```

## Build e execucao

O launcher pode ser compilado com o SDK local .NET 8:

```powershell
$dotnet = Join-Path $env:LOCALAPPDATA 'NeoNewsRuntime\dotnet-sdk\dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet)) { $dotnet = (Get-Command dotnet -ErrorAction Stop).Source }
& $dotnet build .\launcher\NeoNews.Runtime.Launcher\NeoNews.Runtime.Launcher.csproj --configuration Release
```

O runtime profissional e `NeoNewsRuntime.exe`, uma aplicacao WPF `WinExe`, autocontida para `win-x64`. A operacao normal nao abre PowerShell nem terminal; ADB, QEMU e tarefas de startup sao executados diretamente, com logs ao lado da distribuicao.

Para publicar, consulte [docs/BUILD.md](docs/BUILD.md). O resultado deve ficar em `dist/NeoNewsRuntime/` e conter `config/runtime.json`, `runtime/adb`, `runtime/qemu`, o Android provisionado, o qcow2 persistente e os pacotes autorizados.

O backend padrao e `qemu-android-x86`, com `-accel whpx`, transporte ADB `127.0.0.1:5556` para a porta 5555 do guest, servidor ADB privado em `127.0.0.1:5038` e QMP em `127.0.0.1:4445`.

Argumentos suportados:

```text
NeoNewsRuntime.exe --show
NeoNewsRuntime.exe --start
NeoNewsRuntime.exe --stop
NeoNewsRuntime.exe --restart
NeoNewsRuntime.exe --kiosk
NeoNewsRuntime.exe --exit-kiosk
NeoNewsRuntime.exe --diagnostics
NeoNewsRuntime.exe --autostart
NeoNewsRuntime.exe --exit
```

Ha uma unica instancia por distribuicao. Chamadas adicionais enviam comandos a instancia existente via named pipe. Fechar a janela mantem o runtime no tray; `Ctrl + Alt + Shift + F12` sai do kiosk e reabre o painel.
