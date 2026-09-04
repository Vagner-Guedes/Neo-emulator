# WebView — Etapa 4 / Chromium 119

**Data da auditoria:** 2026-09-03
**Branch:** `codex/neonews-runtime-homologation`
**Guest:** Android-x86 7.1.2 / API 25 / x86_64
**Tag Chromium alvo:** `119.0.6045.193`
**Commit da tag:** `baf84c2d246a45577b7ddd2b8d8d2e2cf36e12e2`

## Evidence update — continuous stability gate — 2026-09-04

The provisional statement later in this document that the 600-second gate was
pending is superseded by the continuous run recorded in
`reports/webview-integration-119-stability-600s.json`.

| Gate | Result |
|---|---|
| Continuous stability window | PASS — 600 seconds, 120 samples |
| QEMU process / ADB / boot | PASS — 0 failure samples |
| NeoNews process | PASS — PID remained `3423` in every sample |
| `TerminalActivity` foreground | PASS — 0 focus failures |
| Restart cycles | PASS — 3 cycles completed before the continuous window |
| Logcat fatal crash indicators | PASS — no fatal exception, linker failure, native signal or ANR |

The filtered logcat still contains known Android-x86/Chromium compatibility
warnings: Houdini initialization is successful, while Chromium reports a
missing variations seed and Android API 25 reports unavailable optional
WebView classes (`PacProcessor` and `WebViewRenderProcessClient`). These
warnings were retained in
`reports/webview-integration-119-stability-600s.logcat-filtered.txt`.

This gate does not by itself change the overall release decision to production;
the remaining media/HLS, recovery, kiosk/watchdog, startup, packaging and
zero-touch gates must still be completed.

## Resultado anterior (baseline do guest)

| Campo | Resultado |
|---|---|
| Provider efetivo observado | `com.android.webview` |
| WebView atual | `52.0.2743.100`, versionCode `275610060` |
| Provider exigido pelo build | `com.android.webview` |
| Versão exigida | `119.0.6045.193` |
| ABI do guest | `x86_64` (`ro.zygote=zygote64_32`) |
| ABI do WebView atual | `x86_64` + `x86` |
| Status | `PREBUILT_DOWNLOAD_CHANNEL_BLOCKED` / `NOT HOMOLOGATED` |

## Recuperação do prebuilt e integração parcial — 2026-09-04

O WebView pré-compilado foi obtido sem compilar Chromium e validado antes de
qualquer promoção:

| Campo | Resultado |
|---|---|
| Pacote | `com.google.android.webview` |
| Versão / código | `119.0.6045.193` / `604519307` |
| Tamanho | `264477175` bytes |
| SHA-256 do arquivo | `5e49148fc2b369edc6b1bcc311d7b4ae6f4d5fc20f3a5971ae12792c77b6d167` |
| Certificado SHA-256 | `6faf3c4140407473400934d117815a21af1cfefc5c0bee61c858bc3d72ba6fe5` |
| ABIs | `x86_64` e `x86` |
| API | min `24`, max `28`, target `34` |
| Validação APK | v2, v3 e SourceStamp: PASS |
| Arquivo local | `packages/webview/webview.apk` |

No overlay descartável `runtime/android/webview-integration-119.qcow2`, o
provider foi ativado por `cmd webviewupdate` com retorno `Success` após a
whitelist do framework. O probe real passou HTML, CSS, JavaScript, HTTPS e
conteúdo remoto. O NeoNews iniciou com `primaryCpuAbi=armeabi-v7a`, Native
Bridge `libnb.so` e permaneceu 60 segundos em `TerminalActivity`. RHVoice e
pt-BR permaneceram selecionados; a síntese gerou WAV não vazio.

O estado ainda não é produção: o teste de 600 segundos e três ciclos completos
de restart não foram concluídos. O log registra fallback sem RELRO e avisos
de compatibilidade Chromium (`PacProcessor`, seed/cache); eles foram
registrados nas evidências e não foram ocultados.

Evidência consolidada: `reports/webview-prebuilt-119.json`.

## Atualização da tentativa automatizada de prebuilt

**Data/hora:** `2026-09-03 23:30:06 -03:00`

Estado desta tentativa: `PREBUILT_WEBVIEW_PROVIDER_BLOCKED`. Nenhum APK
WebView foi baixado, promovido para `packages/webview/webview.apk` ou
instalado. O guest não foi iniciado nem alterado nesta tentativa.

Artefato exato esperado:

- nome: `com.google.android.webview_119.0.6045.193-604519307_minAPI24_maxAPI28(x86,x86_64)(nodpi)_apkmirror.com.apk`;
- package: `com.google.android.webview`;
- versão: `119.0.6045.193`;
- versionCode: `604519307`;
- variante: `x86 + x86_64`, `nodpi`, Android 7.0+/API 24+;
- tamanho esperado: `264477175` bytes;
- SHA-256 esperado do arquivo: `5e49148fc2b369edc6b1bcc311d7b4ae6f4d5fc20f3a5971ae12792c77b6d167`;
- SHA-256 esperado do certificado: `6faf3c4140407473400934d117815a21af1cfefc5c0bee61c858bc3d72ba6fe5`.

