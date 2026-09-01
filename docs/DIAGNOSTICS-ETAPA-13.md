# Diagnóstico centralizado — Etapa 13

Data: **2026-09-01**
Script: [`scripts/diagnostics/Collect-Diagnostics.ps1`](../scripts/diagnostics/Collect-Diagnostics.ps1)

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
