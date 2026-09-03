# Relatorio Final de Homologacao - NeoNews Runtime V1

**STATUS GLOBAL: BLOCKED / NOT PRODUCTION READY**

**Data da evidencia:** 2026-09-03
**Branch:** `codex/neonews-runtime-homologation`
**Backend:** QEMU x86_64 + WHPX, Android-x86 7.1-r5, Android 7.1.2/API 25
**Tag de producao:** nao criada

## Conclusao executiva

A infraestrutura e os gates de validacao foram endurecidos, e a sessao ADB TCP
esta operacional no guest descartavel usado nesta rodada. O Native Bridge
oficial tambem foi executado em overlay separado do qcow2 base: o Android
confirmou `persist.sys.nativebridge=1`, `ro.dalvik.vm.native.bridge=libnb.so`,
`libhoudini.so` nao vazio e persistencia apos reboot do guest.

O V1 ainda nao pode ser homologado. A prova do APK NeoNews alcancou identidade,
ABI ARM, instalacao previamente existente, `primaryCpuAbi=armeabi-v7a` e
`TerminalActivity` em foreground por 60 segundos, mas o gate estrito de
estabilidade falhou porque o logcat capturou:

`chromium: Uncaught SyntaxError: Unexpected token ., source: https://vagner-guedes.github.io/powerbi/ (315)`

Esse erro e coerente com o provider WebView antigo observado no guest. O
provider configurado `com.google.android.webview` versao `119.0.6045.193` nao
esta instalado, portanto WebView/NeoNews permanece bloqueado.

O gate de voz tambem permanece bloqueado e protegido: o inventario live
encontrou apenas `com.svox.pico`, engine padrao `null`, locale `en-US` e
nenhum RHVoice. Nao houve sintese real aprovada, saida de audio ou debloat.

## Matriz de gates

| Gate | Resultado | Evidencia e limite |
| --- | --- | --- |
| Branch e checkpoint | PASS parcial | Branch correta; alteracoes desta rodada ainda precisam do checkpoint final. |
| QEMU x86_64 + WHPX | PASS observado | Processo live usa QEMU configurado com `-accel whpx`; o mesmo runtime deve ainda passar os ciclos completos. |
| Android 7.1.2/API 25 | PASS | Confirmado pelo guest live no relatorio Native Bridge. |
| ADB TCP `127.0.0.1:5556` | PASS | Serial online e root no guest usado pelos probes. |
| Rede guest, DNS, HTTP/HTTPS | PASS | Probe live: `dns=true`, `http=true`, `https=true`. |
| HLS, cache e offline | PASS parcial | HLS oficial de teste, cache e NIC QMP down/up passaram; isto nao prova ainda o conteudo real do NeoNews. |
| Native Bridge estrutural | PASS observado | Overlay descartavel, script presente, comandos oficiais com exit code 0, propriedades e `libhoudini.so` nao-zero confirmados. |
| Persistencia Native Bridge | PASS observado | Propriedades e artefatos persistiram apos reboot no mesmo overlay. Falta homologar o fluxo automatico de nova maquina. |
| APK NeoNews e assinatura | PASS observado | Package `com.in9midia.neonews.player`, versao `9.0.3`, versionCode `522`, assinatura e ABIs esperadas. |
| ARM32 / `primaryCpuAbi` | PASS observado | `primaryCpuAbi=armeabi-v7a`; `TerminalActivity` iniciou no overlay. |
| NeoNews estavel | BLOCKED | Janela de 60 s foi coletada, mas o logcat registrou erro Chromium/WebView; nao declarar estabilidade. |
| WebView 119 | BLOCKED | `com.google.android.webview` ausente; provider ativo, versao 119 e conteudo nao foram validados. |
| RHVoice pt-BR | BLOCKED / PROTECTED | RHVoice ausente; sintese e audio nao executados; Google/Pico nao foram desabilitados. |
| Debloat | NOT EXECUTED | Nenhum uninstall, `pm clear`, exclusao de arquivo, troca de engine ou alteracao de dados de voz. |
| Locale e timezone persistentes | NOT FULLY VALIDATED | Contratos existem; a homologacao live conjunta precisa concluir esse gate. |
| Superuser silencioso | PASS de configuracao / live parcial | Politica versionada para `com.in9midia.neonews.player`, allow permanente e notificacao desativada; falta repetir a prova em ciclo limpo. |
| Kiosk, watchdog, startup e tray | NOT TESTED end-to-end | Implementacao e contratos estaticos existem; fluxo integrado ainda nao foi aprovado. |
| Estabilidade de 600 s | NOT TESTED | A prova de 60 s nao substitui os 600 s exigidos. |
| Tres ciclos Start -> Ready -> QMP shutdown | NOT TESTED | Ainda nao executados como matriz completa do runtime final. |
| Build Release | PASS | .NET 8 Release: 0 warnings e 0 errors. |
| Regressao do repositorio | PASS | 33 scripts; parse/configuracao/contratos sem erros; nenhum artefato proprietario rastreado. |
| Publicacao zero-touch em nova maquina | BLOCKED | O launcher ainda aponta para o qcow2 base e os componentes externos nao podem ser incorporados sem origem/licenca de redistribuicao registrada. |

Um PASS observado de componente nao autoriza o PASS do V1. O status global
permanece BLOCKED enquanto WebView, RHVoice, conteudo real, estabilidade longa,
ciclos completos e publicacao reproduzivel nao tiverem evidencia conjunta.

## Evidencia Native Bridge e proveniencia

O qcow2 base usado como origem foi:

