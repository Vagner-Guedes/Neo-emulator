# Inicialização do Windows — Etapa 11

Data: **2026-09-01**  
Script: [`scripts/startup/Register-NeoNewsStartup.ps1`](../scripts/startup/Register-NeoNewsStartup.ps1)

## Comportamento

O script prepara uma tarefa agendada por usuário, disparada no logon com atraso de 30 segundos. A tarefa executa o supervisor com:

- PowerShell não interativo;
- `ExecutionPolicy Bypass` apenas para o arquivo do supervisor;
- diretório de trabalho do repositório;
- reinício automático até três vezes, com intervalo de um minuto;
- política `IgnoreNew` para evitar instâncias concorrentes.

Use `-Apply` para registrar a tarefa e `-Unregister -Apply` para removê-la. Sem `-Apply`, o script apenas gera um preview; `-WhatIf` também é suportado.

## Validação

O preview foi validado contra o supervisor e o caminho do repositório sem criar uma tarefa persistente. O estado permanece:

```text
status=preview
```

## Decisão da etapa

**Etapa 11 concluída como provisionamento reproduzível.** A tarefa não foi registrada automaticamente nesta máquina durante a validação; a execução real continua condicionada a um dispositivo ADB e ao APK NeoNews instalável.

