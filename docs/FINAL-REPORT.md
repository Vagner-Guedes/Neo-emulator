# Relatório final — NeoNews Runtime

Data da atualização: **2026-09-02**

## Estado executivo

O projeto agora possui o caminho de runtime preparado para a homologação funcional do APK ARM oficial, sem modificar, recompilar, resignar ou substituir o APK. O backend padrão foi migrado para **QEMU x86_64 + WHPX**, com Android-x86 7.1.2/API 25, disco persistente, janela gráfica identificável e ADB sobre TCP.

**Status atual: NÃO HOMOLOGADO.** A infraestrutura local foi implementada e provisionada: ISO oficial Android-x86 7.1-r5 validada por SHA-1 (`1E65CB2E37B415576939398BAF4C8A92330FBB24`), QEMU x86_64, ADB Platform Tools e disco qcow2 persistente estão presentes com hashes registrados. O smoke direto do QEMU com WHPX, firmware portátil, IDE qcow2, e1000 e QMP passou; `qemu-img check` não encontrou erros. No teste live, a interface Android iniciou, mas a sessão ADB TCP permaneceu `offline` após as tentativas de adbd, reinício e variantes de rede. Native Bridge, WebView 119 e RHVoice continuam sem provisionamento/evidência de guest, portanto não há evidência honesta de execução do NeoNews no novo runtime.

Os gates de instalação, ABI, kiosk e provisionamento foram deliberadamente
endurecidos nesta rodada: o launcher não transforma um pacote já presente em
evidência de `adb install -r`, não infere ABI a partir da configuração, exige
um registro prévio de provisionamento e restaura o guest se a entrada em kiosk
falhar.

## Alterações verificadas

| Área | Evidência | Resultado |
|---|---|---|
| Backend | `IAndroidRuntimeBackend`, `QemuAndroidRuntimeBackend` e compatibilidade legada | implementado |
| QEMU | `-accel whpx`, qcow2 persistente, forwarding ADB, QMP e título `NeoNews Android Runtime` | implementado; smoke direto aprovado; guest live não homologado |
| ADB | transporte `tcp`, serial configurável `host:port`, `start-server`, `connect`, retry e estados fortes | implementado; ferramenta local presente; sessão guest `offline` |
| Configuração | `schemaVersion=2`, migração de schema 1 com backup `.bak`, caminhos relativos | validado por JSON |
| Native Bridge | coleta de `ro.dalvik.vm.native.bridge`, ABI list, `primaryCpuAbi`, manifesto, ABIs e certificado X.509 antes da instalação | implementado; não homologado |
| NeoNews | APK local preservado, `adb install -r`, confirmação da activity e validação de versão | implementado; não executado neste backend |
| Persistência | qcow2 externo, estado obrigatório em `runtime/state/provisioning.json` e hash forte preservado | implementado; imagem íntegra; reinício/marcador ainda não homologados |
| WebView/TTS | provider ativo, ABI nativa, versão esperada, conteúdo HTML/CSS/JavaScript/HTTPS e síntese real são pré-condições do fluxo completo | implementado; não homologado |
| Otimização Android | inventário real, política descoberta, snapshot, debloat reversível e proteção RHVoice antes/depois de cada grupo | implementado; não executado sem guest |
| Rede/mídia/offline | probe local para DNS, HTTP/HTTPS, HLS/MediaPlayer, cache e NIC QMP reversível | implementado; não executado sem guest provisionado |
| Kiosk | serviço existente usa o contrato do backend, valida geometria/estilo da janela e restaura configurações | compilado |
| Watchdog | distingue activity perdida, ADB offline e backend morto; cooldown, limite de tentativas e bloqueio de loop de reinstalação | compilado |
| Zero-console | QEMU/ADB iniciados por `ProcessStartInfo` invisível; GUI Android permitida | smoke test do launcher aprovado |
| Build | SDK local .NET 8.0.424 / host .NET 8.0.30, `Release` | 0 erros, 0 avisos; publicação atual verificada |
| Regressão | `Test-RuntimeRepository.ps1` | 31 scripts, JSON e ignore checks aprovados |
| Launcher | `NeoNewsRuntime.exe --show` e `--exit` | janela WPF criada, handle válido, 0 processos residuais |
| Diagnóstico | `NeoNewsRuntime.exe --diagnostics` | relatório ampliado com integridade, WHPX, ABI, guest, memória, gráficos e logcat filtrado |
| Publicação | `Publish-NeoNewsRuntime.ps1` em diretório de verificação | layout portátil criado; pacotes proprietários não são copiados nem incorporados |
| Checklist | `Test-HomologationChecklist.ps1` | 31 gates agregados; pendências nunca viram aprovação |
| Estabilidade integrada | `Test-RuntimeStability.ps1` | runner de 600 s para backend, ADB, NeoNews, watchdog, kiosk, WebView, TTS, conteudo real e logcat; pendente sem guest |

