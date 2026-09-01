# Runtime base — Etapa 2

Data da validação: **2026-09-01**  
Objetivo: provisionar as ferramentas Android, a imagem API 25 e AVDs para testar as ABIs do APK NeoNews.

## Componentes provisionados

SDK local utilizado durante a validação:

`C:\Users\vagne\AppData\Local\Android\Sdk`

| Componente | Versão/revisão |
|---|---|
| Android SDK Command-Line Tools | `15859902` |
| SHA-256 do pacote command-line tools | `90AE805D20434428BFFCB699C290860F19BB5F66A67E6B330067E3DE801FB04A` |
| Java | Microsoft OpenJDK `17.0.10.7` |
| SDK Platform-Tools | `37.0.1` |
| Android Emulator | `37.1.11` |
| Android Platform | `android-25`, revisão `3` |
| Build-Tools | `25.0.3` |
| Google APIs x86 | API 25, revisão `18` |
| Google APIs ARM32 | API 25, revisão `18` |
| Google APIs ARM64 | API 25, revisão `20` |

O command-line tools foi organizado em `cmdline-tools/latest`, conforme a documentação oficial. O SDK Manager também foi usado para instalar as plataformas, o Emulator e as imagens; o repositório contém o script reproduzível, não os binários do SDK.

## AVDs criados

- `NeoNews_API25_x86`
- `NeoNews_API25_arm32`
- `NeoNews_API25_arm64`

Os AVDs foram criados com o perfil `pixel_2` apenas como perfil técnico inicial. A resolução, orientação landscape, RAM, GPU e demais parâmetros ainda precisam ser ajustados após a compatibilidade do APK ser resolvida.

## Evidência de aceleração

Comando executado:

```text
emulator -accel-check
```

Resultado:

```text
accel:
0
WHPX(10.0.26200) is installed and usable.
accel
```

Logo, o Windows expõe WHPX para imagens x86/x86_64. Isso não habilita execução de uma imagem ARM: aceleração de VM e tradução de ABI são problemas distintos.

## Smoke test do AVD x86

O AVD x86 foi iniciado com:

```text
emulator -avd NeoNews_API25_x86 -no-window -gpu swiftshader -no-boot-anim -no-snapshot -accel auto -timezone America/Bahia -port 5556
```

Evidências coletadas por ADB:

```text
sys.boot_completed=1
init.svc.bootanim=stopped
ro.build.version.release=7.1.1
ro.build.version.sdk=25
ro.product.cpu.abi=x86
ro.bootimage.build.fingerprint=google/sdk_google_phone_x86/generic_x86:7.1.1/NYC/6695155:userdebug/test-keys
```

O boot base do Android 7.1.1/API 25 funciona no host.

## Teste da ABI do NeoNews

Comando executado no AVD x86:

```text
adb -s emulator-5556 install -r app.apk
```

Resultado real:

```text
INSTALL_FAILED_NO_MATCHING_ABIS: Failed to extract native libraries, res=-113
```

Isso confirma que a imagem x86 não possui uma native bridge capaz de carregar as bibliotecas ARM do APK.

## Teste das imagens ARM

O Emulator `37.1.11` recusou as duas variantes ARM:

```text
QEMU2 emulator does not support arm64 CPU architecture
```

e:

```text
CPU Architecture 'arm' is not supported by the QEMU2 emulator, (the classic engine is deprecated!)
```

O mesmo resultado ocorreu ao solicitar `-engine classic` para ARM32. Portanto:

```text
APK ARM → x86 sem bridge: falha por ABI
APK ARM → ARM64 no Emulator oficial atual: arquitetura não suportada
APK ARM → ARM32 no Emulator oficial atual: arquitetura não suportada
```

## Estado da etapa

**Concluído:** SDK local, API 25 final, AVDs de comparação, boot x86 e diagnóstico WHPX.  
**Não concluído:** execução do NeoNews.

A Etapa 3 não pode ser marcada como concluída nesta máquina. As opções técnicas que permanecem são:

1. disponibilizar uma build NeoNews com `x86`/`x86_64` nativo;
2. obter e validar uma native bridge ARM legalmente distribuível para a imagem x86;
3. executar o teste em um host/dispositivo com suporte real à arquitetura ARM;
4. usar outro backend de virtualização/emulação que suporte ARM e medir seu desempenho.

Não foi instalada nenhuma bridge de fonte não homologada e nenhuma otimização do Android foi aplicada.

## Referências oficiais

- [SDK Manager](https://developer.android.com/tools/sdkmanager)
- [Notas da plataforma Android 7.1/API 25](https://developer.android.com/tools/releases/platforms)
- [Inicialização do Emulator por linha de comando](https://developer.android.com/studio/run/emulator-commandline)
- [Aceleração do Android Emulator](https://developer.android.com/studio/run/emulator-acceleration)

