# Supervisor e watchdog — Etapa 10

Data: **2026-09-01**  
Script: [`scripts/runtime/Watch-NeoNews.ps1`](../scripts/runtime/Watch-NeoNews.ps1)

## Comportamento

Em cada ciclo, o supervisor verifica:

1. se o serial ADB está disponível;
2. se `com.in9midia.neonews.player` está instalado;
3. se `TerminalActivity` é a atividade em primeiro plano.

Com `-LaunchOnActivityLoss`, a atividade é relançada somente quando o pacote existe e a atividade foi perdida. Cada ciclo é registrado como JSON Lines em `logs/supervisor.log`.

O modo `-Once` permite diagnóstico sem criar um loop persistente.

## Validação

No AVD API 25 x86, sem o APK instalado, o primeiro ciclo retornou:

```json
{
  "packageName": "com.in9midia.neonews.player",
  "activity": "com.in9midia.neonews.player/TerminalActivity",
  "status": "package-missing",
  "restartAttempted": false
}
```

## Decisão da etapa

**Etapa 10 concluída como supervisor preparado e testado no estado ausente.** O watchdog não tenta reiniciar um pacote que não existe, evitando falsos positivos e loops de ADB. A recuperação funcional depende da resolução da ABI do APK.