## Verificacao local desta rodada

A publicação de verificação `dist/NeoNewsRuntime-current` foi gerada depois do build Release e passou pelo smoke do executável publicado. O relatório registrou janela WPF responsiva, single-instance, CLI, `--exit`, caminho com espaços e ausência de processos residuais; os campos manuais de console, tray e hotkey foram registrados explicitamente. A coleta fresca `--diagnostics` também terminou com exit code 0 e registrou o backend/serial configurados, WHPX disponível, a ISO Android-x86 validada e os demais arquivos externos ausentes.

Na validação de 2026-09-02, `reports/diagnostics.json` e `reports/launcher-smoke.json` foram regenerados contra a mesma publicação `dist/NeoNewsRuntime-current`; a identidade de publicação passou a coincidir. O diagnóstico confirmou QEMU 11.1.0, WHPX disponível, ISO, qcow2 e ADB presentes, mas registrou `android.adb.online=false` e estado `Offline`. O checklist fresco (`reports/homologation-checklist.json`) permanece `not-approved`, com 0 gates pass, 19 fail e 12 pending; essa contagem não é convertida em aprovação por heurística.

O smoke direto do QEMU também foi executado com `-accel whpx`, `-L runtime/qemu/share`, firmware `bios-256k.bin`, máquina `pc`, disco IDE qcow2, NIC e1000, forwarding `127.0.0.1:5556` para a porta 5555 do guest e QMP. A negociação QMP, o envio de `quit` e a saída sem kill forçado foram observados nesse smoke; a imagem permaneceu válida no `qemu-img check`. Isso não substitui a prova de uma sessão ADB online nem a homologação funcional do guest.

No probe adicional do guest, a chave pública ADB do host foi instalada somente em uma sessão QEMU `-snapshot`: o arquivo `/data/misc/adb/adb_keys` retornou 700 bytes, modo `600` e SHA-256 `7465959a33569cca0a945ca5028ff13a4181c500d15b9ca9557407c613009867`, coincidente com a chave pública do host. Mesmo assim, após `persist.adb.tcp.port=5555`, `service.adb.tcp.port=5555`, reinício do serviço e execução manual de `adbd -a`, o host continuou em `offline`/falha de conexão. O listener `tcp6 :::5555` e o forwarding QEMU foram observados; o bloqueio restante está no comportamento do `adbd`/guest, não em pacote ou conteúdo de voz.

Em uma sessão live `-snapshot` separada, o forwarding foi declarado explicitamente para `10.0.2.15:5555`. Com o `adbd` parado, um `nc` no guest recebeu o banner `CNXN` enviado por `adb connect 127.0.0.1:5558`; com o `adbd` restaurado, `adb devices` continuou reportando `127.0.0.1:5558 offline`. Esse controle elimina o destino implícito do `hostfwd` como causa do bloqueio e não justifica alterar o contrato do backend.

