# Relatório final — NeoNews Runtime V1

**Data:** 2026-09-04
**Branch:** `codex/neonews-runtime-homologation`
**Resultado global:** **BLOCKED / NOT PRODUCTION READY**

## Resumo

O WebView pré-compilado exato `com.google.android.webview` 119 foi obtido,
validado e integrado em uma publicação local sem compilar Chromium. O
provider efetivo passou a ser `119.0.6045.193`, com ABI nativa x86, e os
probes de HTML, CSS, JavaScript, HTTPS e conteúdo remoto passaram.

Native Bridge/Houdini, NeoNews ARM, `TerminalActivity`, RHVoice com síntese
real, locale pt-BR, fuso e sincronização do relógio com o Windows também
foram observados funcionando.

O produto permanece bloqueado por dois motivos principais: o fluxo real do
NeoNews com conteúdo Power BI não foi aprovado, e as duas execuções
integradas de 600 s registraram amostras offline do backend/ADB. A regra
vigente exige zero amostras instáveis; por isso não há aprovação de
estabilidade contínua.

## Matriz de gates

| Gate | Estado | Evidência / observação |
|---|---|---|
| QEMU + WHPX | PASS observado | Três ciclos com QEMU x86_64 e `-accel whpx`. |
| Android | PASS | Android-x86 7.1.2 / API 25 / x86_64. |
| ADB TCP privado | PASS observado, com ressalva | `127.0.0.1:5556` → guest `5555`; houve duas quedas capturadas no endurance. |
| Native Bridge/Houdini | PASS observado | `persist.sys.nativebridge=1`, `ro.dalvik.vm.native.bridge=libnb.so`, Houdini não vazio e ABI ARM32. |
| NeoNews ARM | PASS observado | Pacote `com.in9midia.neonews.player`, versão `9.0.3`/522, `primaryCpuAbi=armeabi-v7a`. |
| `TerminalActivity` | PASS observado | Foreground estável por 60 s no probe Native Bridge. |
| RHVoice pt-BR | PASS observado | Engine padrão RHVoice, dados pt-BR/Letícia presentes e WAV não vazio. |
| Verbalizar | PASS observado | `RHVoiceService`, `tts_speak_success`, `AudioTrack` e mensagem de sucesso. |
| Android em pt-BR | PASS observado | `persist.sys.locale=pt-BR` e `system_locales=pt-BR` após reboot. |
| Relógio Android = Windows | PASS observado | `America/Sao_Paulo`, sincronização no boot/watchdog e desvio medido de 0–3 s. |
| WebView 119 | PASS observado | Provider `com.google.android.webview`, versão exata, ativo e ABI x86. |
| HTML/CSS/JavaScript/HTTPS | PASS observado | Probe WebView 119 passou conteúdo local e HTTPS remoto. |
| Página de teste Power BI | PASS observado | `https://vagner-guedes.github.io/powerbi/` passou no probe dedicado. |
| Conteúdo real Power BI no NeoNews | BLOCKED | O app registrou conteúdo offline ausente e erros do template (`Hora`); não houve prova de reprodução real. |
| Três ciclos QEMU | PASS observado | 3/3 ciclos, 60 s por ciclo, QMP confirmado e `forcedKill=false`. |
| Persistência do qcow2 | PASS observado | Boot/reboot e marcador persistente confirmados em publicação de prova. |
| Endurance integrado de 600 s | NOT VALIDATED | Primeira execução: 628,19 s/1 falha; retry: 625,03 s/2 falhas. |
| Kiosk/watchdog/startup/tray | Parcial | Contratos e alguns smoke checks passaram; observação integral em PC limpo ainda não foi feita. |
| Superuser silencioso | Configuração PASS | `notification=false` persistido; nova prova visual de ausência do toast ainda pendente. |
| Isolamento do host | PASS estático | Ferramentas empacotadas, ADB privado, QMP privado e ownership por processo. |
| PC Windows novo / zero-touch | NOT RUN | Exige computador externo limpo. |
| Build Release | PASS | .NET 8: 0 avisos, 0 erros. |
| Validação do repositório | PASS | 36 scripts, 0 erros de parse/contrato. |
| Validação de codificação | PASS | Fontes/configuração/documentação versionáveis; temporários excluídos. |
| Limpeza de storage | NOT EXECUTED | C: sem espaço suficiente; nenhum arquivo foi apagado. |

## WebView pré-compilado

O artefato foi obtido pela página exata da variante aprovada:

`https://www.apkmirror.com/apk/google-inc/android-system-webview/android-system-webview-119-0-6045-193-release/android-system-webview-119-0-6045-193-7-android-apk-download/`

