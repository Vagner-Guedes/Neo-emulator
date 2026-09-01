# Otimização Android — Etapa 7

Data: **2026-09-01**  
Script: [`scripts/provision/Configure-NeoNewsAvd.ps1`](../scripts/provision/Configure-NeoNewsAvd.ps1)

## Perfil aplicado

O AVD `NeoNews_API25_x86` recebeu um perfil local de sinalização, com orientação inicial landscape:

| Parâmetro | Valor |
|---|---:|
| Resolução | `1920×1080` |
| Densidade | `160 dpi` |
| RAM | `2048 MB` |
| CPUs virtuais | `4` |
| Partição de dados | `8192M` |
| GPU | `swiftshader_indirect` |
| Áudio de entrada | habilitado |
| Áudio de saída | habilitado |
| Moldura/skin dinâmica | desabilitadas |
| Orientação inicial | `landscape` |

Comando executado:

```powershell
.\scripts\provision\Configure-NeoNewsAvd.ps1
```

O script cria um backup do `config.ini` antes da primeira alteração:

```text
config.ini.before-neonews-optimization.bak
```

O perfil do AVD conserva o display físico do device profile (`1080×1920`/`420 dpi`) em algumas imagens API 25. Por isso, a resolução lógica `1920×1080` e a densidade de operação devem ser aplicadas depois do boot pela etapa de kiosk; os valores do `config.ini` são a configuração persistente de referência.

## Decisão da etapa

**Etapa 7 concluída como configuração do perfil.** O áudio de entrada não foi desabilitado porque a auditoria do APK encontrou câmera, microfone e acessórios USB. A aceleração WHPX continua disponível para imagens x86; ela não resolve a incompatibilidade da ABI ARM do APK.

As métricas de desempenho e a validação visual do NeoNews permanecem pendentes até existir um caminho executável para o APK.
