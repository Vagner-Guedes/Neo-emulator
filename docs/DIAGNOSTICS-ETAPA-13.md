# Diagnóstico centralizado — Etapa 13

Data: **2026-09-01**
Script: [`scripts/diagnostics/Collect-Diagnostics.ps1`](../scripts/diagnostics/Collect-Diagnostics.ps1)

O objeto `tools.qemuNetwork` registra o contrato configurado do forwarding
ADB (`cidr`, `guestAddress`, `nicModel`, host/portas e porta do guest). Esses
campos descrevem a configuracao; nao sao evidencia de que o Android obteve o
endereco ou de que o `adbd` ficou online.

O script PowerShell atua como wrapper de compatibilidade e delega a coleta ao `NeoNewsRuntime.exe --diagnostics`; ele recusa um relatório sem o schema canônico de identidade do runtime.

O coletor principal do runtime também está disponível por `NeoNewsRuntime.exe --diagnostics`.

Quando houver mais de uma publicação no workspace, indique explicitamente o
executável que deve produzir a evidência:

```powershell
.\scripts\diagnostics\Collect-Diagnostics.ps1 `
  -ExecutablePath .\dist\NeoNewsRuntime\NeoNewsRuntime.exe `
  -ReportPath .\reports\diagnostics-published.json
```
Ele acrescenta integridade SHA-256 dos componentes locais, preflight WHPX,
PID/título do backend, compatibilidade ABI, rede/DNS, armazenamento `/data`,
políticas kiosk e memória/gráficos/logcat filtrados. O resultado permanece
específico da máquina e não é versionado.

## Conteúdo

O coletor gera um JSON com:

- Windows, CPU, memória e espaço livre em `C:`;
- raiz do SDK e versão do ADB;
- propriedades do guest Android e estado de boot;
- ABI, fingerprint e display;
- presença/resumo do pacote NeoNews;
- estado do WebView;
- engines TTS e engine padrão;
- amostras de memória, gráficos e logcat.

O relatório é gerado em `reports/diagnostics.json`, que permanece ignorado pelo Git por conter estado específico da máquina.

## Validação

O script foi validado em AVD API 25 x86 com o pacote ausente. Ele coleta o guest sem inventar uma versão do NeoNews e mantém o campo `packagePath` vazio. O status do relatório é `collected`; o status do componente NeoNews continua bloqueado por ABI.

## Decisão da etapa

**Etapa 13 concluída com coletor centralizado e evidência reproduzível.**
