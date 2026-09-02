# QEMU Android-x86 API 25

O backend comercial do NeoNews Runtime é `QemuAndroidRuntimeBackend`. Ele inicia o guest x86_64 com `-accel whpx`, usa um qcow2 persistente e encaminha ADB do host para o guest:

```text
127.0.0.1:<hostPort>  ->  guest:<guestPort>
127.0.0.1:5556        ->  guest:5555
```

## Layout portátil

```text
runtime/
  qemu/qemu-system-x86_64.exe
  android/android-x86-7.1-r5.iso
  android/neonews-api25.qcow2
  adb/adb.exe
  state/provisioning.json
```

O disco não é recriado durante o boot nem durante a atualização do launcher. Native Bridge, WebView, RHVoice e o APK oficial são pacotes externos; só entram na distribuição quando fornecidos localmente e explicitamente.

## Provisionamento

Execute:

```powershell
.\scripts\provision\Provision-QemuAndroidRuntime.ps1 -RequireInstallerImage
```

O script apenas valida arquivos locais e salva hashes no estado de provisionamento. Ele não baixa uma ISO, QEMU, Native Bridge, WebView ou TTS.

Depois que o guest estiver online, a instalação dos componentes locais é uma
operação separada e explícita:

```powershell
.\scripts\provision\Install-GuestComponents.ps1 `
  -InstallNativeBridge -InstallWebView -InstallTts -SetRhVoiceDefault
```

O comando usa somente os arquivos configurados, `adb install -r` e registra
hashes/estado. O boot normal não instala componentes desconhecidos.

## Fluxo de execução

1. validar QEMU, WHPX, ADB e qcow2;
2. iniciar QEMU sem `cmd.exe`, PowerShell ou console visível;
3. executar `adb start-server` e `adb connect host:port`;
4. aguardar `get-state=device` e `sys.boot_completed=1`;
5. validar Native Bridge e propriedades de ABI;
6. validar provider WebView e RHVoice conforme a política;
7. instalar/atualizar o APK com `adb install -r`, sem limpar dados;
8. iniciar e confirmar `TerminalActivity` por `dumpsys activity`;
9. ativar kiosk e watchdog.

Para parar, o backend solicita `qmp_capabilities`/`quit` via QMP, aguarda o processo e só então usa encerramento forçado após timeout. `adb emu kill` não é usado pelo backend QEMU.

## Diagnóstico da ABI

Use [`Test-NativeBridge.ps1`](../scripts/validation/Test-NativeBridge.ps1) depois de o guest estar disponível. O relatório registra `guestAbi`, `guestAbiList`, `nativeBridgeProperty`, ABIs do APK, `primaryCpuAbi`, resultado de instalação, lançamento, estabilidade e logcat filtrado. Uma propriedade preenchida, sozinha, nunca declara Native Bridge homologada.
