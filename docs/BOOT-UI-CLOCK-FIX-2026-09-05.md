# Relatório — correção de boot, UI e relógio

**Data:** 2026-09-05  
**Branch:** `codex/neonews-runtime-homologation`

## Escopo

Esta etapa tratou somente do boot e da apresentação do NeoNews no Android:

- taskbar do Android-x86;
- confirmação visual de modo imersivo/tela cheia;
- receiver legado `NeonewsAutoStart`;
- sincronização do relógio com o Windows;
- ordem de entrada no kiosk antes da abertura do NeoNews.

RHVoice, WebView, Native Bridge, APK, política de debloat e dados do NeoNews não foram instalados, removidos, limpos ou substituídos nesta etapa.

## Causa identificada

O logcat do overlay de teste registrou:

```text
android.view.WindowManager$BadTokenException: Unable to add window
... Toast$TN.handleShow
Process: com.in9midia.neonews.player
```

O processo era iniciado pelo receiver `com.in9midia.neonews.player/.NeonewsAutoStart` durante o boot. Esse receiver exibia um Toast antes de existir um token de Activity, causando o crash do processo e impedindo a inicialização determinística do player.

## Correções persistentes no projeto

1. `config/runtime.json` fixa:
   - `startFullscreen=true`;
   - `immersiveModeConfirmation=confirmed`;
   - taskbar `com.farmerbb.taskbar.androidx86` desabilitado;
   - `com.in9midia.neonews.player/.NeonewsAutoStart` desabilitado.
2. `GuestConfigurationService` aplica e verifica essas políticas em cada inicialização.
3. `WaitForBootAsync` tenta desabilitar taskbar e receiver assim que ADB fica disponível, antes do broadcast `BOOT_COMPLETED`.
4. O kiosk é ativado antes de lançar o NeoNews, evitando flash de taskbar, barra de navegação ou confirmação de tela cheia.
5. O relógio continua usando RTC UTC no QEMU e aplica o horário local do Windows depois de aguardar a aplicação do fuso `America/Sao_Paulo`.
6. A mesma política foi adicionada ao script operacional `Apply-KioskSettings.ps1`.
7. O timeout persistente de boot foi ampliado para 600 s para acomodar a
   varredura/dexopt do Android 7.1.2; sondagens esperadas (`offline` e tarefa
   Windows inexistente) não poluem mais o log visível como erro.

## Evidências

| Verificação | Resultado |
|---|---|
| Build Release do launcher | PASS — 0 avisos, 0 erros |
| Validação estática do repositório | PASS — sem erros de contrato |
| Configuração de taskbar/immersive/receiver | PASS — valores fixados e verificações presentes |
| Proteção precoce antes de `BOOT_COMPLETED` | PASS — contrato estático |
| Configuração do QEMU em tela cheia | PASS — contrato estático |
| Sincronização de relógio após troca de fuso | PASS — contrato estático; ciclo manual anterior coincidiu com o Windows |
| App, Power BI e `TerminalActivity` | PASS no ciclo funcional anterior: URL Power BI carregada e Activity em foreground por 60 s |
| Cold boot novo após essas mudanças | NÃO HOMOLOGADO — dois overlays novos permaneceram `offline` além de 300 s durante a varredura inicial do Package Manager; o limite persistente foi então ampliado para 600 s |

O último item é uma falha de boot do guest/imagem de teste, não foi convertido em aprovação do player. O QEMU permaneceu responsivo e `qemu-img check` não apontou corrupção no overlay.

## Próximos passos

1. Repetir o cold boot em uma imagem já com a política de receiver persistida e coletar `sys.boot_completed=1`.
2. Confirmar após reboot: taskbar disabled, `policy_control=immersive.full=*`, `immersive_mode_confirmations=confirmed`, locale `pt-BR` e relógio com desvio máximo de 5 s.
3. Abrir o NeoNews, confirmar `mResumedActivity`/`mFocusedActivity` em `TerminalActivity` por 60 s e coletar logcat filtrado por `NativeBridge`, `Houdini`, `linker`, `UnsatisfiedLinkError`, `FATAL EXCEPTION` e `crash`.
4. Só depois executar novamente o endurance integrado de 600 s. WebView 119, RHVoice pt-BR e conteúdo real do Power BI continuam gates independentes e ainda não devem ser marcados como produção.
