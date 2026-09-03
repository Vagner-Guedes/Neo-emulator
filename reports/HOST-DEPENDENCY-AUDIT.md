# NeoNews Runtime — auditoria de dependências do host

Data da auditoria: 2026-09-03

## Resultado

`STATIC PASS / LIMITED DYNAMIC PASS / FULL DYNAMIC NOT RUN`

A análise estática do launcher passou. Um smoke test dinâmico seguro confirmou que o ADB empacotado aceita `-L tcp:5038 nodaemon server`, responde `adb -P 5038 version` e encerra por PID exato, com a porta liberada depois. A homologação integral do host não é marcada como PASS porque ainda não foram executados os testes em um PC limpo, a coexistência com Android Studio/QEMU externo e a publicação final.

## Contratos persistentes

- Ferramentas de produção são resolvidas pela raiz da distribuição por `RuntimePaths`.
- ADB empacotado: `runtime/adb/adb.exe`.
- O launcher cria o servidor privado em foreground com `-L tcp:5038 nodaemon server`, registra `runtime/state/adb-server.json` e encerra somente seu `ManagedProcess`.
- Servidor ADB privado: `127.0.0.1:5038`.
- Transporte ADB do guest: host `127.0.0.1:5556` → guest `10.0.2.15:5555`.
- QMP privado: `127.0.0.1:4445`.
- QEMU empacotado: `runtime/qemu/qemu-system-x86_64.exe`.
- Disco, imagem Android, estado, logs e relatórios permanecem relativos à distribuição.
- Mutex e pipe de controle são derivados da raiz canônica da instalação.
- O launcher não executa `taskkill /IM`, não usa `GetProcessesByName` e não chama `adb kill-server` globalmente.
- Processos filhos recebem ambiente sanitizado, sem `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `JAVA_HOME`, variáveis de ADB/QEMU e sem depender do `PATH` do host.
- O QEMU é encerrado por QMP; o fallback atua somente sobre o `ManagedProcess` criado pelo launcher.

## Evidência dinâmica limitada

- ADB empacotado: `runtime/adb/adb.exe`.
- PID de smoke test: `17828`.
- Comando: `adb.exe -L tcp:5038 nodaemon server`.
- Resultado: listener local ativo; `adb -H 127.0.0.1 -P 5038 version` retornou `Android Debug Bridge version 1.0.41`; encerramento por PID exato; porta 5038 livre após o encerramento.
- Escopo: teste do servidor privado isolado; não inicializou QEMU, não conectou ao guest e não substitui a matriz de coexistência.

## Dependências classificadas

| Dependência | Produção | Classificação |
|---|---:|---|
| QEMU empacotado | Sim | Obrigatória; caminho absoluto derivado da distribuição |
| ADB empacotado | Sim | Obrigatória; servidor privado na porta 5038 |
| Android-x86/API25 e qcow2 | Sim | Artefatos locais provisionados e verificados por SHA-256 |
| WHPX | Sim | Recurso do Windows; validado antes do boot |
| .NET Runtime | Não | Publicação `win-x64`, self-contained e single-file |
| Java/.NET SDK/Android SDK do host | Não | Somente scripts de build/provisionamento/diagnóstico, fora do boot de produção |
| Android Studio, ADB 5037 e QEMU externo | Não | Não são usados; coexistência dinâmica ainda precisa ser testada |

## Qualidade estática

Executar:

```powershell
.\scripts\validation\Test-HostIsolation.ps1
```

O relatório JSON gerado registra cada check e mantém os testes dinâmicos como `not-run` até haver evidência real.

Durante esta auditoria havia uma sessão pré-existente, preservada sem intervenção:

- `adb.exe` empacotado, PID 18788, servidor `tcp:5037`.
- `qemu-system-x86_64.exe` empacotado, PID 18420, transporte `127.0.0.1:5556` e QMP `127.0.0.1:4445`.

Essa sessão ocupa as portas do runtime antigo. O novo contrato não a encerra nem se conecta a ela; por isso o boot dinâmico do contrato privado 5038 não foi executado nesta rodada.
