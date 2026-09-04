# Limpeza de armazenamento — NeoNews Runtime V1

**Data da verificação:** 2026-09-04
**Status:** `PASS — cópias testadas removidas`

## Estado preservado

| Item | Tamanho aproximado | Tratamento |
|---|---:|---|
| `runtime/android/neonews-runtime-v1.qcow2` | 4,02 GB | Imagem canônica aprovada; preservada |
| `dist/NeoNewsRuntime-current` | 2,88 GB | Publicação vigente; preservada |
| `runtime/android/android-x86-7.1-r5.iso` | 0,86 GB | ISO aprovada; preservada |
| `dist/NeoNewsRuntime-live-check` | 0,01 GB | Somente ADB global 5037 em uso; preservado |

## Cópias testadas removidas

As imagens abaixo já tinham sido usadas em gates concluídos ou em
investigações descartáveis. Seus relatórios, hashes e documentação continuam
como evidência; as cópias completas não são necessárias para reconstrução.

| Arquivo | Tamanho | SHA-256 | Motivo |
|---|---:|---|---|
| `runtime/android/adb-tcp-clean-api25.qcow2` | 2,53 GB | `9904FDC74E79FDDA8FC08B5E5797729DD21F0FCA61CF59A68613BEFC5AF0DB95` | baseline ADB TCP já homologado |
| `runtime/android/adb-tcp-provisioned-api25.qcow2` | 2,44 GB | `F4AD7075326D78814128941F66F5FFCE0E93F6A054A11652FCF19020120A343B` | imagem ADB TCP de teste já substituída pela imagem final |
| `runtime/android/nativebridge-investigation-9d0eeccd85174cbd9bf0403e0d345fd6.qcow2` | 0,03 GB | `B4FF4ECE9A92FE771B319967086A59F961E96E2353C7EE68325D89CA2751CE24` | overlay de investigação concluído |
| `runtime/android/nativebridge-official-455658f4e32e4babb46230523e3ba718.qcow2` | 0,80 GB | `E34CF86CCD9F9873E3FC011ACFEF7D2ED23CCEA44908CB140F90127A8E6E07D9` | overlay Native Bridge já validado |
| `runtime/android/neonews-api25.qcow2` | 1,36 GB | `E4F54E76CDB05C88C5E2506595DCBA42DBDD37CB140AAC0D864558F8ED40C5A6` | imagem antiga substituída pela V1 |
| `runtime/android/webview-aurora-acquisition-20260903.qcow2` | 0,83 GB | `322C0960CECE7669E4E3E60D2C97B780FB2CA7B02E0669A4F89C89912E794851` | imagem de aquisição já concluída |
| `runtime/android/webview-integration-119.qcow2` | 0,73 GB | `8C896328E7ED42F4C6A2DBAA18EEC6E2F8F76160C9046C177CFCCDC5F65F9B15` | overlay WebView já validado |
| `dist/NeoNewsRuntime-no-proprietary` | 0,16 GB | — | publicação de teste já concluída |

Também foram removidos os diretórios temporários de endurance/publicação já
consolidados. Arquivos não rastreados do usuário (`.gclient`, `.tmp-network/`,
`tmp/` e `docs/ui-reference/`) não foram apagados.

## Verificação pós-limpeza

- SSD: `SAMSUNG MZALQ256HAJD-000L2`, status `OK`.
- `C:` livre: `69,48 GB`.
- `E:` livre: `142,02 GB`.
- QCOW2 grandes restantes no projeto: somente a imagem canônica e a imagem
  embutida na publicação vigente.
- ADB global `127.0.0.1:5037`: PID `9360`, preservado e escutando.
- Nenhum QEMU ou processo de teste estava em execução durante a remoção.

O gate `STORAGE_GUARD_PASS` está atendido para esta etapa. A limpeza não
altera RHVoice, WebView, Native Bridge, debloat ou a imagem canônica.
