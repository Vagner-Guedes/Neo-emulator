# Modo kiosk — Etapa 9

Data: **2026-09-01**  
Script: [`scripts/runtime/Apply-KioskSettings.ps1`](../scripts/runtime/Apply-KioskSettings.ps1)

## Configurações

O script aplica no guest Android:

- display lógico `1920×1080` e densidade `160`;
- `immersive.full=*` para ocultar barras do sistema;
- timeout de tela `2147483647 ms`;
- permanência acordado quando conectado à energia;
- screensaver desabilitado;
- orientação fixa landscape.

O script suporta `-WhatIf` e sempre relata se o pacote NeoNews está instalado. A presença do APK não é presumida.

## Atalho operacional

No launcher publicado, `Ctrl+Alt+Shift+F12` e o atalho persistente para alternar entre a
janela normal e o modo fullscreen/kiosk. A configuracao do guest e o estado
original da janela continuam transacionais e sao restaurados ao sair.

## Validação

Foi aplicada a configuração ao AVD API 25 x86 após o boot. Como o NeoNews não está instalado neste AVD por incompatibilidade de ABI, o estado reportado é:

```text
status=kiosk-applied-package-absent
```

O display passou a reportar `1920×1080` e `160 dpi` no guest após a aplicação via `wm`.

## Decisão da etapa

**Etapa 9 concluída para o guest Android, com vínculo ao app pendente.** O launcher/home definitivo e a confirmação de fullscreen do NeoNews dependem da instalação do APK ARM ou de uma build compatível com x86.
