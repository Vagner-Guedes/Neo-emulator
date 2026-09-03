# Provedor WebView — Etapa 4

**Data da validação:** 2026-09-03
**Guest:** Android-x86 7.1.2 / API 25 / x86_64
**Script:** [`scripts/validation/Test-WebViewProvider.ps1`](../scripts/validation/Test-WebViewProvider.ps1)

## Resultado

| Campo | Resultado |
|---|---|
| Provider exigido | `com.google.android.webview` |
| Versão exigida | `119.0.6045.193` |
| ABI exigida | x86/x86_64 |
| Provider/versão exigidos no guest | Ausentes |
| Status | `missing-provider` / BLOCKED |

O NeoNews chegou a carregar o provider legado do sistema
`com.android.webview` 52.0.2743.100, mas isso não atende à versão exigida.
Também foi observado erro Chromium na página Power BI (`Unexpected token .`),
portanto o conteúdo real não foi aprovado.

## Regra de aquisição

Arquivo esperado: `packages/webview/webview.apk`. Não foi encontrada uma URL
oficial pública direta e pinável para o APK Google assinado exatamente em
`119.0.6045.193`. Foram consultadas a [página oficial do Google Play](https://play.google.com/store/apps/details?id=com.google.android.webview),
as [instruções oficiais de build do Chromium WebView](https://chromium.googlesource.com/chromium/src/%2Bshow/d66b8119aa23c5f10de05c408ea6835f45fba63c/android_webview/docs/build-instructions.md)
e a [integração AOSP do Chromium 119](https://chromium.googlesource.com/chromium/src/%2B/119.0.6045.199/android_webview/docs/aosp-system-integration.md).

Como a origem direta exata não está disponível, a aquisição parou conforme a
regra definida. Nenhum APKMirror, APKPure ou mirror aleatório foi utilizado.
Não instalar um arquivo aproximado e não declarar provider homologado apenas
por nome de pacote.

## Próximo gate

Obter o APK oficial/licenciado exato, registrar origem, tamanho e SHA-256,
instalar no mesmo overlay e validar `dumpsys webviewupdate`, package, versão,
assinatura, ABI, HTML/CSS/JavaScript, HTTPS e o conteúdo real do NeoNews.