Também foi testado, em sessão independente, o destino `127.0.0.1:5555` no guest. O `adb connect 127.0.0.1:5559` falhou sem estabelecer transporte, enquanto o destino `10.0.2.15` recebeu o `CNXN`; a configuração loopback foi descartada e não substituiu o forwarding atual.

Como controle adicional, o `kernel` e o `initrd` oficiais foram iniciados diretamente com o parâmetro `qemu=1`. O guest confirmou `ro.kernel.qemu=1`, mas, após configurar a NIC, reiniciar o `adbd` e reconectar por `127.0.0.1:5561`, o estado permaneceu `offline`. Portanto, esse modo de boot também não constitui correção funcional e não foi incorporado ao backend padrão.

O benchmark reproduzível de 2026-09-02 (`reports/qemu-benchmark-probe.json`) percorreu o launcher real e terminou como `boot-timeout`, sem declarar aprovação: `adb.ready=false` e `adb.booted=false`. Ainda assim, a sessão QEMU terminou com `qmpCapabilitiesSucceeded=true`, `qmpQuitSent=true`, `qmpQuitResponseSucceeded=true`, `qmpShutdownSucceeded=true` e `forcedKill=false`. O ajuste do benchmark também passou a resolver o QEMU relativo ao repositório e a capturar stderr nativo do ADB sem interromper a coleta no Windows PowerShell 5.1.

Os probes `Test-WebViewProvider.ps1` e `Test-TtsProvider.ps1` agora usam por padrão os nomes de relatório consumidos pelo checklist (`webview-provider.json` e `tts-provider.json`), e invalidam esses arquivos antes de qualquer pré-voo. O smoke do launcher também grava, por padrão, ao lado do executável que foi testado; o checklist compara esse diretório com o diagnóstico e com a estabilidade integrada quando ambos existem, evitando misturar publicações diferentes.

O diagnóstico do launcher também conserva o exit code e a saída resumida do último `adb start-server`, `connect`, `disconnect` ou `get-state`. Isso torna observável a diferença entre conexão recusada, autorização pendente e transporte `offline`, sem transformar estado de falha em sucesso.

O launcher lê o AndroidManifest AXML e as ABIs do APK antes do `adb install -r`;
rejeita package, versionName, versionCode, ausência de `armeabi-v7a` e qualquer
ABI x86/x86_64. O probe de Native Bridge também valida o certificado X.509 v1
contra a fingerprint configurada antes da instalação. Esses parsers foram
exercitados contra o `app.apk` local e encontraram `com.in9midia.neonews.player`,
`9.0.3`, `522`, `arm64-v8a`, `armeabi-v7a` e fingerprint compatível.

O pacote publicado contem zero arquivos em `packages/`; APK oficial, Native Bridge, WebView, RHVoice e demais dependencias externas continuam fora da distribuicao e do Git. Essa verificacao local nao substitui a execucao do guest.

O provisionamento base agora exige origem registrada para QEMU, ADB e a
imagem Android quando solicitada; o boot rejeita estado sem essa proveniencia
ou sem SHA-256 forte. A instalacao opt-in de Native Bridge, WebView e RHVoice
continua exigindo origem/licenca por componente.

O checklist final agora exige evidencia Native Bridge com janela minima de 600 segundos, identidade do manifesto do APK e exit codes zero nos comandos criticos de instalacao, launch e probes. A estabilidade integrada tambem exige observacao explicita de conteudo real do NeoNews em reproducao no mesmo executavel publicado. No ambiente atual, o checklist permanece `not-approved` porque o transporte ADB live está `offline`, a sessão de guest não foi confirmada e Native Bridge, WebView e RHVoice não têm evidência de provisionamento funcional.

