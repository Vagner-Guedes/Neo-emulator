# Relatório completo de homologação — NeoNews Runtime V1

**Status global:** **BLOCKED / NOT PRODUCTION READY**
**Data da auditoria:** 2026-09-04
**Branch:** `codex/neonews-runtime-homologation`

## Decisão

O runtime tem uma base funcional comprovada: QEMU/WHPX, Android-x86
7.1.2/API 25, transporte ADB TCP privado, Native Bridge ARM, NeoNews ARM,
WebView 119 pré-compilado, RHVoice pt-BR, idioma pt-BR e sincronização de
relógio com o Windows.

Isso ainda não constitui liberação de produção. O fluxo real de conteúdo
Power BI dentro do NeoNews continua sem prova de reprodução, e as execuções
integradas de 600 s tiveram amostras offline. A publicação em um PC Windows
novo e o zero-touch externo também não foram homologados.

## Evidências aprovadas

### WebView 119

O APK pré-compilado foi validado sem compilação local de Chromium:

- package: `com.google.android.webview`;
- versão: `119.0.6045.193`;
- versionCode: `604519307`;
- tamanho: `264477175` bytes;
- SHA-256: `5e49148fc2b369edc6b1bcc311d7b4ae6f4d5fc20f3a5971ae12792c77b6d167`;
- certificado: `6faf3c4140407473400934d117815a21af1cfefc5c0bee61c858bc3d72ba6fe5`;
- ABIs: `x86` e `x86_64`;
- origem: página exata da variante APKMirror registrada em
  `reports/webview-prebuilt-119.json`.

No guest, `cmd webviewupdate` retornou `Success`, o provider ativo foi
`com.google.android.webview` e `primaryCpuAbi=x86`. O probe passou HTML, CSS,
JavaScript, HTTPS e conteúdo remoto. A página de teste
`https://vagner-guedes.github.io/powerbi/` também passou.

O resultado do probe não é confundido com o fluxo real do NeoNews. O log
`reports/powerbi-real-refresh.logcat.txt` registra conteúdo offline ausente e
erros do template local; por isso o gate Power BI real continua bloqueado.

### Native Bridge e NeoNews

O script `/system/bin/enable_nativebridge` foi conferido. A variante ARM32
`7_y` foi registrada pela URL oficial esperada pelo próprio script. A imagem
live mostrou `persist.sys.nativebridge=1`,
`ro.dalvik.vm.native.bridge=libnb.so`, Houdini não vazio e
`primaryCpuAbi=armeabi-v7a` para o NeoNews.

O pacote `com.in9midia.neonews.player` versão `9.0.3`/522 abriu
`TerminalActivity` e permaneceu estável por 60 s no relatório
`reports/nativebridge-live-after-rhvoice.json`. O logcat filtrado não mostrou
`UnsatisfiedLinkError`, falha de linker, `FATAL EXCEPTION`, SIGSEGV, SIGABRT
ou ANR nesse probe.

### Voz, idioma e horário

O RHVoice permanece como engine padrão, com os pacotes de idioma brasileiro e
voz Letícia-F123. A síntese real gerou WAV não vazio; o caminho do NeoNews
por `VERBALIZAR` registrou `RHVoiceService`, `AudioTrack` e sucesso.

O guest foi validado com `persist.sys.locale=pt-BR`,
`system_locales=pt-BR` e fuso `America/Sao_Paulo`. O launcher sincroniza o
epoch do Windows no boot e o watchdog repete a correção. O desvio observado
ficou entre 0 e 3 segundos.

### Ciclos QEMU e persistência

O relatório `tmp/NeoNewsRuntime-CycleTest/tmp/NeoNewsRuntime-CycleTest/reports/qemu-runtime-cycles-final.json` registrou 3/3 ciclos bem-sucedidos,
com 60 s de estabilidade por ciclo, `qmpQuitResponseSucceeded=true` e
`forcedKill=false`.

O relatório `tmp/NeoNewsRuntime-FinalPublish-Fresh/reports/qemu-persistence.json`
registrou dois boots, dois desligamentos QMP, marcador persistente e nenhum
kill forçado.

## Gate integrado de 600 s

As duas tentativas foram encerradas normalmente, mas não aprovadas:

| Tentativa | Tempo observado | Amostras | Falhas |
|---|---:|---:|---:|
| final2 | 628,19 s | 26 | 1 |
| retry | 625,03 s | 25 | 2 |

Nas falhas, o relatório capturou backend e ADB offline; as amostras seguintes
voltaram ao estado pronto. Não há crash/restart correspondente no `qemu.log`,
nem recuperação do watchdog. O critério do script é deliberadamente estrito:
qualquer amostra instável mantém `status=not-validated`.

## Proteções respeitadas

- RHVoice, WebView, Native Bridge e dados do NeoNews não foram apagados;
- nenhum `uninstall` ou `pm clear` foi executado no guest final;
- nenhuma engine de voz foi desabilitada;
- nenhum binário aleatório foi usado para Native Bridge;
- o ADB global `127.0.0.1:5037` não foi encerrado;
- o qcow2 aprovado da raiz não foi substituído;
- os arquivos não rastreados do usuário foram preservados;
- APKs e artefatos proprietários continuam fora do Git.

## Estado da publicação

O launcher Release foi recompilado com 0 avisos e 0 erros e publicado em
`dist/NeoNewsRuntime-current`. A publicação é self-contained win-x64 e usa
somente caminhos relativos para QEMU, ADB, imagem e qcow2. O script de
publicação não copia APKs externos automaticamente.

O teste de cópia para caminho contendo espaços não foi concluído porque o
volume C: ficou sem espaço ao copiar a ISO Android. O gate de PC novo,
coexistência e zero-touch permanece `NOT RUN`.

## Próximos passos para desbloqueio

1. Repetir o endurance em cópia limpa com espaço suficiente e isolar as duas
   quedas do transporte/backend.
2. Homologar conteúdo e playback reais do NeoNews/Power BI.
3. Repetir a prova visual de ausência do toast de superusuário.
4. Validar startup, kiosk, tray, watchdog e coexistência em PC limpo.
5. Executar cleanup somente com inventário e autorização explícita, preservando
   qcow2, RHVoice, WebView, Native Bridge e artefatos do usuário.

Até a conclusão desses itens, a decisão oficial permanece
**BLOCKED / NOT PRODUCTION READY**.
