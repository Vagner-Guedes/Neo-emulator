# Baseline de desempenho — Etapa 8

Data: **2026-09-01**  
Script: [`scripts/benchmark/Measure-AndroidRuntime.ps1`](../scripts/benchmark/Measure-AndroidRuntime.ps1)  
AVD: `NeoNews_API25_x86`

## Medição coletada

| Métrica | Resultado |
|---|---|
| Boot detectado pelo script | `0,28 s` |
| Android | `7.1.1` |
| API | `25` |
| ABI | `x86` |
| Display lógico | `1920×1080` |
| Densidade lógica | `160 dpi` |
| Status | `baseline-collected` |

O script também captura amostras de `dumpsys meminfo` e `dumpsys gfxinfo` para comparação posterior. A medição foi feita com o Emulator sem snapshot e GPU SwiftShader; o tempo registrado representa a detecção de `sys.boot_completed` pelo host, não uma promessa de tempo de inicialização do APK.

## Decisão da etapa

**Etapa 8 concluída com baseline do Android base.** Não há métrica de frames, memória ou consumo do NeoNews porque o APK ARM-only ainda não foi instalado no AVD x86.

