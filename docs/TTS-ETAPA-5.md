# TTS offline — Etapa 5

**Data da validação:** 2026-09-03
**Guest:** Android-x86 7.1.2 / API 25, ADB TCP `127.0.0.1:5556`
**Script:** [`scripts/validation/Test-TtsProvider.ps1`](../scripts/validation/Test-TtsProvider.ps1)

## Resultado

| Campo | Resultado |
|---|---|
| Engine requerida | RHVoice |
| Locale requerido | `pt-BR` |
| Pacote | `com.github.olga_yakovleva.rhvoice.android` 1.18.4 / 118040 |
| Engine padrão | RHVoice |
| Dados pt-BR | `...language.brazilian_portuguese.1240` presente |
| Voz | `Letícia-F123` / `...voice.leticia_f123.4060` presente |
| Síntese offline | PASS; WAV não vazio, 110.204 bytes |
| Status | `provider-and-locale-validated-synthesis-confirmed` |

O `CHECK_TTS_DATA` legado da API 25 retorna `result=0` mesmo com os dados
instalados. Por isso o runtime exige a evidência de síntese real no mesmo
serial e valida diretamente os diretórios de idioma/voz, além de confirmar o
arquivo WAV e a engine padrão.

## Teste dentro do NeoNews

O menu nativo do NeoNews foi aberto em português e o botão `VERBALIZAR` foi
acionado. O logcat confirmou vínculo a `RHVoiceService`, locale `por-BRA`,
`AudioTrack`, `tts_speak_success` e `Texto verbalizado com sucesso!`.

Evidência: `reports/neonews-verbalize-live.json`.

## Proteção

RHVoice e todos os pacotes relacionados permanecem protegidos na política
`critical`. Google TTS/Pico não foram desabilitados; nenhum `uninstall`,
`pm clear`, apagamento de arquivos ou substituição automática foi executado.
Qualquer otimização futura deve repetir a síntese e fazer rollback imediato
se algum gate falhar.

## Artefatos

- APK RHVoice F-Droid: SHA-256
  `FDB0F7D6F3EC455477A84AA8CC86D1F2D580CB180D69A0C780240975C2EFD288`.
- Idioma Brazilian Portuguese v1.24: SHA-256
  `76D4309902D8CBDD822EF16DE2E85BDED8E0E23EF9960FEF877DA5ED143806E6`.
- Voz Leticia-F123 v4.6: SHA-256
  `E032EB268BB8B28523E40296D4A99908DBDBB5C65EF8F775279D202C897B23CA`.

Os binários permanecem fora do Git.
