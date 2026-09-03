# Homologação Native Bridge ARM + NeoNews oficial

Data da evidência live: `2026-09-03T01:34:42Z`  
Branch: `codex/neonews-runtime-homologation`  
Checkpoint de partida: `8ddd137`

## Decisão

**BLOCKED_NATIVE_BRIDGE_ARTIFACT**

Este bloco preserva o baseline inicial. A secao posterior
`Provisionamento oficial bem-sucedido em overlay descartavel` registra o
desbloqueio posterior em copia descartavel, sem alterar a base aprovada.

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

## Investigacao do mecanismo oficial no overlay descartavel

Data da execucao: `2026-09-03T01:52:26Z` a `2026-09-03T01:53:41Z`
Base: `runtime/android/adb-tcp-provisioned-api25.qcow2`
Overlay: `runtime/android/nativebridge-investigation-9d0eeccd85174cbd9bf0403e0d345fd6.qcow2`
SHA-256 do disco aprovado antes/depois: `F4AD7075326D78814128941F66F5FFCE0E93F6A054A11652FCF19020120A343B`
Resultado do overlay: `BLOCKED_OFFICIAL_ARTIFACT_FETCH`

O overlay qcow2 foi iniciado com QEMU/WHPX e ADB TCP `127.0.0.1:5556`; o
disco aprovado nao recebeu escrita. O overlay foi mantido localmente como
evidencia descartavel e nao foi promovido ao runtime.

### Script e artefatos esperados

O arquivo existe no guest:

- caminho: `/system/bin/enable_nativebridge`;
- tipo: script `/system/bin/sh`;
- tamanho: `2.199` bytes;
- SHA-256: `e5b59f57d1dee568e2eee0bab09d84a1480c11bc5364737b193cfd6d53a4f4aa`.

O conteudo do script espera os seguintes artefatos/URLs:

| Condicao do script | Variante | URL literal esperada | Arquivo esperado | Alvos do tradutor |
|---|---|---|---|---|
| `uname -m=x86_64`, sem argumento | `7_y` / ARM32 | `http://tinyurl.com/16f0ntql` | `/data/arm/houdini7_y.sfs` | `/system/lib/libhoudini.so`, `/system/bin/houdini` |
| `uname -m` diferente de `x86_64`, sem argumento | `7_x` / x86 | `http://tinyurl.com/5gp5xo99` | `/data/arm/houdini7_x.sfs` | `/system/lib/libhoudini.so`, `/system/bin/houdini` |
| argumento `64` | `7_z` / ARM64 | `http://tinyurl.com/yee4xnfw` | `/data/arm/houdini7_z.sfs` | `/system/lib64/libhoudini.so`, `/system/bin/houdini64` |

Como o guest reporta `uname -m=x86_64` e `ro.zygote=zygote64_32`, a primeira
tentativa requerida para `armeabi-v7a` foi `7_y`; se ela concluisse, o script
tambem encadearia a tentativa `7_z` para o zygote 64/32. Nenhuma URL foi
resolvida ou substituida externamente e nenhum mirror foi consultado.

### Execucao e falha

Estado inicial: `persist.sys.nativebridge` vazio, `ro.dalvik.vm.native.bridge=libnb.so`,
`/system/lib/libhoudini.so` e `/system/lib64/libhoudini.so` com `0` bytes.

1. `adb shell setprop persist.sys.nativebridge 1` terminou com exit `0` e a
   propriedade foi confirmada como `1`.
2. `adb shell enable_nativebridge` foi executado. O script terminou em retry;
   sua saida observada foi:

   ```text
   /system/bin/enable_nativebridge[41]: cd: /data/arm: Permission denied
   mount: bad /etc/fstab: No such file or directory
   wget: bad address 'tinyurl.com'
   rm: houdini7_y.sfs: No such file or directory
   ```

   O processo foi interrompido apos o retry para evitar loop indefinido; nao
   houve instalacao alternativa do artefato.
