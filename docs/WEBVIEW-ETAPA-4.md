# WebView — Etapa 4 / Chromium 119

**Data da auditoria:** 2026-09-03
**Branch:** `codex/neonews-runtime-homologation`
**Guest:** Android-x86 7.1.2 / API 25 / x86_64
**Tag Chromium alvo:** `119.0.6045.193`
**Commit da tag:** `baf84c2d246a45577b7ddd2b8d8d2e2cf36e12e2`

## Resultado atual

| Campo | Resultado |
|---|---|
| Provider efetivo observado | `com.android.webview` |
| WebView atual | `52.0.2743.100`, versionCode `275610060` |
| Provider exigido pelo build | `com.android.webview` |
| Versão exigida | `119.0.6045.193` |
| ABI do guest | `x86_64` (`ro.zygote=zygote64_32`) |
| ABI do WebView atual | `x86_64` + `x86` |
| Status | `BUILD_HOST_RESOURCE_REQUIRED` / BLOCKED |

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

## Preflight do host

O build não foi iniciado. A documentação oficial exige uma máquina Intel 64
bit com pelo menos 8 GB de RAM e 100 GB livres; mais de 16 GB de RAM é
altamente recomendado.

| Recurso | Exigido | Disponível | Resultado |
|---|---:|---:|---|
| RAM | 8 GB mínimo; >16 GB recomendado | 8,45 GB decimais / 7,87 GiB | marginal; abaixo do recomendado |
| Disco livre | 100 GB | 69,74 GB | insuficiente |
| WSL2 | distribuição Linux operacional | nenhuma instalada | incompleto |

Resultado obrigatório da meta: **`BUILD_HOST_RESOURCE_REQUIRED`**.

O checkout do Chromium, `depot_tools`, hooks e qualquer build foram
deliberadamente adiados. Não foi instalado um ambiente Linux parcial nem
baixado código pesado que não pudesse ser compilado com segurança neste host.

## Próximo gate

Liberar pelo menos 100 GB de disco e disponibilizar uma distribuição Linux
WSL2 ou um host Linux com pelo menos 8 GB de RAM (preferencialmente mais de
16 GB para o link release).
Depois disso, repetir o preflight, instalar apenas `depot_tools` oficial,
fazer checkout da tag exata, configurar `system_webview_apk`, gerar e
registrar o APK, e só então integrar em um novo overlay descartável.

O provider só poderá mudar para PASS depois de validar package, assinatura,
versionCode, ABI, provider efetivo, HTML/CSS/JavaScript moderno, HTTPS,
Power BI, NeoNews, reboot, Native Bridge e RHVoice.