O teste de proteção de voz não foi iniciado neste guest sem ADB homologado. O modo `Audit` continua sem alterar o Android; o modo `Apply` permanece bloqueado sem RHVoice/pt-BR homologado e, quando autorizado, só pode operar sobre a política com packages críticos descobertos, sem `uninstall`, `pm clear`, remoção de arquivos ou substituição automática da engine.

O fluxo de otimização agora está documentado em `docs/ANDROID-PACKAGE-OPTIMIZATION.md`. O modo `Audit` não altera o guest; o modo `Apply` exige aprovação explícita, snapshot e gate RHVoice com packages preservados, engine padrão inalterada, locale `pt-BR`, síntese real e áudio não vazio após cada grupo.

Os relatorios de benchmark so podem aprovar o gate de desligamento quando registram a negociacao QMP, o envio de `quit`, a saida do processo e `forcedKill=false` em todas as execucoes.

A verificacao mais recente foi publicada em `dist/NeoNewsRuntime-live-check`
com o SDK local .NET 8.0.424: build, publish, diagnostico e smoke terminaram
sem erros. O smoke contra esse executavel passou com o timeout padrao de 90
segundos, janela WPF responsiva, single-instance, `--exit` e zero processos
residuais. O diagnostico confirmou WHPX e os artefatos externos provisionados,
mas registrou o guest ADB como `Disconnected`, sem APKs proprietarios ou
componentes Android fornecidos para a prova live. O checklist contra a mesma
pasta produziu 31 itens, 0 aprovados, 14 falhas e 17 pendencias, mantendo o
status `not-approved`.

## Contrato do runtime

O arquivo [`config/runtime.json`](../config/runtime.json) usa:

- backend `qemu-android-x86`;
- Android release `7.1.2`, API `25`;
- ABI ARM preferencial `armeabi-v7a`;
- QEMU em `runtime/qemu/qemu-system-x86_64.exe`;
- disco persistente em `runtime/android/neonews-api25.qcow2`;
- ADB host `127.0.0.1:5556` encaminhado para guest `5555`;
- Native Bridge obrigatório;
- WebView `119.0.6045.193` e RHVoice `pt-BR` obrigatórios no fluxo comercial.

O provisionamento é separado da execução normal. [`Provision-QemuAndroidRuntime.ps1`](../scripts/provision/Provision-QemuAndroidRuntime.ps1) valida componentes locais, registra hashes e não baixa binários. O build copia somente os diretórios de runtime necessários; APK, Native Bridge, WebView, RHVoice e outros pacotes externos devem ser provisionados separadamente e não são incorporados ao executável ou versionados.

## Homologação pendente

Para alterar o status, ainda é necessário executar no mesmo runtime:

1. concluir a prova de persistência com marcador no qcow2 e reinício do guest/Windows, reutilizando a imagem já provisionada e validada pelo `qemu-img check`;
2. corrigir o transporte live e obter uma sessão ADB online em `127.0.0.1:5556`, mantendo origem e hashes registrados para QEMU, ADB e imagem;
3. provisionar uma Native Bridge legalmente redistribuível e provar a instalação do APK sem `INSTALL_FAILED_NO_MATCHING_ABIS`;
4. iniciar `TerminalActivity`, observar logcat e confirmar `primaryCpuAbi=armeabi-v7a` exatamente;
5. validar estabilidade após reinício e executar `Test-RuntimeStability.ps1` com conteúdo real do NeoNews em reprodução;
6. validar provider WebView 119 em HTML/CSS/JavaScript/HTTPS e no NeoNews;
7. validar RHVoice com síntese real em `pt-BR`;
8. executar testes de rede, HLS/m3u8, áudio, offline, kiosk, watchdog, startup, tray, instância única e persistência;
9. registrar tempos de boot, consumo e teste prolongado nesta versão do relatório.

Não solicitar outro APK x86. O critério correto é provar que o APK ARM oficial é executado no guest x86/x86_64 através de Native Bridge. Até essa prova existir, o relatório deve permanecer como **NÃO HOMOLOGADO**.
