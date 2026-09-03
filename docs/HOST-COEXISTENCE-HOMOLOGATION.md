# NeoNews Runtime — homologação de coexistência e portabilidade

Status atual: `BLOCKED / NOT PRODUCTION READY`

O isolamento está implementado e passou na inspeção estática, mas a homologação integral depende de evidência operacional que não está disponível neste checkout.

## Matriz de evidências

| Gate | Estado | Evidência necessária |
|---|---|---|
| Ferramentas resolvidas pela distribuição | PASS estático | `RuntimePaths`, `runtime.json`, `Test-HostIsolation.ps1` |
| ADB privado `127.0.0.1:5038` | PASS estático + smoke limitado | `AdbService` usa `nodaemon server`, `-P`, ambiente filho privado; smoke confirmou listener e encerramento por PID |
| Transporte `5556 → 5555` | PASS estático | contrato QEMU/ADB em `runtime.json` |
| QMP privado `127.0.0.1:4445` | PASS estático | `HostPortGuard` e desligamento QMP |
| Ownership do processo QEMU | PASS estático | `ManagedProcess` e `runtime/state/host-process.json` |
| Ownership do servidor ADB | PASS estático + smoke limitado | `ManagedProcess` e `runtime/state/adb-server.json`; smoke não iniciou QEMU/guest |
| WHPX em Windows limpo | NOT RUN | boot real com `-accel whpx` |
| PC de desenvolvimento limpo | NOT RUN | sem SDK/Java/ADB externo no PATH |
| PC de produção limpo | NOT RUN | publicação instalada fora do repositório |
| Android Studio em paralelo | NOT RUN | Android Studio/ADB padrão 5037 funcionando simultaneamente |
| QEMU externo em paralelo | NOT RUN | processo QEMU externo preservado |
| duas distribuições NeoNews | NOT RUN | mutex isolado e conflito de portas recusado sem kill |
| publicação zero-touch | NOT RUN | cópia publicada, boot e configuração persistente |
| NeoNews, Native Bridge, RHVoice, WebView e pt-BR | NÃO ALTERADO | gates próprios ainda devem ser reexecutados após a homologação do host |

## Critério de aprovação

Só marcar este documento como `PASS` depois de executar a matriz em uma cópia publicada, com relatório, PID, caminho dos executáveis, portas e logs. Falha de porta deve produzir erro explícito e não encerrar processos externos.

O desbloqueio do WebView oficial `119.0.6045.193`, a homologação real do RHVoice pt-BR e os testes integrados de estabilidade continuam gates independentes; esta etapa não os substitui.
