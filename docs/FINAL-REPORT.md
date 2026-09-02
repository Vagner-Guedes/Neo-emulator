# Relatório final — NeoNews Runtime

Data da atualização: **2026-09-02**

## Estado executivo

O projeto agora possui o caminho de runtime preparado para a homologação funcional do APK ARM oficial, sem modificar, recompilar, resignar ou substituir o APK. O backend padrão foi migrado para **QEMU x86_64 + WHPX**, com Android-x86 7.1.2/API 25, disco persistente, janela gráfica identificável e ADB sobre TCP.

**Status atual: NÃO HOMOLOGADO.** A infraestrutura foi implementada e verificada estaticamente. A ISO oficial Android-x86 7.1-r5 já está presente e validada por SHA-1 (`1E65CB2E37B415576939398BAF4C8A92330FBB24`), mas QEMU standalone, ADB, disco qcow2, Native Bridge, WebView 119 e RHVoice ainda não estão provisionados nesta cópia de trabalho. Portanto, não há evidência honesta de execução do NeoNews no novo guest.

Os gates de instalação, ABI, kiosk e provisionamento foram deliberadamente
endurecidos nesta rodada: o launcher não transforma um pacote já presente em
evidência de `adb install -r`, não infere ABI a partir da configuração, exige
um registro prévio de provisionamento e restaura o guest se a entrada em kiosk
falhar.

## Alterações verificadas

| Área | Evidência | Resultado |
|---|---|---|
| Backend | `IAndroidRuntimeBackend`, `QemuAndroidRuntimeBackend` e compatibilidade legada | implementado |
| QEMU | `-accel whpx`, qcow2 persistente, forwarding ADB, QMP e título `NeoNews Android Runtime` | implementado; não executado sem binários |
| ADB | transporte `tcp`, serial configurável `host:port`, `start-server`, `connect`, retry e estados fortes | implementado |
| Configuração | `schemaVersion=2`, migração de schema 1 com backup `.bak`, caminhos relativos | validado por JSON |
| Native Bridge | coleta de `ro.dalvik.vm.native.bridge`, ABI list, `primaryCpuAbi`, manifesto, ABIs e certificado X.509 antes da instalação | implementado; não homologado |
| NeoNews | APK local preservado, `adb install -r`, confirmação da activity e validação de versão | implementado; não executado neste backend |
| Persistência | qcow2 externo, estado obrigatório em `runtime/state/provisioning.json` e hash forte preservado | implementado; não executado |
| WebView/TTS | provider ativo, ABI nativa, versão esperada, conteúdo HTML/CSS/JavaScript/HTTPS e síntese real são pré-condições do fluxo completo | implementado; não homologado |
| Rede/mídia/offline | probe local para DNS, HTTP/HTTPS, HLS/MediaPlayer, cache e NIC QMP reversível | implementado; não executado sem guest provisionado |
| Kiosk | serviço existente usa o contrato do backend, valida geometria/estilo da janela e restaura configurações | compilado |
| Watchdog | distingue activity perdida, ADB offline e backend morto; cooldown, limite de tentativas e bloqueio de loop de reinstalação | compilado |
| Zero-console | QEMU/ADB iniciados por `ProcessStartInfo` invisível; GUI Android permitida | smoke test do launcher aprovado |
| Build | SDK local .NET 8.0.424 / host .NET 8.0.30, `Release` | 0 erros, 0 avisos; publicação atual verificada |
| Regressão | `Test-RuntimeRepository.ps1` | 30 scripts, JSON e ignore checks aprovados |
| Launcher | `NeoNewsRuntime.exe --show` e `--exit` | janela WPF criada, handle válido, 0 processos residuais |
| Diagnóstico | `NeoNewsRuntime.exe --diagnostics` | relatório ampliado com integridade, WHPX, ABI, guest, memória, gráficos e logcat filtrado |
| Publicação | `Publish-NeoNewsRuntime.ps1` em diretório de verificação | layout portátil criado; pacotes proprietários não são copiados nem incorporados |
| Checklist | `Test-HomologationChecklist.ps1` | 31 gates agregados; pendências nunca viram aprovação |
| Estabilidade integrada | `Test-RuntimeStability.ps1` | runner de 600 s para backend, ADB, NeoNews, watchdog, kiosk, WebView, TTS, conteudo real e logcat; pendente sem guest |

## Verificacao local desta rodada

A publicação de verificação `dist/NeoNewsRuntime-current` foi gerada depois do build Release e passou pelo smoke do executável publicado. O relatório registrou janela WPF responsiva, single-instance, CLI, `--exit`, caminho com espaços e ausência de processos residuais; os campos manuais de console, tray e hotkey foram registrados explicitamente. A coleta fresca `--diagnostics` também terminou com exit code 0 e registrou o backend/serial configurados, WHPX disponível, a ISO Android-x86 validada e os demais arquivos externos ausentes.

Os probes `Test-WebViewProvider.ps1` e `Test-TtsProvider.ps1` agora usam por padrão os nomes de relatório consumidos pelo checklist (`webview-provider.json` e `tts-provider.json`), e invalidam esses arquivos antes de qualquer pré-voo. O smoke do launcher também grava, por padrão, ao lado do executável que foi testado; o checklist compara esse diretório com o diagnóstico e com a estabilidade integrada quando ambos existem, evitando misturar publicações diferentes.

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

O checklist final agora exige evidencia Native Bridge com janela minima de 600 segundos, identidade do manifesto do APK e exit codes zero nos comandos criticos de instalacao, launch e probes. A estabilidade integrada tambem exige observacao explicita de conteudo real do NeoNews em reproducao no mesmo executavel publicado. No ambiente atual, o checklist permanece `not-approved` porque QEMU/ADB, o disco/guest inicializado, Native Bridge, WebView e RHVoice nao estao provisionados.

Os relatorios de benchmark so podem aprovar o gate de desligamento quando registram a negociacao QMP, o envio de `quit`, a saida do processo e `forcedKill=false` em todas as execucoes.

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

1. criar/provisionar o disco persistente a partir da ISO Android-x86 7.1-r5/API 25 já validada;
2. provisionar QEMU x86_64 e ADB localmente, com origem e hashes registrados;
3. provisionar uma Native Bridge legalmente redistribuível e provar a instalação do APK sem `INSTALL_FAILED_NO_MATCHING_ABIS`;
4. iniciar `TerminalActivity`, observar logcat e confirmar `primaryCpuAbi=armeabi-v7a` exatamente;
5. validar estabilidade após reinício e executar `Test-RuntimeStability.ps1` com conteúdo real do NeoNews em reprodução;
6. validar provider WebView 119 em HTML/CSS/JavaScript/HTTPS e no NeoNews;
7. validar RHVoice com síntese real em `pt-BR`;
8. executar testes de rede, HLS/m3u8, áudio, offline, kiosk, watchdog, startup, tray, instância única e persistência;
9. registrar tempos de boot, consumo e teste prolongado nesta versão do relatório.

Não solicitar outro APK x86. O critério correto é provar que o APK ARM oficial é executado no guest x86/x86_64 através de Native Bridge. Até essa prova existir, o relatório deve permanecer como **NÃO HOMOLOGADO**.
