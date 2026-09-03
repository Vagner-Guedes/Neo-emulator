# Homologação Native Bridge ARM + NeoNews oficial

Data da evidência live: `2026-09-03T01:34:42Z`  
Branch: `codex/neonews-runtime-homologation`  
Checkpoint de partida: `8ddd137`

## Decisão

**BLOCKED_NATIVE_BRIDGE_ARTIFACT**

O guest Android-x86 possui a propriedade `ro.dalvik.vm.native.bridge=libnb.so`,
mas isso não prova tradução ARM. A prova live encontrou:

- `persist.sys.nativebridge` vazio;
- `/system/lib/libnb.so`: ELF x86 de 5.584 bytes;
- `/system/lib64/libnb.so`: ELF x86_64 de 10.344 bytes;
- `/system/lib/libhoudini.so`: 0 bytes;
- `/system/lib64/libhoudini.so`: 0 bytes;
- logcat: `libnb: Native bridge is disabled`.

Não existe tradutor ARM funcional provisionado no guest ou um artefato local
autorizado em `packages/nativebridge/nativebridge.apk`. Nenhum binário
proprietário foi baixado, inventado ou adicionado ao Git.

## Tabela de evidências

| Gate | Evidência | Resultado |
|---|---|---|
| ADB baseline | `127.0.0.1:5556 device`, `sys.boot_completed=1`; QEMU/WHPX iniciado; QMP `capabilities` e `quit` confirmados sem forced kill | PASS |
| Guest ABI | `x86_64` | PASS |
| ABI list | `x86_64,x86,armeabi-v7a,armeabi,arm64-v8a` | DECLARADA; não é prova do bridge |
| Native Bridge property | `ro.dalvik.vm.native.bridge=libnb.so` | CONFIGURADA apenas nominalmente |
| Native Bridge binary | `libnb.so` 32/64 presente; `libhoudini.so` 32/64 com 0 bytes | MISSING |
| Native Bridge functional | `persist.sys.nativebridge` vazio; logcat informa bridge desabilitado | BLOCKED |
| APK SHA-256 | `1AB417F031426B9CD5A4320F00825FF538EFBE4B7564B7EDA3CDD3395068D760` | IDENTIDADE PRESERVADA |
| APK identidade | `com.in9midia.neonews.player`, `9.0.3`, `versionCode 522`; certificado `220848A28B1DE2254C1AC5D3366A64A2F909C265E05DC3495F4B04FCF9CDF91A` | PASS |
| APK ABIs | `armeabi-v7a`, `arm64-v8a`; bibliotecas nativas ARM; nenhum `x86`/`x86_64` | PASS |
| Install result | Uma execução inicial de `adb install -r` deixou o package instalado; `pm path`, versão e `primaryCpuAbi` foram confirmados. O validador antigo falhou antes de serializar stdout/exit code; a execução corrigida parou antes de reinstalar | EVIDÊNCIA INCOMPLETA; não aprova o gate |
| Installed version | `versionName=9.0.3`, `versionCode=522` | PASS |
| primaryCpuAbi | `armeabi-v7a` | COMPATÍVEL nominalmente; execução ARM não comprovada |
| TerminalActivity launch | `am start` retornou exit 0, mas o app seguiu para `LoadConfigActivity`; TerminalActivity não permaneceu confirmada em primeiro plano | NÃO HOMOLOGADO |
| 60s stability | Não aprovado; o bridge foi bloqueado antes do teste ARM completo | NÃO EXECUTADO |
| Restart x3 | Não executado após o bloqueio do bridge | PENDING |
| Guest reboot x3 | Um reboot subsequente preservou o package; os 3 ciclos exigidos não foram executados | PENDING |
| Persistence | `pm path` continuou apontando para `/data/app/com.in9midia.neonews.player-1/base.apk` após o boot subsequente | OBSERVADA; não equivale a 3 reboots |
| Logcat result | `Native bridge is disabled`; também houve ANR do `NeonewsGuardianService`; não houve prova de bibliotecas ARM carregadas | BLOCKED |
| Build validation | Host tem .NET runtime 8.0.27, mas não possui .NET SDK | BUILD VALIDATION PENDING |

## Inventário do guest

O guest foi validado como Android `7.1.2` / API `25`, com ADB TCP no endpoint
configurado. A rede permaneceu em IPv4 `10.0.2.15/24`, rota default via
`10.0.2.2`, DNS `10.0.2.3` e `bindv6only=0`. O relay ADB aprovado não foi
alterado.

O locale observado foi `en-US`. Ele foi apenas registrado como pendência;
nenhuma alteração de locale, TTS ou voz foi feita nesta meta.

## Estado integrado

- `config/runtime.json`: Native Bridge `missing`, ABI validation e integração
  NeoNews `blocked-native-bridge-artifact`, `validated=false`.
- `runtime/state/provisioning.json`: `nativeBridgeStatus` marcado como
  `blocked-native-bridge-artifact`.
- O snapshot tipado do launcher agora diferencia `Unknown`, `Missing`,
  `Configured`, `Ready` e `Error`, e os diagnósticos expõem `persist.sys.nativebridge`
  e os tamanhos dos artefatos do guest.
- O validador interrompe antes de uma nova instalação quando o tradutor ARM
  não possui conteúdo real.

Nenhum debloat, `pm clear`, uninstall, remoção de package, troca de WebView,
alteração de RHVoice/TTS ou alteração do relay ADB foi executado nesta meta.

## Próximo desbloqueio

Fornecer um artefato Native Bridge ARM legalmente provisionado e compatível com
este Android-x86 API 25, sem adicioná-lo ao Git. Depois disso, repetir a
homologação live no mesmo endpoint `127.0.0.1:5556`, começando pelo inventário
do bridge. O APK NeoNews oficial não deve ser modificado, recompilado ou
resinado.
