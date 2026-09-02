# Relatório final — NeoNews Runtime

Data da atualização: **2026-09-02**

## Estado executivo

O projeto agora possui o caminho de runtime preparado para a homologação funcional do APK ARM oficial, sem modificar, recompilar, resignar ou substituir o APK. O backend padrão foi migrado para **QEMU x86_64 + WHPX**, com Android-x86 7.1.2/API 25, disco persistente, janela gráfica identificável e ADB sobre TCP.

**Status atual: NÃO HOMOLOGADO.** A infraestrutura foi implementada e verificada estaticamente, mas os binários externos do QEMU, ADB, imagem Android-x86, disco qcow2, Native Bridge, WebView 119 e RHVoice ainda não estão presentes nesta cópia de trabalho. Portanto, não há evidência honesta de execução do NeoNews no novo guest.

## Alterações verificadas

| Área | Evidência | Resultado |
|---|---|---|
| Backend | `IAndroidRuntimeBackend`, `QemuAndroidRuntimeBackend` e compatibilidade legada | implementado |
| QEMU | `-accel whpx`, qcow2 persistente, forwarding ADB, QMP e título `NeoNews Android Runtime` | implementado; não executado sem binários |
| ADB | transporte `tcp`, serial configurável `host:port`, `start-server`, `connect`, retry e estados fortes | implementado |
| Configuração | `schemaVersion=2`, migração de schema 1 com backup `.bak`, caminhos relativos | validado por JSON |
| Native Bridge | coleta de `ro.dalvik.vm.native.bridge`, ABI list, `primaryCpuAbi` e relatório de compatibilidade | implementado; não homologado |
| NeoNews | APK local preservado, `adb install -r`, confirmação da activity e validação de versão | implementado; não executado neste backend |
| Persistência | qcow2 externo e estado em `runtime/state/provisioning.json` | implementado; não executado |
| WebView/TTS | provider ativo, ABI nativa, versão esperada, conteúdo HTML/CSS/JavaScript/HTTPS e síntese real são pré-condições do fluxo completo | implementado; não homologado |
| Rede/mídia/offline | probe local para DNS, HTTP/HTTPS, HLS/MediaPlayer, cache e NIC QMP reversível | implementado; não executado sem guest provisionado |
| Kiosk | serviço existente usa o contrato do backend e localiza a janela por PID/título | compilado |
| Watchdog | distingue activity perdida, ADB offline e backend morto; cooldown e limite de tentativas | compilado |
| Zero-console | QEMU/ADB iniciados por `ProcessStartInfo` invisível; GUI Android permitida | smoke test do launcher aprovado |
| Build | SDK local .NET 8.0.30, `Release` | 0 erros, 0 avisos |
| Regressão | `Test-RuntimeRepository.ps1` | 28 scripts, JSON e ignore checks aprovados |
| Launcher | `NeoNewsRuntime.exe --show` e `--exit` | janela WPF criada, handle válido, 0 processos residuais |
| Diagnóstico | `NeoNewsRuntime.exe --diagnostics` | relatório ampliado com integridade, WHPX, ABI, guest, memória, gráficos e logcat filtrado |
| Publicação | `Publish-NeoNewsRuntime.ps1` em diretório de verificação | layout portátil criado; APK externo copiado sem alteração (58.954.286 bytes) |
| Checklist | `Test-HomologationChecklist.ps1` | 30 gates agregados; pendências nunca viram aprovação |

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

O provisionamento é separado da execução normal. [`Provision-QemuAndroidRuntime.ps1`](../scripts/provision/Provision-QemuAndroidRuntime.ps1) valida componentes locais, registra hashes e não baixa binários. O build copia apenas componentes locais explicitamente existentes; nenhum binário proprietário é incorporado ao executável ou versionado.

## Homologação pendente

Para alterar o status, ainda é necessário executar no mesmo runtime:

1. provisionar a release oficial Android-x86 7.1-r5/API 25 e o disco persistente;
2. provisionar QEMU x86_64 e ADB localmente, com origem e hashes registrados;
3. provisionar uma Native Bridge legalmente redistribuível e provar a instalação do APK sem `INSTALL_FAILED_NO_MATCHING_ABIS`;
4. iniciar `TerminalActivity`, observar logcat e confirmar `primaryCpuAbi=armeabi-v7a` ou equivalente;
5. validar estabilidade após reinício e conteúdo real do NeoNews;
6. validar provider WebView 119 em HTML/CSS/JavaScript/HTTPS e no NeoNews;
7. validar RHVoice com síntese real em `pt-BR`;
8. executar testes de rede, HLS/m3u8, áudio, offline, kiosk, watchdog, startup, tray, instância única e persistência;
9. registrar tempos de boot, consumo e teste prolongado nesta versão do relatório.

Não solicitar outro APK x86. O critério correto é provar que o APK ARM oficial é executado no guest x86/x86_64 através de Native Bridge. Até essa prova existir, o relatório deve permanecer como **NÃO HOMOLOGADO**.
