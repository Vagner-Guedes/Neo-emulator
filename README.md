# NeoNews Runtime

Runtime Windows para sinalização digital com guest Android 7.1.1/API 25, perfil de kiosk, launcher WPF, supervisor, diagnóstico e benchmark.

## Estado atual

O runtime base foi provisionado e validado. A homologação do NeoNews está bloqueada neste host porque o APK fornecido contém apenas `arm64-v8a` e `armeabi-v7a`, enquanto a imagem x86 não possui native bridge. O APK proprietário, WebView e RHVoice permanecem artefatos externos.

Consulte [`docs/FINAL-REPORT.md`](docs/FINAL-REPORT.md) para evidências e pendências.

## Primeira execução

```powershell
.\scripts\provision\Install-AndroidRuntime.ps1 -AcceptLicenses
.\scripts\provision\Create-Api25Avds.ps1
.\scripts\provision\Configure-NeoNewsAvd.ps1
```

Forneça o APK em `packages/neonews/neonews.apk` e execute os validadores:

```powershell
.\scripts\validation\Test-WebViewProvider.ps1 -StartEmulator -StopEmulator
.\scripts\validation\Test-TtsProvider.ps1 -StartEmulator -StopEmulator
.\scripts\runtime\Start-NeoNews.ps1 -StartEmulator -Launch
```

O launcher WPF pode ser compilado com o SDK local .NET 8:

```powershell
dotnet build .\launcher\NeoNews.Runtime.Launcher\NeoNews.Runtime.Launcher.csproj --configuration Release
```

## Executando o Runtime

O runtime profissional é `NeoNewsRuntime.exe`, uma aplicação WPF `WinExe` autocontida para `win-x64`. A operação normal não abre PowerShell nem terminal: ADB, Emulator e `schtasks.exe` são executados diretamente, com saída capturada em `logs/`.

Para publicar a distribuição final, consulte [`docs/BUILD.md`](docs/BUILD.md). O resultado fica em `dist/NeoNewsRuntime/` com o executável único e `config/runtime.json`. O APK proprietário continua opcional e externo; sem ele, o painel ainda abre e os estados reportam a dependência ausente.

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
