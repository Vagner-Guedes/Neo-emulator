# Resiliência — Etapa 14

Data: **2026-09-01**

Script: [`scripts/runtime/Ensure-NeoNewsRuntime.ps1`](../scripts/runtime/Ensure-NeoNewsRuntime.ps1)

## Garantias

O bootstrap do runtime:

- usa lock exclusivo em `runtime/neonews-runtime.lock`;
- inicia o AVD opcionalmente e recupera o ADB com `start-server`;
- aguarda `sys.boot_completed`;
- limita as tentativas e o backoff;
- encerra a sequência como `package-missing` quando o APK não está instalado;
- só relança `TerminalActivity` quando o pacote existe;
- pode parar um AVD iniciado pelo próprio processo com `-StopEmulatorOnFailure`.

## Validação

Com o AVD x86 já bootado e `-MaxAttempts 1`, o bootstrap retornou:

```json
{
  "attempts": [
    {
      "attempt": 1,
      "status": "package-missing",
      "detail": "APK não instalado; não há recuperação automática possível"
    }
  ],
  "status": "package-missing"
}
```

## Decisão da etapa

**Etapa 14 concluída com resiliência bounded.** O bloqueio de ABI é tratado como estado terminal de diagnóstico, não como motivo para reiniciar indefinidamente o emulador.
