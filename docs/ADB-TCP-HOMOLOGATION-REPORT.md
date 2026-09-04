# Relatório específico — homologação ADB TCP

**Execução:** 02–03/09/2026
**Backend:** `QemuAndroidRuntimeBackend` / QEMU + WHPX
**Guest:** Android-x86 7.1-r5, Android 7.1.2, API 25
**Resultado do gate ADB TCP:** **PASS**

## Escopo e gates

Esta meta tratou exclusivamente do transporte ADB TCP entre Windows e
Android-x86. Não foram executados debloat, Native Bridge, NeoNews, WebView,
kiosk, mídia ou qualquer alteração de pacote, APK, voz ou engine TTS.

| Gate | Estado nesta meta |
| --- | --- |
| ADB TCP | **PASS** |
| Native Bridge | BLOQUEADO — próxima etapa |
| NeoNews | BLOQUEADO — próxima etapa |
| WebView | BLOQUEADO — próxima etapa |
| RHVoice/TTS | BLOQUEADO — protegido e fora do escopo |

O critério foi observado ao vivo em três ciclos: `adb devices -l` exibindo
`device` e `adb -s 127.0.0.1:5556 shell getprop sys.boot_completed` retornando
`1`. O estado `offline` nunca foi promovido automaticamente.

## Componentes e artefatos

| Item | Valor |
| --- | --- |
| QEMU | 11.1.0 (`v11.1.0-12130-ge470268ff4`) |
| SHA-256 QEMU | `47D57A6072E0BB3BD98F87926EB129EB1736DFE818C67B3B81EF7CE4EDD0B3CD` |
| ADB | 1.0.41 / 37.0.1-15733141 |
| SHA-256 ADB | `B4A6B455702684652CCCF7B46258B29E653538904359A58FD4931CF3EF286B3F` |
| ISO oficial | `runtime/android/android-x86-7.1-r5.iso` |
| SHA-256 ISO | `43EF7D7A44C2765BD35E2ED9C441FCEDA43741F152BB6384BCEC16EDCE0EAA25` |
| qcow2 vazio inicial | `runtime/android/adb-tcp-clean-api25.qcow2` |
| SHA-256 qcow2 vazio | `E80C945307D0738D449E58062253EEECF7A0F9C3F1A49ED6BACEDE39463014D2` |
| qcow2 baseline limpo pós-instalação | SHA-256 `9904FDC74E79FDDA8FC08B5E5797729DD21F0FCA61CF59A68613BEFC5AF0DB95` |
| qcow2 provisionado usado no PASS | `runtime/android/adb-tcp-provisioned-api25.qcow2` |
| SHA-256 qcow2 provisionado registrado | `E9B71CDB61B0523BD86CA451EAEB279A8EBE3B496EAF7AF4E66005B087E78303` |
| QEMU user-mode | `10.0.2.0/24`, guest esperado `10.0.2.15` |
| Host forwarding | `127.0.0.1:5556 -> 10.0.2.15:5555` |
| NIC | `e1000` |
| QMP do backend | `127.0.0.1:4445` |

O qcow2 vazio, o baseline limpo e a ISO original foram preservados. O
`qemu-img check` do artefato provisionado terminou com `No errors were found
on the image`; o estado de corrupção/dirty flag também permaneceu falso.

## Diagnóstico experimental

No baseline original, o guest apresentava:

```text
cat /proc/sys/net/ipv6/bindv6only -> 0
/proc/net/tcp                    -> sem listener IPv4
/proc/net/tcp6                   -> :::5555 LISTEN
wifi_eth                         -> sem IPv4 automático
ip route                         -> sem rota padrão
adb devices -l                   -> 127.0.0.1:5556 offline
```

Com configuração temporária de `wifi_eth=10.0.2.15/24` e rota via
`10.0.2.2`, o ping ao gateway passou. O teste independente obrigatório também
passou: um listener IPv4 puro no guest recebeu exatamente
`NEONEWS-ADB-PROBE` enviado do Windows pelo `hostfwd`. Isso comprova a entrega
IPv4 do QEMU e elimina hostfwd/NAT como causa do bloqueio.

O adbd da imagem continua criando seu listener TCP em AF_INET6. O caminho
mínimo por `bindv6only` não era necessário (`0`) e `adbd -a` foi rejeitado pelo
binário (`invalid option -- a`). Desabilitar IPv6 também não produziu fallback
IPv4. O bloqueio restante era o listener IPv6 do adbd combinado com o destino
IPv4 do hostfwd.

Não foi definido `ro.kernel.qemu=1` e não foi utilizado QEMUD.

## Correção persistente

Foi criada uma variante controlada, separada da ISO e do baseline:

1. Em `/system/etc/init.sh`, depois da criação de `wifi_eth`, foram mantidas
   as linhas de rede:

   ```text
   ifconfig wifi_eth 10.0.2.15 netmask 255.255.255.0 up
   ip route replace default via 10.0.2.2 dev wifi_eth
   setprop net.dns1 10.0.2.3
   ```

