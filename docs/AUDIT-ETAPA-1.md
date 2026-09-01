# Auditoria inicial — Etapa 1

Data da coleta: **2026-09-01**  
Projeto: **NeoNews Digital Signage Runtime**  
Entrada analisada: `app.apk` (mantida fora do Git por ser um binário proprietário fornecido externamente)

## Resultado executivo

O APK do NeoNews é instalável a partir de `minSdk 15`, mas foi compilado com `targetSdk 36`. Ele contém código e bibliotecas nativas somente para ARM (`arm64-v8a` e `armeabi-v7a`). Portanto, a imagem Android x86 prevista na meta só poderá ser usada depois de validar uma ponte ARM/native bridge em execução real; não há base para assumir que Houdini esteja disponível.

O APK ainda não foi executado nesta máquina. A validação funcional está bloqueada até que o Android SDK, o Emulator, uma imagem API 25 e ADB sejam provisionados.

## Repositório

- Diretório: `C:\Users\vagne\Desktop\Neo-emulator`
- Remoto `origin`: `https://github.com/Vagner-Guedes/Neo-emulator.git`
- Estado desta etapa: primeiro commit local a ser criado após este documento
- O APK original está ignorado pelo `.gitignore`; ele não será distribuído pelo repositório.

## APK NeoNews

| Campo | Valor |
|---|---|
| Arquivo | `app.apk` |
| Tamanho | 58.954.286 bytes |
| SHA-256 do arquivo | `1AB417F031426B9CD5A4320F00825FF538EFBE4B7564B7EDA3CDD3395068D760` |
| Package | `com.in9midia.neonews.player` |
| Rótulo | `Neonews Player` |
| Version name | `9.0.3` |
| Version code | `522` |
| minSdk | `15` |
| targetSdk | `36` |
| Activity principal indicada pelo analisador | `com.in9midia.neonews.player.ConfigActivity` |
| Assinatura | APK Signature Scheme v1 e v2; v3 não presente |
| SHA-256 do certificado de assinatura | `220848a28b1de2254c1ac5d3366a64a2f909c265e05dc3495f4b04fcf9cdf91a` |

### ABIs e bibliotecas nativas

ABIs presentes no APK:

- `arm64-v8a`
- `armeabi-v7a`

Não existem diretórios `lib/x86` ou `lib/x86_64`.

Bibliotecas presentes em cada ABI:

- `libUACAudio.so`
- `libUVCCamera.so`
- `libc++_shared.so`
- `libjpeg-turbo1500.so`
- `libnativelib.so`
- `libusb100.so`
- `libuvc.so`
- `libvlc.so`
- `libvlcjni.so`

**Conclusão ABI:** APK ARM → arquitetura Android ainda não escolhida. A imagem x86/API 25 exige validação de native bridge; uma imagem ARM compatível pode ser necessária caso a ponte não funcione.

## Componentes Android declarados

### Activities

- `TerminalActivity`: `MAIN`, `DEFAULT`, `LAUNCHER`, `LEANBACK_LAUNCHER`; também recebe USB device attached.
- `ConfigActivity`: `MAIN`, `LAUNCHER`.
- `OnlineActivity`: `MAIN`, `LAUNCHER`.
- `LogActivity`, `ErrorActivity`, `ListInstalledApps`, `BlackActivity`, `LoadConfigActivity`: atividades auxiliares.
- `CrashActivity`: processo `:crash`.
- `CrashLoadConfigActivity`: processo `:load`.
- `ProcessPhoenix`: processo `:phoenix`.

Há múltiplas activities exportadas com filtros `MAIN`. O launcher do runtime deverá iniciar explicitamente a activity de operação correta, em vez de depender da resolução implícita do launcher Android.

### Services

- `NeonewsGuardianService`, processo `:guardian`.
- `SGAService`, processo `:sga`.
- `NeonewsAccessibilityService`, processo `:accessibility`, protegido por `BIND_ACCESSIBILITY_SERVICE`.

### Receivers

- `NeonewsAutoStart`: `BOOT_COMPLETED`, `QUICKBOOT_POWERON` e evento equivalente da HTC.
- `NeonewsOnUpdate`: `PACKAGE_REPLACED` para o próprio pacote.
- `HdmiListener`: `HDMI_PLUGGED`.