URL de origem esperada pelo artefato: [página exata do APKMirror](https://www.apkmirror.com/apk/google-inc/android-system-webview/android-system-webview-119-0-6045-193-release/android-system-webview-119-0-6045-193-7-android-apk-download/).

Motivo exato da falha: uma tentativa anterior retornou um nonce de download
expirado (`redirected=thank_you_invalid_nonce`). Nesta nova tentativa, o
navegador normal gerou o redirect `download.php` com chave temporária, mas a
requisição do download retornou HTTP `403`, `Server: cloudflare` e
`Cf-Mitigated: challenge`, exigindo a barreira normal de JavaScript/cookies.
O Chrome instalado também foi executado com um perfil temporário isolado e
com comportamento normal; recebeu a página `Attention Required! | Cloudflare`
com a mensagem de bloqueio. O perfil temporário foi removido ao final.
O host `download.apkmirror.com` também não resolveu por DNS durante a
tentativa.
O Google Play fornece a listagem atual, mas não um APK histórico pinável
desta versão; o prebuilt AOSP localizado era `119.0.6045.141`, portanto foi
rejeitado por não corresponder ao alvo. Nenhum mirror aleatório foi usado e
nenhuma barreira foi contornada.

Na auditoria corretiva adicional, foram pesquisados os APKs do repositório,
Desktop, Downloads, Documents, outro checkout em `E:\Neo-emulator`, Temp,
cache do Chrome, cache do Edge e Packages do usuário. Foram encontrados 16
APKs, mas nenhum com o nome, tamanho ou hash do alvo. O cache continha apenas
arquivos de diagnóstico, o APK de teste e o WebView legado de
`123009916` bytes com hash `fb5cec22e4cdd8282a7474bbfdade7cfc65aef824795d22731df4d4c38548ebe`.
As consultas públicas por nome completo e SHA-256 não localizaram uma cópia
adicional verificável; variantes `604519306`, `604519301`, `604519338` e
outras versões foram rejeitadas por ABI, API, bundle ou versionCode.

A busca oficial e conhecida foi esgotada para este caminho. Por isso não foi
possível validar package, versionName, versionCode, minSdk, targetSdk, ABIs,
assinatura, tamanho e SHA-256 localmente, e o fallback de compilação não foi
iniciado enquanto o host WSL/armazenamento continua sem capacidade operacional
validada. O APK de teste `tools/webview-probe/build/webview-probe.apk` não é
um WebView e não foi considerado.

## Reavaliação do caminho preferencial — APK pré-compilado

| Item | Resultado |
|---|---|
| Arquivo esperado | `packages/webview/webview.apk` |
| Presença no repositório/distribuição | AUSENTE |
| Presença em `Downloads`/`Desktop` pesquisados | AUSENTE |
| Package/version/ABI/certificado/hash do pré-compilado | NÃO APLICÁVEL; nenhum APK foi encontrado |
| URL oficial direta pinável para o APK Google exato | NÃO ENCONTRADA |
| Instalação ou alteração do guest | NÃO EXECUTADA |

O caminho A foi encerrado sem usar mirror, APK de terceiro ou pacote ARM via
Houdini. Não há arquivo válido para executar a inspeção de `packageName`,
`versionName`, `versionCode`, `minSdk`, `targetSdk`, ABIs, assinatura, tamanho
e SHA-256.

O inventário live read-only foi tentado por um servidor ADB foreground privado
em `127.0.0.1:5038`. O endpoint `127.0.0.1:5556` recusou a conexão
(`10061`), e o servidor privado foi encerrado por PID exato; 5038 ficou livre.
O inventário histórico deste documento continua sendo a única evidência do
provider legado e não foi atualizado com inferência.

## Histórico do fallback de build

O registro histórico anterior havia usado `SOURCE_BUILD_REQUIRED`. A meta
corretiva vigente não classifica essa etapa como `SOURCE_BUILD_REQUIRED`; o
estado atual é `PREBUILT_DOWNLOAD_CHANNEL_BLOCKED`. O build não foi iniciado:
a distro
`Debian-NeoNews` está em `D:\WSL\Debian-NeoNews`, mas não respondeu nem a
`echo WSL_OK` após `wsl --shutdown`. O host tem aproximadamente 7,87 GiB de
RAM, D: tem aproximadamente 99,53 GiB livres e E: aproximadamente 242,09 GiB;
o VHDX da distro permanece em D: e não foi movido/desregistrado
automaticamente. Resultado operacional: `BUILD_HOST_IO_BOTTLENECK`.

Nenhum GN/Ninja/Chromium foi iniciado nesta tentativa, nenhum APK foi
produzido e nenhum componente do guest foi alterado. O próximo passo é usar
um host Linux/WSL responsivo com armazenamento suficiente, mantendo o build
no ext4, ou disponibilizar um APK WebView 119 oficial e verificável em
`packages/webview/webview.apk`.

O guest confirmou Android 7.1.2/API25, `com.android.webview` em
`/system/app/webview/webview.apk`, marcado como pacote de sistema. O provider
configurado em `settings global webview_provider` é `com.android.webview`.
`dumpsys webviewupdate` não produz texto útil nesta imagem, mas o serviço
`android.webkit.IWebViewUpdateService`, o comando `cmd webviewupdate` e a
configuração global estão presentes.

## Inventário não mutante do WebView 55

| Item | Valor |
|---|---|
| APK | `/system/app/webview/webview.apk` |
| Tamanho | `123009916` bytes |
| SHA-256 | `fb5cec22e4cdd8282a7474bbfdade7cfc65aef824795d22731df4d4c38548ebe` |
| Assinatura | Android-x86; certificado SHA-256 `67:03:6F:F3:DE:C3:9A:DF:32:AE:28:E8:F3:F9:4B:2C:1A:EC:69:0A:C8:AA:DF:68:15:92:E0:E3:60:BE:2F:02` |
| Código nativo | `primaryCpuAbi=x86_64`, `secondaryCpuAbi=x86` |
| Arquivos oat | `/system/app/webview/oat/x86/webview.odex` e `/system/app/webview/oat/x86_64/webview.odex` |
| Status system | `SYSTEM HAS_CODE`; APK preinstalado em `/system` |
| Estado User 0 | `installed=true`, `enabled=0` |

O `config_webview_packages.xml` não existe como arquivo separado. O recurso
equivalente foi localizado dentro de `/system/framework/framework-res.apk` em
`res/xml/config_webview_packages.xml`; a whitelist decodificada contém
`com.android.webview`. `com.google.android.webview` não está instalado.

O APK 52 e seus arquivos oat não foram apagados, desabilitados, substituídos
ou modificados. O rollback continua disponível no overlay descartável
`runtime/android/nativebridge-official-455658f4e32e4babb46230523e3ba718.qcow2`.

## Fonte oficial e decisão de target

A tag foi consultada exclusivamente em
`https://chromium.googlesource.com/chromium/src` e resolve para o commit
`baf84c2d246a45577b7ddd2b8d8d2e2cf36e12e2`.

A documentação oficial da própria tag recomenda `monochrome_public_apk` para
N-P, mas esse target usa `org.chromium.chrome` por padrão. A mesma
documentação informa que `system_webview_apk` usa `com.android.webview` e que
esse package é o permitido por padrão em AOSP N-P. Portanto, para este guest,
o target planejado é `system_webview_apk`, com `target_os="android"` e
`target_cpu="x64"`; Trichrome não será usado. Os demais GN args só serão
aceitos após validação pelo `gn args --list` da própria tag.

Referências oficiais:

- [WebView build instructions da tag 119.0.6045.193](https://chromium.googlesource.com/chromium/src/+/119.0.6045.193/android_webview/docs/build-instructions.md)
- [WebView quick start da tag 119.0.6045.193](https://chromium.googlesource.com/chromium/src/+/119.0.6045.193/android_webview/docs/quick-start.md)
- [Android build instructions da tag](https://chromium.googlesource.com/chromium/src/+/119.0.6045.193/docs/android_build_instructions.md)
- [Linux build instructions da tag](https://chromium.googlesource.com/chromium/src/+/119.0.6045.193/docs/linux/build_instructions.md)

## Preflight e host de build

O host é Intel 64-bit com 8,45 GB de RAM decimal / 7,87 GiB, WSL2 funcional
(`Debian-NeoNews`) e baixa paralelização. O checkout, `depot_tools`, SDK/NDK e
hooks foram obtidos pelas fontes oficiais do Chromium/CIPD/Google Storage.

O requisito oficial de build é pelo menos 100 GB livres (mais de 16 GB de RAM
é recomendado). No momento do bloqueio, o volume D: tinha 81.633.284.096
bytes livres (aprox. 76,0 GiB), abaixo do requisito. O VHDX também apresentou
latência extrema: leituras de poucos megabytes demoraram dezenas de segundos.

O GN foi gerado com sucesso em
`/home/neonews/chromium/out/NeoNewsWebView119` e o Ninja iniciou
`system_webview_apk`, mas ficou preso em `folio_`/`wait_on_buffer` durante
três retomadas. A distribuição foi encerrada de forma controlada para não
deixar processos zumbi; a árvore e o cache permanecem no WSL. Nenhum APK foi
produzido ou instalado. O resultado é
`BUILD_HOST_RESOURCE_REQUIRED / NOT HOMOLOGATED`.

## Próximo gate

Liberar pelo menos 100 GB reais no volume do build e corrigir a latência do
VHDX (ou usar host Linux/WSL com armazenamento mais rápido). Depois retomar o
build e registrar o APK, tamanho e SHA-256 em
`reports/webview-build-119.json`. Em seguida, validar package,
versionName/versionCode, assinatura e ABI antes de integrar somente em um
novo overlay descartável. O provider efetivo permanece inalterado durante
essa etapa.

O provider só poderá mudar para PASS depois de validar HTML/CSS/JavaScript
moderno, HTTPS, Power BI, NeoNews, reboot, Native Bridge/Houdini e RHVoice,
incluindo síntese real, locale pt-BR, relógio sincronizado, três ciclos e
600 segundos de estabilidade.
