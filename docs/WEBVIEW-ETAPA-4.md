# Provedor WebView — Etapa 4

Data da validação: **2026-09-01**  
AVD: `NeoNews_API25_x86`  
Script: [`scripts/validation/Test-WebViewProvider.ps1`](../scripts/validation/Test-WebViewProvider.ps1)

## Resultado

O provedor `com.google.android.webview` está presente na imagem Google APIs API 25, mas a versão instalada não corresponde ao alvo do runtime:

| Campo | Resultado |
|---|---|
| Android | `7.1.1` |
| API | `25` |
| ABI do AVD | `x86` |
| Provedor | `com.google.android.webview` |
| Versão instalada | `55.0.2883.91` |
| Versão alvo | `119.0.6045.193` |
| Status | `version-mismatch` |

Comando executado:

```powershell
.\scripts\validation\Test-WebViewProvider.ps1 `
  -ReportPath .\reports\webview-etapa-4.json
```

O teste usa o ADB configurado em `runtime/adb/adb.exe` e o endpoint TCP
`127.0.0.1:5556`. Para exercitar conteúdo real, acrescente
`-ContentUrl https://example.com`; sem esse parâmetro o resultado cobre apenas
provider, versão, API e ABI.

Saída resumida:

```json
{
  "android": { "release": "7.1.1", "apiLevel": "25", "abi": "x86" },
  "provider": {
    "packageName": "com.google.android.webview",
    "expectedVersion": "119.0.6045.193",
    "installedVersion": "55.0.2883.91",
    "packagePresent": true,
    "versionMatches": false
  },
  "status": "version-mismatch"
}
```

## Decisão da etapa

**Etapa 4 concluída como validação do estado atual, com homologação bloqueada.** O runtime não deve declarar suporte ao WebView 119 até que seja fornecido um pacote `com.google.android.webview` compatível com API 25, instalado no AVD e validado por versão, assinatura e execução de uma página de teste.

O teste do WebView foi separado do APK NeoNews porque o APK continua sem caminho executável neste host por ser ARM-only. Portanto, este resultado mede somente a imagem Android base.