2. A linha 61 do artefato provisionado inicia
   `/system/bin/neonews-adb-relay-start.sh` após a configuração de DNS.

3. O startup controlado define `service.adb.tcp.port` e
   `persist.adb.tcp.port` como `5556`, reinicia o adbd e inicia o relay local.
   O adbd escuta `:::5556`; o relay escuta IPv4 `0.0.0.0:5555` e encaminha
   bytes bidirecionalmente para `::1:5556`, sem alterar o payload ADB.

4. O relay é código próprio versionado em
   [`scripts/adb/AdbIpv4Relay.java`](../scripts/adb/AdbIpv4Relay.java) e usa
   somente classes padrão disponíveis no Android-x86. O DEX foi reproduzido
   por [`Build-AdbIpv4Relay.ps1`](../scripts/adb/Build-AdbIpv4Relay.ps1), tem
   3.248 bytes, SHA-256
   `D682DBE7E4F9A0C81DFBBD86948CF0C4780D92C79E0F9E392A9BF9D96ABF4D32` e
   MD5 `AFF81994F571E6F85EF42754FC3DA5C5`.

5. O guest persistente contém `/system/bin/adb-relay.dex` e
   `/system/bin/neonews-adb-relay-start.sh`. A configuração versionada aponta
   `config/runtime.json` para `runtime/android/adb-tcp-provisioned-api25.qcow2`;
   o backend continua usando QEMU/WHPX, `e1000`, user-mode networking e
   forwarding IPv4.

O BusyBox `nc` não foi usado como relay porque a implementação da imagem não
suporta o destino IPv6 necessário. O relay local é iniciado automaticamente,
sem console, e sobrevive ao reboot do guest.

## Evidência live — três ciclos consecutivos

Cada ciclo foi iniciado do host com o qcow2 provisionado sem `-snapshot`,
aguardou `device`, confirmou `boot_completed=1` e foi encerrado com `quit` via
QMP. Não houve `forcedKill`.

| Ciclo | QEMU → `device` | `device` → `boot_completed` | ADB | IPv4/rota | DNS | bindv6only | relay | forcedKill |
| ---: | ---: | ---: | --- | --- | --- | ---: | --- | --- |
| 1 | 31,26 s | 1,79 s | `device` | OK | `10.0.2.3` | `0` | OK | `false` |
| 2 | 32,22 s | 1,21 s | `device` | OK | `10.0.2.3` | `0` | OK | `false` |
| 3 | 31,14 s | 3,58 s | `device` | OK | `10.0.2.3` | `0` | OK | `false` |

Saída observada no host:

```text
List of devices attached
127.0.0.1:5568  device product:android_x86_64 model:Standard_PC__i440FX___PIIX__1996_ device:x86_64

adb -s 127.0.0.1:5568 get-state
device

adb -s 127.0.0.1:5568 shell getprop sys.boot_completed
1
```

Após o último ciclo, QEMU foi encerrado via QMP e não ficou processo QEMU
órfão. O servidor ADB pode ser encerrado pelo operador quando a sessão de
diagnóstico terminar.

## Integração ao backend

O `QemuAndroidRuntimeBackend` já constrói o forwarding configurado e mantém
`-no-reboot`, QMP e a política estrita de `AdbService`: somente `device` é
estado online. A integração desta meta consistiu em apontar o disco aprovado
no `config/runtime.json` para a variante provisionada; não houve fallback para
`offline` nem mascaramento por estado estático.

O código-fonte do launcher não foi recompilado nesta máquina porque há apenas
o runtime .NET 8 instalado, sem .NET SDK. A prova live foi feita diretamente
com o mesmo comando QEMU, o mesmo artefato configurado e o mesmo `adb.exe` que
o backend usa; a recompilação deve ser feita no ambiente de build antes da
publicação do executável.

## Evidencia adicional - recovery controlado - 2026-09-04

Foi executado um teste independente na copia descartavel com WebView 119,
usando somente o ADB privado `127.0.0.1:5038` e o guest `127.0.0.1:5556`.

| Verificacao | Resultado |
| --- | --- |
| Guest boot antes da queda | PASS |
| `adb disconnect 127.0.0.1:5556` | PASS |
| Estado apos a queda | sem dispositivo (`not found`) |
| `adb connect 127.0.0.1:5556` | PASS |
| Estado apos reconnect | `device` |
| Continuidade de rede | PASS - ping externo recebido |
| Encerramento QEMU | PASS - QMP confirmado, sem forced kill |

Evidencia completa: `reports/adb-recovery-final.json`.

## Rollback e limites

O rollback é selecionar novamente o qcow2 original no `runtime.json` ou
regenerar um artefato a partir do baseline limpo e da ISO oficial. Nenhum
arquivo de voz, pacote TTS/RHVoice, APK ou política de debloat foi tocado.

Este PASS altera somente o gate **ADB TCP**. Native Bridge, NeoNews, WebView,
RHVoice/TTS, kiosk e mídia permanecem sem homologação e não devem ser marcados
como aprovados por este relatório.