3. A execucao ocorreu como `uid=2000(shell)`, portanto o script nao conseguiu
   acessar `/data/arm`; alem disso, o `wget` nao conseguiu resolver o host
   `tinyurl.com`. O mecanismo oficial nao obteve o artefato.

Inventario de artefatos baixados:

| Origem | Nome | Tamanho | SHA-256 | Resultado |
|---|---|---:|---|---|
| Nenhum download concluido | `houdini7_y.sfs` | N/A | N/A | URL inacessivel (`bad address`) |
| Nenhum download iniciado | `houdini7_z.sfs` | N/A | N/A | nao alcancado apos falha de `7_y` |

Os arquivos existentes antes/depois permaneceram sem conteudo:

- `/system/lib/libhoudini.so`: `0` bytes,
  SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`;
- `/system/lib64/libhoudini.so`: `0` bytes,
  SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`;
- apos rollback, `persist.sys.nativebridge=0` e
  `ro.dalvik.vm.native.bridge=libnb.so`.

O logcat tambem registrou `Unable to open /system/lib/libhoudini.so` e
negacoes de acesso ao arquivo pelo processo do aplicativo. A busca filtrada
incluiu `NativeBridge`, `Houdini`, `linker`, `UnsatisfiedLinkError`, sinais de
crash e excecoes fatais; nao houve prova de biblioteca ARM carregada.

Por causa da falha do mecanismo oficial, o fluxo parou antes de reboot,
confirmacao de persistencia, execucao do NeoNews e teste de estabilidade de
60 segundos. Portanto `primaryCpuAbi=armeabi-v7a` e `TerminalActivity` nao
foram re-homologados nesta execucao.

## Provisionamento oficial bem-sucedido em overlay descartavel

Data da validacao: `2026-09-03`
Base somente leitura: `runtime/android/adb-tcp-provisioned-api25.qcow2`
SHA-256 da base antes/depois: `F4AD7075326D78814128941F66F5FFCE0E93F6A054A11652FCF19020120A343B`
Overlay utilizado: `runtime/android/nativebridge-official-455658f4e32e4babb46230523e3ba718.qcow2`
Resultado do gate: `READY_STRUCTURAL_AND_RUNTIME_INITIALIZED` no overlay; o qcow2 aprovado nao foi promovido.

Esta secao substitui somente a conclusao da investigacao anterior sobre a obtencao do artefato. A falha anterior de `tinyurl.com` continua registrada acima como historico; nesta execucao os arquivos foram obtidos previamente de endpoints oficiais diretos e colocados em `/data/arm` antes da chamada ao script. Nenhum mirror foi consultado.

### Script oficial do guest

`/system/bin/enable_nativebridge` existe como script `/system/bin/sh`, com 2.199 bytes e SHA-256 `E5B59F57D1DEE568E2EEE0BAB09D84A1480C11BC5364737B193CFD6D53A4F4AA`. O conteudo foi capturado integralmente. Os URLs literais esperados por ele sao:

| Caminho do script | Variante | URL literal esperada | Arquivo esperado | Arquitetura | Funcao |
|---|---|---|---|---|---|
| `uname -m=x86_64`, sem argumento | `7_y` | `http://tinyurl.com/16f0ntql` | `/data/arm/houdini7_y.sfs` | ARM32 | traduzir executaveis e bibliotecas `armeabi-v7a` |
| argumento `64` | `7_z` | `http://tinyurl.com/yee4xnfw` | `/data/arm/houdini7_z.sfs` | ARM64 | suportar o ramo `zygote64_32` |

O guest reporta `uname -m=x86_64` e `ro.zygote=zygote64_32`; por isso o `7_y` foi provisionado primeiro e o proprio script encadeou o ramo `64`. Os endpoints oficiais diretos usados para obter os mesmos artefatos foram `http://dl.android-x86.org/houdini/7_y/houdini.sfs` e `http://dl.android-x86.org/houdini/7_z/houdini.sfs`. O nome local foi normalizado para o nome esperado pelo script; o conteudo nao foi alterado.