| Campo | Valor |
|---|---|
| Arquivo local | `packages/webview/webview.apk` |
| Nome conhecido | `com.google.android.webview_119.0.6045.193-604519307_minAPI24_maxAPI28(x86,x86_64)(nodpi)_apkmirror.com.apk` |
| Package | `com.google.android.webview` |
| Versão / versionCode | `119.0.6045.193` / `604519307` |
| Tamanho | `264477175` bytes |
| SHA-256 do APK | `5e49148fc2b369edc6b1bcc311d7b4ae6f4d5fc20f3a5971ae12792c77b6d167` |
| SHA-256 do certificado | `6faf3c4140407473400934d117815a21af1cfefc5c0bee61c858bc3d72ba6fe5` |
| ABIs | `x86`, `x86_64` |
| API | min 24, max 28, target 34 |
| Assinatura | v2, v3 e SourceStamp validados |

O APK permanece fora do Git. O script de publicação não copia APKs
proprietários automaticamente.

## Artefatos Native Bridge

O script `/system/bin/enable_nativebridge` foi identificado e seu SHA-256 é
`e5b59f57d1dee568e2eee0bab09d84a1480c11bc5364737b193cfd6d53a4f4aa`.

| Variante | URL esperada | Arquivo | Tamanho | SHA-256 |
|---|---|---|---:|---|
| ARM32 `7_y` | `http://dl.android-x86.org/houdini/7_y/houdini.sfs` | `houdini7_y.sfs` | 37728256 | `56FD08C448840578386A71819C07139122F0AF39F011059CE728EA0F3C60B665` |
| ARM64 `7_z` | `http://dl.android-x86.org/houdini/7_z/houdini.sfs` | `houdini7_z.sfs` | 37253120 | `7EEDC42015E6FB84A11A406A099241EFCCC20D4E020D476335A5FDB6E69A33D2` |

Nenhum mirror aleatório foi usado para Native Bridge. Os artefatos ficam
fora do Git.

## RHVoice e proteção da voz

O runtime preserva o pacote principal, os dados de idioma/voz e a engine
selecionada. Não foram executados `uninstall`, `pm clear`, remoção de
arquivos, troca automática de engine ou debloat no ciclo final.

Pacotes observados:

- `com.github.olga_yakovleva.rhvoice.android`;
- `com.github.olga_yakovleva.rhvoice.android.language.brazilian_portuguese.1240`;
- `com.github.olga_yakovleva.rhvoice.android.voice.leticia_f123.4060`.

O relatório de síntese `reports/tts-synthesis-after-webview119.json` registra
a frase de teste, engine RHVoice, locale pt-BR e áudio WAV de 110204 bytes.

## Endurance e falhas capturadas

Relatórios das duas tentativas integradas:

- `tmp/NeoNewsRuntime-FinalPublish-ApprovedOverlay/reports/runtime-stability-600-final2.json`: 628,19 s, 26 amostras, 1 falha;
- `tmp/NeoNewsRuntime-FinalPublish-ApprovedOverlay/reports/runtime-stability-600-retry.json`: 625,03 s, 25 amostras, 2 falhas.

As amostras reprovadas registraram `backendRunning=false` e
`adbOnline=false`. O log do QEMU não mostra crash ou restart nesse intervalo;
o watchdog não registrou recuperação. O encerramento final foi solicitado por
QMP. Como a causa transitória ainda não foi isolada e a regra exige zero
falhas, o gate continua `NOT VALIDATED`.

## Publicação e portabilidade

O launcher foi recompilado e publicado em
`dist/NeoNewsRuntime-current/NeoNewsRuntime.exe` como self-contained
win-x64, sem compilar WebView. O smoke de cópia para um caminho contendo
espaços foi interrompido por falta de espaço no C: durante a cópia da ISO
Android; isso deixou o teste zero-touch externo pendente.

A publicação não contém APKs nas pastas `packages/` e mantém o disco
persistente configurado como `runtime/android/neonews-runtime-v1.qcow2`.

## Próximos passos obrigatórios

1. Liberar espaço no host ou usar uma máquina de validação com armazenamento suficiente.
2. Repetir o endurance em uma cópia limpa e investigar a origem das quedas ADB/backend antes de aceitar 600 s.
3. Executar o fluxo real do NeoNews autenticado, confirmar conteúdo Power BI e reprodução.
4. Repetir a prova visual de que o toast de superusuário não aparece.
5. Validar kiosk, tray, watchdog, startup e coexistência em um PC Windows limpo, com Android Studio/ADB 5037 preservado.
6. Só depois executar a limpeza aprovada e fechar o gate zero-touch/publicação.
