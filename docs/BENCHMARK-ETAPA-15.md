# Benchmark repetível — Etapa 15

Data: **2026-09-01**

Script: [`scripts/benchmark/Run-NeoNewsBenchmark.ps1`](../scripts/benchmark/Run-NeoNewsBenchmark.ps1)

## Medição

O benchmark reinicia o AVD sem snapshot em cada iteração e coleta:

- tempo até `sys.boot_completed=1`;
- latência de uma chamada ADB;
- presença do pacote NeoNews;
- resumo mínimo, médio e máximo do boot.

Comando de referência:

```powershell
.\scripts\benchmark\Run-NeoNewsBenchmark.ps1 -Iterations 3
```

Neste ambiente, a medição é classificada como `base-runtime-only`: o pacote NeoNews não está instalado no AVD x86 por incompatibilidade de ABI. As métricas do app e de reprodução de mídia só podem ser coletadas após uma build x86 ou backend ARM executável.

## Decisão da etapa

**Etapa 15 concluída com benchmark reproduzível do runtime base.**