### Provider

- `androidx.startup.InitializationProvider`.

## Permissões e recursos exigidos

Permissões declaradas relevantes:

- Rede: `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`.
- Persistência: `WRITE_EXTERNAL_STORAGE`.
- Inicialização e operação contínua: `RECEIVE_BOOT_COMPLETED`, `WAKE_LOCK`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `REORDER_TASKS`.
- Hardware: `CAMERA`, `RECORD_AUDIO`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION`.
- Operação dedicada: `SYSTEM_ALERT_WINDOW`, `GET_TASKS`.

Features declaradas:

- `android.hardware.usb.host`: **obrigatório**.
- Câmera, microfone, Wi-Fi, Bluetooth, localização, sensores, tela landscape, touchscreen e Leanback: opcionais.

A aplicação também declara `usesCleartextTraffic=true`, `networkSecurityConfig`, `largeHeap`, `hardwareAccelerated=true`, `allowBackup=false` e `extractNativeLibs=true`. Esses valores deverão ser considerados no diagnóstico e na revisão de segurança, sem alteração cega do APK.

## Evidências de funcionalidades usadas

A inspeção dos DEX e do manifesto encontrou referências a:

- `android.webkit.WebView` e `androidx.webkit`.
- ExoPlayer/ExoMedia, `MediaCodec` e `MediaPlayer`.
- LibVLC e `libvlcjni`.
- HLS e `.m3u8`.
- OkHttp e WebSocket.
- Câmera Android, USB/UVC e áudio USB.
- `android.speech.tts.TextToSpeech` e recursos relacionados a voz; há referência a `Portuguese_Brazil`.
- Accessibility Service, wake lock e inicialização após boot.

Isso confirma que não é seguro remover WebView, MediaCodec, áudio, rede, armazenamento, USB, câmera ou serviços de inicialização antes dos testes funcionais correspondentes. A presença de referências não comprova que cada fluxo está operacional.

## Ambiente auditado

| Item | Resultado |
|---|---|
| Sistema | Windows 11 Home Single Language, build `26200`, x64 |
| CPU | Intel Core i5-10300H, 4 cores / 8 threads |
| RAM detectada | 8.451.772.416 bytes (~7,9 GiB) |
| GPU | NVIDIA GeForce GTX 1650 e Intel UHD Graphics |
| Espaço livre em C: | 88.523.870.208 bytes (~82,4 GiB) |
| .NET | Runtime 8.0.27 instalado |
| .NET SDK | Não instalado |
| Java/JAVA_HOME | Não encontrado / não configurado |
| ADB | Não encontrado |
| Emulator | Não encontrado |
| `sdkmanager` / `avdmanager` | Não encontrados |
| `aapt` / `aapt2` / `apkanalyzer` | Não encontrados |
| Android SDK variables | `ANDROID_HOME` e `ANDROID_SDK_ROOT` não configuradas |

O `systeminfo` informa que há um hipervisor detectado, mas os dados WMI disponíveis nesta sessão não comprovam VT-x/AMD-V, SLAT nem a disponibilidade de WHPX. Essa capacidade deverá ser verificada novamente durante o provisionamento do Emulator, com privilégio suficiente e evidência de boot acelerado.

## Pendências que bloqueiam a Etapa 2

1. Instalar um JDK compatível e o .NET SDK necessário para desenvolvimento WPF.
2. Provisionar somente as ferramentas Android necessárias: command-line tools, platform-tools, emulator e imagem API 25.
3. Escolher uma imagem API 25 com base no teste ARM: x86 com native bridge comprovada ou alternativa ARM compatível.
4. Executar instalação do APK e registrar `adb shell getprop`, ABI efetiva, logs de carregamento das bibliotecas e activity de operação.
5. Só depois validar WebView, TTS, vídeo, áudio, USB/UVC, rede, persistência e boot.

## Escopo não comprovado nesta etapa

Ainda não há evidência de boot do Android, funcionamento da WebView 119, RHVoice, aceleração de GPU, reprodução de mídia, streaming, modo kiosk, watchdog, startup do Windows ou comportamento offline. Esses itens permanecem como etapas posteriores e não devem ser marcados como concluídos com base apenas na análise estática.