`runtime/android/adb-tcp-provisioned-api25.qcow2`
SHA-256: `F4AD7075326D78814128941F66F5FFCE0E93F6A054A11652FCF19020120A343B`

A validacao foi feita em uma copia descartavel:

`runtime/android/nativebridge-official-455658f4e32e4babb46230523e3ba718.qcow2`

O arquivo guest `/system/bin/enable_nativebridge` foi encontrado e seu
SHA-256 e `E5B59F57D1DEE568E2EEE0BAB09D84A1480C11BC5364737B193CFD6D53A4F4AA`.
O script espera os endpoints registrados no projeto:

| Variante | Arquivo esperado | URL direta esperada | Redirecionamento historico registrado |
| --- | --- | --- | --- |
| ARM32 `7_y` | `houdini.sfs` | `http://dl.android-x86.org/houdini/7_y/houdini.sfs` | `http://tinyurl.com/16f0ntql` |
| ARM64 `7_z` | `houdini.sfs` | `http://dl.android-x86.org/houdini/7_z/houdini.sfs` | `http://tinyurl.com/yee4xnfw` |

Artefatos usados, com origem allowlisted, nome, tamanho e SHA-256:

| Variante | Nome local | Tamanho | SHA-256 |
| --- | --- | ---: | --- |
| `7_y` | `packages/nativebridge/houdini7_y.sfs` | 37,728,256 bytes | `56FD08C448840578386A71819C07139122F0AF39F011059CE728EA0F3C60B665` |
| `7_z` | `packages/nativebridge/houdini7_z.sfs` | 37,253,120 bytes | `7EEDC42015E6FB84A11A406A099241EFCCC20D4E020D476335A5FDB6E69A33D2` |

O provisionador `scripts/provision/Provision-NativeBridgeOfficial.ps1` usa
somente essas origens, valida tamanho e hash, executa o mecanismo suportado
(`setprop persist.sys.nativebridge 1` e `enable_nativebridge`) e aborta com
`EXTERNAL_ARTIFACT_REQUIRED` quando um artefato oficial nao esta disponivel.
Nenhum mirror aleatorio foi procurado ou usado.

## Protecao absoluta do sistema de voz

A protecao definida pelo projeto foi mantida. O modo `Audit` inventaria os
packages relacionados ao RHVoice e os adiciona automaticamente a `critical`
antes de qualquer plano. O modo `Apply` exige evidencia fresca de RHVoice,
pt-BR, engine selecionada, sintese real e audio antes/depois de cada grupo;
em falha, faz rollback do grupo. As operacoes permitidas continuam limitadas
a `disable-user`; nao ha uninstall, `pm clear`, remocao de arquivos de voz ou
substituicao automatica da engine.

Na sessao atual, como RHVoice nao estava presente, nenhuma otimizacao foi
aplicada. Google TTS/Pico nao foram desabilitados. O resultado live foi
registrado em `reports/tts-provider-live-current.json` como
`missing-engine`, sem tentativa de mascarar a ausencia de sintese.

## Configuracoes persistentes do projeto

`config/runtime.json` e os servicos de configuracao versionados preservam:

- rede guest `eth0`, `10.0.2.15/24`, rota `10.0.2.2`, DNS `10.0.2.3` e `VIRT_WIFI=0`;
- politica Superuser para o package exato do NeoNews, allow permanente e
  notificacao desativada;
- backend QEMU/WHPX, API 25, serial/forwarding ADB e Native Bridge obrigatorio;
- exigencia de WebView `119.0.6045.193` e RHVoice `pt-BR` no fluxo comercial.

Esses contratos tornam as configuracoes reproduziveis no codigo. Contudo, a
publicacao atual nao possui os componentes externos necessarios para cumprir
o requisito de uma nova maquina somente com o APK do usuario. O Native Bridge,
WebView, RHVoice, imagem Android, QEMU/ADB e logs ficam fora do Git por
protecao legal, tamanho e seguranca; uma distribuicao zero-touch exige uma
origem/licenca explicita para cada artefato externo.

## Relatorios primarios desta rodada

- `reports/nativebridge-live-current.json`: Native Bridge e ABI, com falha
  estrita de estabilidade por erro Chromium.
- `reports/guest-network-media-live-current.json`: rede, HLS, cache e offline.
- `reports/webview-provider-live-current.json` e
  `reports/webview-content-live-current.json`: provider ausente e conteudo
  nao validado.
- `reports/tts-provider-live-current.json`: RHVoice ausente e sintese nao
  executada.
- `reports/runtime-repository-final-live.json`: contratos estaticos aprovados.

## Criterio para liberar o V1

Ainda faltam, no mesmo runtime e em uma execucao fresca:

1. provisionar WebView compativel e validar provider, HTML/CSS/JavaScript,
   HTTPS e pagina real do NeoNews;
2. provisionar RHVoice oficial e voz pt-BR, selecionar a engine, sintetizar
   audio real e confirmar saida antes de qualquer debloat;
3. corrigir o erro de compatibilidade de conteudo sem alterar o APK ou
   mascarar o logcat;
4. repetir Native Bridge + NeoNews depois de reboot, com TerminalActivity e
   logcat limpos;
5. executar estabilidade integrada de 600 s, tres ciclos completos, kiosk,
   watchdog, startup, tray, single-instance e persistencia;
6. produzir uma distribuicao legalmente redistribuivel e zero-touch, ou
   registrar os artefatos externos como pre-requisitos explicitos da instalacao.

Sem esses itens, o resultado oficial continua **BLOCKED / NOT PRODUCTION READY**.
