# Integração NeoNews — Etapa 6

Data da validação: **2026-09-01**  
Script: [`scripts/runtime/Start-NeoNews.ps1`](../scripts/runtime/Start-NeoNews.ps1)  
Atividade operacional configurada: `com.in9midia.neonews.player.TerminalActivity`

## Contrato de integração

O APK proprietário deve ser fornecido externamente em:

```text
packages/neonews/neonews.apk
```

O script não instala artefatos automaticamente. Ele valida o boot do dispositivo, consulta `pm path`, identifica a versão instalada e só executa `am start -W` quando o pacote existe. Isso evita tratar um AVD sem APK como uma falha de lançamento.

Comando usado:

```powershell
.\scripts\runtime\Start-NeoNews.ps1 `
  -StartEmulator `
  -ReportPath .\reports\neonews-etapa-6.json `
  -StopEmulator
```

Resultado no AVD x86:

```json
{
  "packageName": "com.in9midia.neonews.player",
  "expectedVersion": "9.0.3",
  "launchActivity": "com.in9midia.neonews.player/com.in9midia.neonews.player.TerminalActivity",
  "packagePath": "",
  "status": "not-installed"
}
```

## Decisão da etapa

**Etapa 6 concluída como integração automatizada, com execução bloqueada pela ABI.** A atividade `TerminalActivity` foi escolhida por ser a atividade operacional com filtros `MAIN/LAUNCHER/LEANBACK_LAUNCHER` observados na auditoria. O APK não foi instalado neste host porque suas bibliotecas são ARM-only e o AVD x86 não possui native bridge.

