# Build oficial do WebView 119

Este procedimento produz o WebView do NeoNews a partir exclusivamente da tag
`119.0.6045.193` do repositório oficial Chromium. Ele não baixa APK pronto,
não consulta mirror e não instala nada no guest.

O comando reproduzível é:

```powershell
.\scripts\build\Build-ChromiumWebView119.ps1 -Jobs 3
```

Para reutilizar a árvore oficial já sincronizada, mantendo o build isolado no
WSL e evitando uma nova sincronização:

```powershell
.\scripts\build\Build-ChromiumWebView119.ps1 -SkipSync -SkipHooks -Jobs 3
```

Parâmetros importantes:

- distribuição WSL: `Debian-NeoNews`;
- origem: `https://chromium.googlesource.com/chromium/src`;
- tag: `119.0.6045.193`;
- commit upstream da tag: `baf84c2d246a45577b7ddd2b8d8d2e2cf36e12e2`;
- arquivo de origem: `1367896317` bytes, SHA-256
  `de3b2b430a322e57e0515f69f42f5e348eccc86faa30a378295496914bb57164`;
- target: `system_webview_apk`;
- package: `com.android.webview`;
- ABI de build: `x86_64` (`target_cpu="x64"`), sem ABI secundária no CQ;
- `clang_use_default_sample_profile=false`, pois o snapshot público não
  contém `chrome/android/profiles/afdo.prof`; o perfil não é fabricado;
- build release oficial, não-component, sem branding Chrome e sem chaves
  oficiais do Google.

O relatório ignorado `reports/webview-build-119.json` registra os parâmetros,
origem, tamanho e SHA-256 de cada APK encontrado. O APK não deve ser
versionado. A instalação só pode ocorrer depois de validar package, versão,
assinatura, ABI e compatibilidade com a whitelist do guest em um novo overlay
descartável.

O build não altera `runtime/android/*.qcow2`, Native Bridge/Houdini, RHVoice,
WebView atualmente instalado, configurações pt-BR, relógio ou regras de
debloat. A homologação do provider e os testes de JavaScript, HTTPS, Power BI,
NeoNews, reboot, ciclos, Native Bridge e RHVoice são gates posteriores.
