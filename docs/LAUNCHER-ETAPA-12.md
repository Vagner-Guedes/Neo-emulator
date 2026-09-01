# Launcher WPF — Etapa 12

Data: **2026-09-01**
Projeto: [`launcher/NeoNews.Runtime.Launcher/NeoNews.Runtime.Launcher.csproj`](../launcher/NeoNews.Runtime.Launcher/NeoNews.Runtime.Launcher.csproj)

## Escopo

O launcher WPF fornece uma superfície local para:

- iniciar o NeoNews pelo script de integração;
- aplicar o modo kiosk;
- coletar o baseline/diagnóstico do runtime;
- exibir stdout/stderr e o código de saída;
- encerrar o launcher.

Os scripts são invocados com `ProcessStartInfo.ArgumentList`, sem concatenar entrada do usuário em uma linha de comando. O launcher procura `config/runtime.json` subindo a partir do diretório de publicação, permitindo execução a partir de `bin` ou da pasta publicada.

## Validação

O SDK .NET 8 foi instalado localmente em `C:\Users\vagne\AppData\Local\NeoNewsRuntime\dotnet-sdk` pelo instalador oficial. A compilação deve ser executada com:

```powershell
& C:\Users\vagne\AppData\Local\NeoNewsRuntime\dotnet-sdk\dotnet.exe build `
  .\launcher\NeoNews.Runtime.Launcher\NeoNews.Runtime.Launcher.csproj `
  --configuration Release
```

O launcher não embute o APK, o WebView ou o RHVoice.

## Decisão da etapa

**Etapa 12 concluída como launcher WPF versionado.** A execução end-to-end do botão “Iniciar NeoNews” continua limitada pela ABI documentada na Etapa 3.
