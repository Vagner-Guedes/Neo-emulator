# Relatório final de homologação — NeoNews Runtime V1

**Status global: BLOCKED / NOT PRODUCTION READY**
**Data:** 2026-09-03
**Branch:** `codex/neonews-runtime-homologation`
**Runtime de prova:** QEMU x86_64 + WHPX, Android-x86 7.1-r5 / Android 7.1.2 / API 25, ADB TCP `127.0.0.1:5556`
**Overlay descartável:** `runtime/android/nativebridge-official-455658f4e32e4babb46230523e3ba718.qcow2`

## Resumo executivo

O Native Bridge oficial foi habilitado em uma cópia descartável do qcow2. O
APK ARM oficial do NeoNews instalou/permaneceu utilizável com
`primaryCpuAbi=armeabi-v7a`, e `TerminalActivity` foi observada em execução.

O RHVoice foi instalado a partir da origem aprovada, recebeu o idioma
brasileiro e a voz Letícia-F123. A ação real do NeoNews foi executada pelo
menu em português: `VERBALIZAR` chamou `RHVoiceService`, registrou
`tts_speak_success`, inicializou `AudioTrack` e informou `Texto verbalizado
com sucesso!`.

O Android agora é configurado como `pt-BR`, com fuso
`America/Sao_Paulo`. O launcher sincroniza o relógio com o Windows em cada
inicialização e o watchdog repete a correção periodicamente, porque o serviço
de hora desta imagem API 25 pode sobrescrever o RTC durante o boot.

O V1 ainda está bloqueado: o WebView exato `119.0.6045.193` não está
disponível no guest, o conteúdo Power BI ainda tem erro Chromium observado, e
as provas integradas de 600 s, três ciclos e publicação zero-touch ainda não
foram concluídas.

## Matriz de gates

| Gate | Resultado | Evidência / limite |
|---|---|---|
| QEMU + WHPX | PASS observado | QEMU live com `-accel whpx`; ainda falta ciclo comercial completo. |
| Android | PASS | Android 7.1.2, API 25, guest x86_64. |
| ADB TCP | PASS | `127.0.0.1:5556`, guest online e root durante a validação. |
| Rede guest | PASS observado | Ethernet/DNS/HTTP/HTTPS e HLS do probe passaram; conteúdo real ainda depende do WebView. |
| Native Bridge | PASS observado | `persist.sys.nativebridge=1`, `ro.dalvik.vm.native.bridge=libnb.so`, Houdini não vazio e persistência no overlay. |
| NeoNews ARM | PASS observado | Package `com.in9midia.neonews.player`, versão `9.0.3`/522, assinatura autorizada, `primaryCpuAbi=armeabi-v7a`. |
| TerminalActivity | PASS observado | Atividade em foreground; probe pós-RHVoice registrou estabilidade de 60 s com logcat limpo. |
| Verbalize real | PASS observado | Menu em pt-BR, `RHVoiceService`, `tts_speak_success`, `AudioTrack` e mensagem de sucesso. |
| RHVoice pt-BR | PASS observado / protegido | Engine padrão RHVoice; idioma e voz persistiram após reboot; síntese real aprovada. |
| Idioma Android | PASS observado | `persist.sys.locale=pt-BR` e `system_locales=pt-BR`, confirmados após reboot. |
| Horário Android = Windows | PASS por política | `America/Sao_Paulo`; sincronização host→guest implementada e validada com desvio de 0–3 s. |
| WebView 119 | BLOCKED | O guest aceita `com.android.webview`, mas só possui 52.0.2743.100; o build oficial 119 foi bloqueado por recursos do host. |
| Conteúdo Power BI | BLOCKED | Erro Chromium legado observado: `Unexpected token .` na página Power BI. |
| Debloat | NOT EXECUTED | Nenhum uninstall, `pm clear`, remoção de arquivo ou alteração de engine. |
| Superuser silencioso | Configuração PASS / toast não reprovado | Política NeoNews allow permanente, `notification=false`; recomenda-se repetir prova visual em ciclo limpo. |
| Kiosk/watchdog/startup/tray | NOT TESTED end-to-end | Contratos implementados; faltam provas integradas. |
| Estabilidade 600 s | NOT TESTED | A prova de 60 s não substitui a exigência de 600 s. |
| Três ciclos | NOT TESTED | Ainda não executados como matriz final. |
| Build Release | PASS | .NET SDK 8.0.424: 0 erros, 0 avisos. |
| Regressão do repositório | PASS | `Test-RuntimeRepository.ps1`: 33 scripts, 0 parse errors, 0 contract errors. |