### Proveniencia dos artefatos

| Origem oficial | Nome | Variante | Arquitetura | Tamanho | SHA-256 | Git |
|---|---|---|---|---:|---|---|
| `http://dl.android-x86.org/houdini/7_y/houdini.sfs` | `houdini7_y.sfs` | `7_y` | ARM32 | `37728256` | `56FD08C448840578386A71819C07139122F0AF39F011059CE728EA0F3C60B665` | fora do Git |
| `http://dl.android-x86.org/houdini/7_z/houdini.sfs` | `houdini7_z.sfs` | `7_z` | ARM64 | `37253120` | `7EEDC42015E6FB84A11A406A099241EFCCC20D4E020D476335A5FDB6E69A33D2` | fora do Git |

Os arquivos sao mantidos localmente em `packages/nativebridge/houdini7_y.sfs` e `packages/nativebridge/houdini7_z.sfs`; esse diretorio esta ignorado pelo Git. O runtime final nao depende de download durante o boot.

### Sequencia executada

1. QEMU/WHPX foi iniciado sobre o overlay, com ADB TCP em `127.0.0.1:5556`; o estado foi `device` e `sys.boot_completed=1`.
2. `adb root` terminou com `restarting adbd as root` e `id` confirmou `uid=0(root)` com contexto `u:r:su:s0`.
3. Os dois SFS foram enviados para `/data/arm/`; os hashes calculados no guest coincidiram com a tabela acima.
4. `adb shell setprop persist.sys.nativebridge 1` terminou com exit `0` e `getprop persist.sys.nativebridge` retornou `1`.
5. `adb shell enable_nativebridge` foi executado como root e terminou com exit `0`, sem baixar um arquivo alternativo.

Antes do provisionamento, os dois `libhoudini.so` tinham conteudo zero. A validacao logo depois do script encontrou:

| Arquivo | Tamanho | SHA-256 | Tipo observado |
|---|---:|---|---|
| `/system/lib/libhoudini.so` | `4957408` | `AA24BBFEB0E88150A8C5F4091BA07B692F091A09BD67A8EF86DF9DC287C5F3A4` | ELF 32-bit LSB 386 |
| `/system/lib64/libhoudini.so` | `6187512` | `540416E50CB3622E2805E62BFFEF525459EA57BA29B7333E12B9DCF309D20579` | ELF 64-bit LSB x86-64 |

Tambem foram observados os mounts:

```text
/dev/block/loop0 on /system/lib/arm type squashfs (ro,seclabel,relatime)
/dev/block/loop0 on /system/lib/libhoudini.so type squashfs (ro,seclabel,relatime)
/dev/block/loop1 on /system/lib64/arm64 type squashfs (ro,seclabel,relatime)
/dev/block/loop1 on /system/lib64/libhoudini.so type squashfs (ro,seclabel,relatime)
none on /proc/sys/fs/binfmt_misc type binfmt_misc (rw,relatime)
```

As entradas binfmt foram confirmadas como habilitadas:

```text
arm_dyn: interpreter /system/lib/arm/houdini
arm64_dyn: interpreter /system/lib64/arm64/houdini64
status: enabled
```

### Reboot e persistencia

Foi executado `adb shell reboot`. Como o QEMU de validacao usa `-no-reboot`, o processo QEMU encerrou ao reiniciar o guest; ele foi iniciado novamente sobre o mesmo overlay, sem recriar o disco. Depois do segundo boot, ADB voltou a `device`, `sys.boot_completed=1`, e permaneceram:

- `persist.sys.nativebridge=1`;
- `ro.dalvik.vm.native.bridge=libnb.so`;
- `libhoudini.so` 32-bit com `4957408` bytes e o mesmo SHA-256;
- `libhoudini.so` 64-bit com `6187512` bytes e o mesmo SHA-256;
- mounts SquashFS e entradas `arm_dyn`/`arm64_dyn`.

Isso prova persistencia no overlay descartavel. Nao prova promocao para a base aprovada, que permaneceu com o SHA-256 indicado no inicio desta secao.

### NeoNews no mesmo overlay

O APK ja instalado nao foi reinstalado. `pm path` retornou `/data/app/com.in9midia.neonews.player-1/base.apk`, e `dumpsys package` confirmou:

```text
package: com.in9midia.neonews.player
versionName=9.0.3
versionCode=522
primaryCpuAbi=armeabi-v7a
secondaryCpuAbi=null
```

Cada chamada de `TerminalActivity` retornou exit `0`, e o logcat registrou `Displayed com.in9midia.neonews.player/.TerminalActivity`. O proprio fluxo do aplicativo navegou em seguida para `LoadConfigActivity`, que exibiu o formulario de configuracao. Nenhum usuario, senha, codigo ou configuracao de estacao foi inventado ou inserido.

O logcat tambem registrou, em varios processos do NeoNews:

```text
D houdini: Initialize library(version: 7.1.0a_y.49344 RELEASE)... successfully.
```

Isso prova inicializacao real do Houdini para os processos do pacote, alem da propriedade nominal. Contudo, nao foi possivel observar o carregamento das JNI ARM do conteudo NeoNews porque o fluxo parou legitimamente em `LoadConfigActivity` sem configuracao. Os mapas do processo mostraram `/system/lib/libhoudini.so`, mas nao mostraram `libnativelib.so` ou `libUACAudio.so`.

No teste de 60 segundos, o processo principal permaneceu vivo nas amostras, mas `TerminalActivity` nao permaneceu em primeiro plano: o estado estavel foi `LoadConfigActivity`. O processo `com.in9midia.neonews.player:guardian` produziu ANR em `NeonewsGuardianService` (timeout de execucao do service). Assim, a prova exigida de `TerminalActivity` estavel por 60 segundos e a homologacao completa do NeoNews continuam **NAO APROVADAS**. Tres ciclos posteriores de force-stop/start abriram novamente a activity e inicializaram Houdini, mas nao removem essa pendencia.

Na busca filtrada por `NativeBridge`, `Houdini`, `linker`, `UnsatisfiedLinkError`, `SIGSEGV`, `SIGABRT`, `FATAL EXCEPTION` e crashes, nao houve `UnsatisfiedLinkError`, `SIGSEGV`, `SIGABRT` ou `FATAL EXCEPTION` do NeoNews. Houve o ANR do guardian e falhas de resolucao de `neonews.in9midia.com` porque o guest nao tinha rede funcional nessa sessao.

### Conclusao desta rodada

- Native Bridge oficial: **READY estrutural e inicializado em runtime no overlay**.
- Persistencia do bridge no overlay: **PASS observada apos reboot**.
- `primaryCpuAbi=armeabi-v7a`: **PASS**.
- Inicializacao Houdini em processos NeoNews: **PASS observada**.
- `TerminalActivity` estavel por 60 segundos: **NAO HOMOLOGADO**.
- Execucao de JNI ARM e conteudo real NeoNews: **NAO HOMOLOGADO** sem configuracao de estacao.
- WebView, RHVoice e debloat: **NAO TOCADOS** nesta rodada.

O estado versionado e a configuracao base continuam sem marcar o runtime como homologado. O provisionador oficial novo e `scripts/provision/Provision-NativeBridgeOfficial.ps1`; ele aceita somente os endpoints oficiais fixados, valida hashes e informa `EXTERNAL_ARTIFACT_REQUIRED` com nome, URL, variante, arquitetura, funcao e motivo quando o artefato nao estiver disponivel.
