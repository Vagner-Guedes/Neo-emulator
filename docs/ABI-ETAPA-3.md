# Compatibilidade de ABI — Etapa 3

Data da validação: **2026-09-01**  
APK avaliado: `com.in9midia.neonews.player`, versão `9.0.3` (`versionCode 522`)

## Resultado

O APK contém bibliotecas nativas somente para:

- `arm64-v8a`
- `armeabi-v7a`

Não há `x86` nem `x86_64`. A execução funcional do NeoNews não foi homologada neste host Windows x64.

## Evidências

### Imagem x86 com Emulator atual

O AVD `NeoNews_API25_x86` inicializou em Android 7.1.1/API 25. A instalação falhou com:

```text
INSTALL_FAILED_NO_MATCHING_ABIS: Failed to extract native libraries, res=-113
```

A imagem também foi inspecionada diretamente:

```text
ro.product.cpu.abi=x86
ro.dalvik.vm.native.bridge=0
ls /system/lib/libhoudini.so
ls /system/lib64/libhoudini.so
No such file or directory
```

Conclusão: o AVD x86 não oferece uma native bridge ARM instalada.

### Imagens ARM no Emulator atual

O Android Emulator `37.1.11` recusou as imagens ARM API 25:

```text
QEMU2 emulator does not support arm64 CPU architecture
CPU Architecture 'arm' is not supported by the QEMU2 emulator, (the classic engine is deprecated!)
```

### Emulator legado ARM32

Foi testado o Emulator oficial `32.1.11` com o AVD `NeoNews_API25_arm32`. O guest iniciou com:

```text
ro.product.cpu.abi=armeabi-v7a
ro.product.cpu.abi2=armeabi
ro.build.version.sdk=25
```

O APK foi copiado para `/data/local/tmp/app.apk`, mas o `PackageManager` ficou bloqueado durante o `dex2oat`. O Android 7.1.1 encerrou o `system_server` pelo watchdog:

```text
WATCHDOG KILLING SYSTEM PROCESS: Blocked in handler on PackageManager (PackageManager)
at com.android.server.pm.PackageDexOptimizer.performDexOpt(PackageDexOptimizer.java:102)
at com.android.server.pm.PackageManagerService.installPackageLI(PackageManagerService.java:15241)
```

O comando terminou com `android.os.DeadSystemException`; o pacote não foi instalado.

## Decisão da etapa

**Etapa 3 concluída como investigação, com bloqueio de execução.** Não será instalado um bridge de origem não homologada nem será alterado o APK proprietário.

Para prosseguir com as etapas funcionais, é necessário um destes caminhos:

1. uma build NeoNews contendo `x86`/`x86_64`;
2. uma native bridge ARM legalmente distribuível e validada;
3. um dispositivo ou host com execução ARM real;
4. outro backend de emulação ARM que consiga concluir a instalação e o `dex2oat`.

Até essa decisão, as etapas de WebView, TTS, kiosk e supervisor permanecem especificadas, mas não podem ser homologadas contra o APK real neste ambiente.

