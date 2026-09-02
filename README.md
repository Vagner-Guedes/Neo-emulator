# NeoNews Runtime

Runtime Windows para sinalização digital com guest Android-x86 7.1.2/API 25, QEMU/WHPX, perfil de kiosk, launcher WPF, supervisor, diagnóstico e benchmark.

## Estado atual

O runtime está migrando para o backend QEMU x86_64 com disco persistente e ADB TCP. A homologação completa permanece pendente até que Android-x86 7.1-r5, Native Bridge ARM, WebView 119, RHVoice e o APK oficial sejam provisionados e testados no mesmo guest. O APK proprietário e demais componentes externos permanecem fora do Git.

Consulte [`docs/FINAL-REPORT.md`](docs/FINAL-REPORT.md) para evidências e pendências.

## Primeira execução

```powershell
.\scripts\provision\Provision-QemuAndroidRuntime.ps1 -RequireInstallerImage `
  -QemuOrigin "<origem aprovada/licenca do QEMU>" `
  -AdbOrigin "<origem aprovada/licenca do ADB>" `
  -AndroidImageOrigin "<origem aprovada/licenca da imagem Android-x86>"
```

Forneça o APK em `packages/neonews/neonews.apk` e execute os validadores:

Também é aceito colocar o arquivo fornecido como `app.apk` na raiz do repositório para execução local; a publicação não copia nem redistribui esse binário. Depois de publicar, o operador deve provisioná-lo separadamente em `packages/neonews/neonews.apk`; o botão “Iniciar sistema” tenta instalá-lo antes de abrir a atividade.

```powershell
.\scripts\validation\Test-NativeBridge.ps1
```

Para a evidÃªncia de estabilidade exigida pelo checklist final, execute com
uma janela prolongada (padrÃ£o mÃ­nimo de 600 segundos):

```powershell
.\scripts\validation\Test-NativeBridge.ps1 -StabilitySeconds 600 -RestartCount 1
```

Depois do provisionamento do guest, os probes de integração são executados
separadamente e falham sem declarar homologação quando falta evidência real:

```powershell
.\scripts\validation\Test-WebViewContent.ps1
.\scripts\validation\Test-TtsSynthesis.ps1
.\scripts\validation\Test-GuestNetworkMedia.ps1 -HlsUrl https://seu-host/aprovado/playlist.m3u8
.\scripts\validation\Test-QemuPersistence.ps1
.\scripts\benchmark\Run-QemuNeoNewsBenchmark.ps1 -Iterations 3 -StabilitySeconds 60
```

O probe de rede/mídia exige uma URL HLS aprovada pelo ambiente e valida apenas
o guest (DNS, HTTP/HTTPS, playlist, reprodução, cache e perda reversível da
NIC); a renderização do conteúdo proprietário do NeoNews continua sendo uma
etapa de homologação separada.

O launcher WPF pode ser compilado com o SDK local .NET 8:

```powershell
dotnet build .\launcher\NeoNews.Runtime.Launcher\NeoNews.Runtime.Launcher.csproj --configuration Release
```

## Executando o Runtime

O runtime profissional é `NeoNewsRuntime.exe`, uma aplicação WPF `WinExe` autocontida para `win-x64`. A operação normal não abre PowerShell nem terminal: ADB, QEMU e `schtasks.exe` são executados diretamente, com saída capturada em `logs/`.

Para publicar a distribuição final, consulte [`docs/BUILD.md`](docs/BUILD.md). O resultado fica em `dist/NeoNewsRuntime/` com o executável único e `config/runtime.json`. O APK proprietário continua opcional e externo; sem ele, o painel ainda abre e os estados reportam a dependência ausente.

O backend padrão é `qemu-android-x86`, com `-accel whpx`, ADB encaminhado de `127.0.0.1:5556` para a porta 5555 do guest e disco persistente em `runtime/android/neonews-api25.qcow2`. Esses caminhos são relativos ao diretório da distribuição e podem conter espaços.

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

Há uma única instância por usuário. Chamadas adicionais enviam o comando à instância existente via named pipe. Fechar a janela mantém o runtime no tray; o atalho global `Ctrl + Alt + Shift + F12` sai do kiosk e reabre o painel.
