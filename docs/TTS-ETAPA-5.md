# TTS offline — Etapa 5

Data da validação: **2026-09-01**  
AVD: `NeoNews_API25_x86`  
Script: [`scripts/validation/Test-TtsProvider.ps1`](../scripts/validation/Test-TtsProvider.ps1)

## Resultado

O AVD API 25 contém uma engine Google TTS, mas não contém o RHVoice requerido pelo runtime:

| Campo | Resultado |
|---|---|
| Engine requerida | `RHVoice` |
| Locale requerido | `pt-BR` |
| Pacote de engine detectado | `com.google.android.tts` |
| RHVoice presente | `false` |
| Engine padrão | `null` |
| Status | `missing-engine` |

Comando executado:

```powershell
.\scripts\validation\Test-TtsProvider.ps1 `
  -ReportPath .\reports\tts-etapa-5.json
```

O teste usa o ADB portátil e o endpoint TCP configurados no runtime. A etapa
de síntese permanece explicitamente pendente: presença do pacote, engine
padrão e `CHECK_TTS_DATA` não são tratados como prova de áudio reproduzido.

Saída resumida:

```json
{
  "requested": { "engine": "RHVoice", "locale": "pt-BR" },
  "detected": {
    "rhvoicePresent": false,
    "enginePackages": ["com.google.android.tts"],
    "defaultEngine": "null"
  },
  "status": "missing-engine"
}
```

## Decisão da etapa

**Etapa 5 concluída como diagnóstico, com TTS offline bloqueado.** A homologação exige um pacote RHVoice compatível com API 25, sua instalação no guest, seleção como engine padrão e teste real de síntese em `pt-BR`.

O pacote não foi baixado de fonte não verificada e nenhuma engine proprietária foi incluída no repositório.

## Probe de síntese real

Com o guest provisionado e o SDK Android de desenvolvimento disponível, execute:

```powershell
.\scripts\validation\Test-TtsSynthesis.ps1 `
  -SdkRoot C:\Android\Sdk `
  -ReportPath .\reports\tts-synthesis.json
```

O script compila localmente um probe temporário, chama `TextToSpeech.speak` e
`synthesizeToFile` com a frase de teste, confirma um WAV não vazio e remove o
probe ao final, salvo se `-KeepProbe` for usado. `-BuildOnly` valida apenas a
construção do probe.
