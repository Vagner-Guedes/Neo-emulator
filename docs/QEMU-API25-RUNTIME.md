# QEMU Android-x86 API 25

O backend comercial do NeoNews Runtime é `QemuAndroidRuntimeBackend`. Ele inicia o guest x86_64 com `-accel whpx`, usa a máquina compatível `pc`, um disco IDE qcow2 persistente, a NIC `e1000` compatível com o Android-x86 API 25 e encaminha ADB do host para o endereço explícito do guest:

```text
127.0.0.1:<hostPort>  ->  10.0.2.15:<guestPort>
127.0.0.1:5556        ->  10.0.2.15:5555
```

O `user` network é configurado como `10.0.2.0/24`, com `dhcpstart=10.0.2.15`, e o `hostfwd` aponta para `10.0.2.15:5555`. Assim, o transporte não depende do destino implícito escolhido pelo QEMU; isso ainda não substitui a prova live de que o Android obteve o endereço e que o `adbd` está online.

## Layout portátil

```text
runtime/
  qemu/qemu-system-x86_64.exe
  qemu/share/              # firmware/ROMs do mesmo pacote QEMU
  android/android-x86-7.1-r5.iso
  android/neonews-runtime-v1.qcow2
  adb/adb.exe
  state/provisioning.json
```

O disco final `neonews-runtime-v1.qcow2` não é recriado durante o boot nem durante a atualização do launcher. O diretório `share` é obrigatório: o backend passa `-L runtime/qemu/share` e valida `bios-256k.bin` antes de iniciar. Native Bridge, WebView, RHVoice e o APK oficial são pacotes externos; ficam fora da publicação e devem ser fornecidos separadamente pelo operador, com origem, licença e hash registrados.

## Provisionamento

Ao provisionar a base, informe origens verificáveis para QEMU e ADB (e para a
imagem quando ela for exigida); ao instalar Native Bridge, WebView ou RHVoice,
informe também os respectivos parâmetros `*Origin`. Os scripts rejeitam
componentes sem essa proveniência registrada e nunca baixam binários.

Execute:

```powershell
.\scripts\provision\Provision-QemuAndroidRuntime.ps1 -RequireInstallerImage `
  -QemuOrigin "<origem aprovada/licenca do QEMU>" `
  -AdbOrigin "<origem aprovada/licenca do ADB>" `
  -AndroidImageOrigin "<origem aprovada/licenca da imagem Android-x86>"
```

O script apenas valida arquivos locais e salva hashes no estado de provisionamento. Ele não baixa uma ISO, QEMU, Native Bridge, WebView ou TTS.

O Native Bridge do Android-x86 não é um APK. Para a variante oficial Houdini
do Android-x86 7.1-r5, use o provisionador dedicado, que aceita somente os
endpoints oficiais fixados, pré-carrega os SFS em `/data/arm`, executa
`enable_nativebridge` como root e revalida propriedades, mounts, binfmt e
persistência. Ele não consulta mirrors e não coloca os binários no Git:

```powershell
.\scripts\provision\Provision-NativeBridgeOfficial.ps1
```

Use `-DownloadOfficial` apenas na fase de provisionamento com rede e, ainda
assim, somente os dois URLs oficiais allowlisted são aceitos. A execução normal
não baixa Native Bridge.

Depois que o guest estiver online, a instalação dos componentes locais é uma
operação separada e explícita:

```powershell
.\scripts\provision\Install-GuestComponents.ps1 `
  -InstallWebView -InstallTts `
  -WebViewOrigin "<origem aprovada/licenca do WebView>" `
  -TtsOrigin "<origem aprovada/licenca do RHVoice>"
```

`-SetRhVoiceDefault` e opcional e nao deve ser usado como efeito colateral da
instalacao: sem essa chave, a engine TTS existente e preservada e qualquer
mudanca inesperada e restaurada/verificada. A chave so deve ser usada por
acao explicita depois da homologacao funcional do RHVoice pt-BR.

O comando usa somente os arquivos configurados, `adb install -r` e registra
hashes/estado. O boot normal não instala componentes desconhecidos.

## Fluxo de execução

1. validar QEMU, WHPX, ADB, a imagem Android-x86 aprovada e o qcow2;
2. iniciar QEMU sem `cmd.exe`, PowerShell ou console visível;
3. executar `adb start-server` e `adb connect host:port`;
4. aguardar `get-state=device` e `sys.boot_completed=1`;
5. validar Native Bridge e propriedades de ABI;
6. validar provider WebView e RHVoice conforme a política;
7. instalar/atualizar o APK com `adb install -r`, sem limpar dados;
8. iniciar e confirmar `TerminalActivity` por `dumpsys activity`;
9. ativar kiosk e watchdog.

Para parar, o backend negocia `qmp_capabilities`, exige resposta positiva,
envia `quit` e exige a resposta positiva antes de aguardar o processo; só
usa encerramento forçado após timeout. `adb emu kill` não é usado pelo
backend QEMU.

## Diagnóstico da ABI

Use [`Test-NativeBridge.ps1`](../scripts/validation/Test-NativeBridge.ps1) depois de o guest estar disponível. O relatório registra `guestAbi`, `guestAbiList`, `nativeBridgeProperty`, ABIs do APK, `primaryCpuAbi`, resultado de instalação, lançamento, estabilidade e logcat filtrado. Uma propriedade preenchida, sozinha, nunca declara Native Bridge homologada.
