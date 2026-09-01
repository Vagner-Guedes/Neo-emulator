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
