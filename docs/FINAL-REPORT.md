# Relatório final — NeoNews Runtime 7

Data: **2026-09-01**

## Estado executivo

O repositório foi inicializado, conectado a `origin/master` e evoluído com uma base reproduzível de runtime Windows/Android. A base técnica, o launcher WPF, kiosk, supervisor, startup, diagnóstico, resiliência e benchmark estão versionados.

**Status de homologação do NeoNews: bloqueado por dependências externas.** O APK auditado é ARM-only; não foi possível instalá-lo funcionalmente no AVD x86, e o Emulator ARM disponível não concluiu a instalação sem derrubar o `system_server` durante o `dex2oat`.

## Evidências principais

| Área | Evidência | Estado |
|---|---|---|
| APK | pacote `com.in9midia.neonews.player`, versão `9.0.3`, ABIs `arm64-v8a`/`armeabi-v7a` | auditado |
| Android | API 25/7.1.1 inicializou no AVD x86 | validado |
| Aceleração | WHPX instalado e utilizável | validado |
| ABI x86 | `INSTALL_FAILED_NO_MATCHING_ABIS` e native bridge ausente | bloqueado |
| ABI ARM32 | Emulator legado iniciou, mas watchdog matou `system_server` no `dex2oat` | bloqueado |
| WebView | `55.0.2883.91` instalado; alvo `119.0.6045.193` | divergente |
| TTS | `com.google.android.tts` presente; RHVoice ausente; default `null` | bloqueado |
| Kiosk | `immersive.full=*`, timeout máximo, display `1920×1080`/`160 dpi` | aplicado no guest |
| Boot | cold boot medido em `12,61 s` no benchmark de uma iteração | base medida |
| Launcher | WPF Release compilado com `0` erros e `0` avisos | validado |
| Regressão | 14 scripts PowerShell parseados, JSON válido, APK ignorado | aprovado |

## Artefatos entregues

- `config/runtime.json`: contrato único de runtime, ABI, WebView, TTS, kiosk, supervisor, startup, launcher, diagnóstico, resiliência e benchmark.
- `scripts/provision`: instalação do SDK/API 25, criação de AVD e configuração persistente.
- `scripts/validation`: validação de WebView, TTS e regressão estática.
- `scripts/runtime`: lançamento NeoNews, kiosk, supervisor e bootstrap resiliente.
- `scripts/diagnostics`: coleta host/guest, ADB, pacote, WebView, TTS, memória, gráficos e logcat.
- `scripts/benchmark`: baseline e benchmark repetível do guest.
- `launcher/NeoNews.Runtime.Launcher`: launcher WPF local.
- `docs`: evidências por etapa e decisões de homologação.

## Pendências que impedem a homologação

1. fornecer uma build NeoNews com `x86`/`x86_64`, ou disponibilizar dispositivo/backend ARM executável;
2. fornecer um pacote WebView 119 compatível com API 25 e validar versão, assinatura e página de teste;
3. fornecer e instalar RHVoice compatível com API 25, selecionar a engine padrão e sintetizar áudio `pt-BR`;
4. repetir `Start-NeoNews.ps1 -Launch`, supervisor, diagnóstico e benchmark com o APK instalado;
5. somente após os testes acima, registrar a tarefa de startup com `Register-NeoNewsStartup.ps1 -Apply`.

Nenhum APK proprietário, native bridge não homologada ou engine TTS de fonte incerta foi incluído no Git.

## Commits enviados

As etapas foram commitadas e enviadas progressivamente para `origin/master`. Principais commits:

```text
2796e8f docs: registrar auditoria inicial do runtime
169a313 chore: provisionar runtime base Android API 25
cfcdeaf docs: registrar validacao de ABI do NeoNews
d14c046 feat: automatizar validacao do provedor WebView
81463d3 feat: automatizar diagnostico de TTS offline
2fbd87c feat: formalizar integracao e lancamento do NeoNews
54de177 feat: aplicar perfil otimizado ao AVD do NeoNews
a29923f feat: coletar baseline do runtime Android
a6d6670 feat: aplicar configuracao kiosk no Android
a89dc3d chore: limpar formatacao do supervisor
93801ea chore: limpar formatacao da documentacao de startup
9afd186 feat: adicionar launcher WPF do runtime
166f318 chore: limpar fim do coletor de diagnosticos
d5131db feat: adicionar bootstrap resiliente do runtime
17d0904 chore: limpar formatacao do benchmark
1769ac chore: limpar documentacao de regressao
```

## Conclusão

O runtime está preparado para continuar a homologação assim que as dependências externas forem disponibilizadas. A infraestrutura não declara suporte funcional ao NeoNews enquanto a ABI, o WebView 119 e o RHVoice não forem comprovados no mesmo guest.

