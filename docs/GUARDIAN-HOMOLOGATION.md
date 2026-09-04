# Homologacao do Guardian - NeoNews Runtime V1

**Data da rodada:** 2026-09-04
**Status:** **BLOCKED / NOT PRODUCTION READY**

Este documento registra somente evidencia. Nenhum comportamento foi alterado
na rodada evidence-only.

## Evidencia registrada

- O codigo possui intencao persistente `UserStoppedRuntime` e o Guardian
  consulta essa intencao antes de tentar recuperar o runtime.
- O smoke da publicacao atual confirmou single-instance e encerramento
  `--exit` sem processo residual.
- O boot real desta rodada nao atingiu `sys.boot_completed=1`. O ADB privado
  alternou entre `offline`, `device` e desconectado; o QEMU registrou
  `WHPX: Unexpected VP exit code 4` e foi encerrado via QMP pelo fluxo de
  limpeza.
- Por causa da falha de boot, nao ha prova live nesta rodada para crash do
  NeoNews, parada humana, recuperacao do runtime, startup, kiosk, tray,
  fullscreen, F11/F12 ou ausencia de relancamento apos `USER_STOPPED_RUNTIME`.
- O gate de janelas tecnicas permanece `pending-evidence`: o monitor
  `SetWinEventHook` observou somente `launcher-diagnostics`; os demais
  cenarios exigidos nao foram executados.

## Atalhos configurados

A configuração persistente agora declara `Ctrl+Alt+Shift+F11` para parada segura,
`Ctrl+Alt+Shift+F12` para fullscreen/janela e `Ctrl+Alt+Shift+F10` para exibir
o painel. As teclas simples `F11` e `F12` não são registradas. A evidência live
destes atalhos ainda está pendente porque o boot desta rodada não completou.

## Proximo gate permitido

Corrigir somente a causa comprovada do boot/ADB/WHPX, se autorizado, e
reexecutar diretamente o boot, a matriz de intencoes e os 12 cenarios de
console. Ate que essas evidencias existam, o Guardian nao esta homologado
para producao.