## Native Bridge e artefatos oficiais

O script guest `/system/bin/enable_nativebridge` foi localizado; SHA-256:
`E5B59F57D1DEE568E2EEE0BAB09D84A1480C11BC5364737B193CFD6D53A4F4AA`.

| Variante | Arquivo esperado pelo mecanismo | URL esperada | Tamanho | SHA-256 |
|---|---|---|---:|---|
| ARM32 `7_y` | `houdini.sfs` | `http://dl.android-x86.org/houdini/7_y/houdini.sfs` | 37,728,256 | `56FD08C448840578386A71819C07139122F0AF39F011059CE728EA0F3C60B665` |
| ARM64 `7_z` | `houdini.sfs` | `http://dl.android-x86.org/houdini/7_z/houdini.sfs` | 37,253,120 | `7EEDC42015E6FB84A11A406A099241EFCCC20D4E020D476335A5FDB6E69A33D2` |

Os artefatos foram mantidos fora do Git. Nenhum mirror aleatório foi usado.

## RHVoice e proteção de voz

| Artefato | Origem | Tamanho | SHA-256 |
|---|---|---:|---|
| `packages/tts/rhvoice.apk` | [F-Droid RHVoice](https://f-droid.org/pt_BR/packages/com.github.olga_yakovleva.rhvoice.android/) / `https://f-droid.org/repo/com.github.olga_yakovleva.rhvoice.android_118040.apk` | 15,921,542 | `FDB0F7D6F3EC455477A84AA8CC86D1F2D580CB180D69A0C780240975C2EFD288` |
| `RHVoice-F123-Brazilian-Portuguese-language-v1.24.zip` | [release oficial RHVoice](https://github.com/RHVoice/Brazilian-Portuguese/releases/tag/1.24) | 148,609 | `76D4309902D8CBDD822EF16DE2E85BDED8E0E23EF9960FEF877DA5ED143806E6` |
| `Leticia-F123-v4.6.zip` | `https://rhvoice.org/download/Leticia-F123-v4.6.zip` | 21,363,986 | `E032EB268BB8B28523E40296D4A99908DBDBB5C65EF8F775279D202C897B23CA` |

O guest mantém o pacote principal RHVoice, o pacote de idioma
`com.github.olga_yakovleva.rhvoice.android.language.brazilian_portuguese.1240`
e o pacote de voz
`com.github.olga_yakovleva.rhvoice.android.voice.leticia_f123.4060`. Pico e
outras engines não foram desabilitados. A política de voz continua exigindo
engine, locale, síntese e bytes de áudio antes/depois de qualquer otimização;
em falha, o grupo deve sofrer rollback.

## Idioma, fuso e relógio

Configuração persistida em `config/runtime.json`:

```json
"runtime": {
  "timezone": "America/Sao_Paulo",
  "syncClockWithHost": true,
  "maxClockSkewSeconds": 5
}
```

O backend QEMU usa RTC UTC, apropriado para o kernel Linux do Android-x86.
Depois do boot, o launcher aplica `persist.sys.timezone`, desativa os ajustes
automáticos concorrentes, aplica o horário local do Windows e valida o epoch.
O watchdog repete a sincronização a cada 30 s enquanto o runtime estiver
ativo. A configuração de idioma usa `persist.sys.locale=pt-BR` e
`system_locales=pt-BR` antes de abrir o NeoNews.

## Evidência do Verbalize

O menu de opções exibiu `VERBALIZAR` em português. Após o clique, o logcat
registrou:

- vínculo bem-sucedido a `com.github.olga_yakovleva.rhvoice.android`;
- conexão com `com.github.olga_yakovleva.rhvoice.android.RHVoiceService`;
- locale TTS `por-BRA`;
- `AudioTrack` e atividade do `AudioFlinger`;
- `tts_speak_success`;
- `Texto verbalizado com sucesso!`;
- nenhum `FATAL`, `UnsatisfiedLinkError` ou erro de linker no recorte limpo.

Evidência primária: `reports/neonews-verbalize-live.json`.

## Meta Chromium 119 — preflight atual

A auditoria confirmou que o guest AOSP/API25 aceita `com.android.webview` pelo
recurso `framework-res.apk:res/xml/config_webview_packages.xml`. O provider
atual permanece preinstalado em `/system/app/webview/webview.apk`, versão
52.0.2743.100, com ABI `x86_64`/`x86`; ele não foi modificado.

A tag oficial Chromium `119.0.6045.193` resolve para o commit
`baf84c2d246a45577b7ddd2b8d8d2e2cf36e12e2`. Para este guest, o target
planejado é `system_webview_apk` com package `com.android.webview`; Trichrome
não será usado.

O build foi interrompido antes do checkout por falta de recursos no host:
7,87 GiB de RAM disponíveis contra o mínimo oficial de 8 GB e 69,74 GB livres
contra o mínimo oficial de 100 GB. O WSL2 existe, mas não possui distribuição
Linux instalada. Resultado obrigatório: **`BUILD_HOST_RESOURCE_REQUIRED`**.

Evidência detalhada: `reports/webview-build-preflight.json` e
[`docs/WEBVIEW-ETAPA-4.md`](WEBVIEW-ETAPA-4.md). Nenhum `depot_tools`, hook,
checkout Chromium, APK de terceiro ou mirror foi usado.

## Histórico da estratégia anterior: WebView Google

Arquivo esperado pelo provisionamento: `packages/webview/webview.apk`
Package esperado: `com.google.android.webview`
Versão esperada: `119.0.6045.193`
ABI nativa esperada: `x86`/`x86_64`
URL direta oficial pinável para esse APK exato: **não encontrada**. Foi
localizada a [página oficial do Google Play](https://play.google.com/store/apps/details?id=com.google.android.webview)
e a documentação oficial do [build do Android WebView](https://chromium.googlesource.com/chromium/src/%2Bshow/d66b8119aa23c5f10de05c408ea6835f45fba63c/android_webview/docs/build-instructions.md),
mas nenhuma URL pública direta que permita obter e validar exatamente o APK
Google assinado na versão solicitada. A integração AOSP do Android 119 está
documentada [aqui](https://chromium.googlesource.com/chromium/src/%2B/119.0.6045.199/android_webview/docs/aosp-system-integration.md).

Conforme a regra da meta, a busca parou nesse ponto; não foi usado APKMirror,
APKPure ou mirror aleatório. Não declarar WebView homologado enquanto o
provider efetivo, assinatura, ABI, versão e conteúdo real não forem validados.

## Próximos passos para liberar o V1

1. Liberar os recursos do host e disponibilizar WSL2 Ubuntu ou host Linux;
   depois fazer checkout oficial da tag e construir `system_webview_apk`.
2. Registrar o APK produzido, tamanho/SHA-256, assinatura, versionCode e ABI;
   integrar no mesmo qcow2 de prova e validar provider efetivo,
   JavaScript, HTTPS e a página Power BI do NeoNews.
3. Rerodar Native Bridge, RHVoice e `VERBALIZAR` no mesmo ciclo limpo.
4. Executar 600 s com conteúdo real, watchdog e kiosk ativos.
5. Executar três ciclos completos, persistência após reboot/Windows e
   atualização `adb install -r` sem perda de dados.
6. Repetir a prova visual do toast de Superuser e finalizar a publicação
   zero-touch somente com artefatos cuja redistribuição esteja autorizada.

Até isso, o resultado oficial permanece **BLOCKED / NOT PRODUCTION READY**.
