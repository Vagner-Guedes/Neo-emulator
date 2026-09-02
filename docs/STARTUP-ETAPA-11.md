# Inicialização do Windows — Etapa 11

Data: **2026-09-01**
Script: [`scripts/startup/Register-NeoNewsStartup.ps1`](../scripts/startup/Register-NeoNewsStartup.ps1)

## Comportamento

O script prepara uma tarefa agendada por usuário, disparada no logon com atraso de 30 segundos. A ação é o executável WPF publicado com `--autostart`, em seu diretório de distribuição; não há PowerShell no caminho normal de operação. A tarefa usa reinício limitado e `IgnoreNew` quando registrada pelo script de provisionamento.

Ao receber `--autostart`, o launcher aplica a configuração persistida:

- com `Startup.StartNeoNews=true`, executa o fluxo completo de Android, NeoNews, validações, kiosk e watchdog;
- com `Startup.StartNeoNews=false`, inicia somente o Android e ainda aplica `Startup.AutoKiosk` e o watchdog configurado;
- se a entrada no kiosk falhar, o runtime desmonta o início parcial e reporta o erro à interface.

Use `-Apply` para registrar a tarefa e `-Unregister -Apply` para removê-la. Sem `-Apply`, o script apenas gera um preview; `-WhatIf` também é suportado.

## Validação

O preview foi validado contra o executável do launcher e o caminho da distribuição sem criar uma tarefa persistente. O estado permanece:

```text
status=preview
```

## Decisão da etapa

**Etapa 11 concluída como provisionamento reproduzível.** A tarefa não foi registrada automaticamente nesta máquina durante a validação; a execução real continua condicionada a um dispositivo ADB e ao APK NeoNews instalável.
