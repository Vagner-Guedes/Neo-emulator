# Relatório específico — homologação ADB TCP

**Data da execução:** 02/09/2026
**Backend:** `IAndroidRuntimeBackend` / `QemuAndroidRuntimeBackend`
**Guest:** Android-x86 7.1-r5, Android 7.1.2, API 25
**Resultado:** **BLOQUEADO**

## Escopo e critério

Foi investigado somente o transporte ADB TCP entre Windows e Android-x86 no
backend QEMU/WHPX. Não foram executados debloat, NeoNews, WebView, HLS/cache,
Native Bridge, RHVoice ou qualquer alteração de pacote, voz ou APK.

O critério de aprovação era uma sessão live em que `adb devices -l` exibisse o
serial configurado como `device`. O estado `offline` nunca foi promovido para
`device`.

## Identidade observada

| Item | Valor |
| --- | --- |
| QEMU | 11.1.0 (`v11.1.0-12130-ge470268ff4`) |
| SHA-256 QEMU | `47D57A6072E0BB3BD98F87926EB129EB1736DFE818C67B3B81EF7CE4EDD0B3CD` |
| ADB | 1.0.41 / 37.0.1-15733141 |
| SHA-256 ADB | `B4A6B455702684652CCCF7B46258B29E653538904359A58FD4931CF3EF286B3F` |
| ISO | `android-x86-7.1-r5.iso` |
| SHA-256 ISO | `43EF7D7A44C2765BD35E2ED9C441FCEDA43741F152BB6384BCEC16EDCE0EAA25` |
| Rede QEMU | `10.0.2.0/24`, DHCP anunciado em `10.0.2.15` |
| Forwarding | `127.0.0.1:5556 -> 10.0.2.15:5555` |
| NIC | `e1000` |
| QMP | `127.0.0.1:4445` |

O comando efetivo do backend está em
[`QemuAndroidRuntimeBackend.cs`](../launcher/NeoNews.Runtime.Launcher/Services/QemuAndroidRuntimeBackend.cs:111)
e contém `-netdev user`, `dhcpstart`, `hostfwd`, `-device e1000` e QMP. A
política ADB permanece estrita em
[`AdbService.cs`](../launcher/NeoNews.Runtime.Launcher/Services/AdbService.cs:132):
somente o texto `device` é aceito como online.

## Evidência live

### Boot normal com a linha de produção

No guest:

```text
ro.build.version.release = 7.1.2
ro.build.version.sdk = 25
ro.product.cpu.abilist = x86_64,x86,armeabi-v7a,armeabi,arm64-v8a
persist.adb.tcp.port = 5555
service.adb.tcp.port = vazio
ro.adb.secure = vazio
sys.usb.config = adb
```

O guest criou `wifi_eth` com link `UP/LOWER_UP`, mas sem IPv4 e sem rota:

```text
wifi_eth: fe80::5054:ff:fe12:3456/64
ip route: vazio
tcp6 :::5555 LISTEN
```

No host, há somente o ADB local do repositório. Após reiniciar o servidor ADB:

```text
adb connect 127.0.0.1:5556  -> falha/offline
adb devices -l               -> 127.0.0.1:5556 offline
adb -s 127.0.0.1:5556 get-state -> device offline
```

Um probe TCP independente conseguiu abrir `127.0.0.1:5556`, mas o envio de um
CNXN ADB não recebeu bytes de resposta em três segundos. Isso prova somente que
o frontend TCP do `hostfwd` aceitou a conexão; não prova que o QEMU conseguiu
entregar a conexão ao socket do guest nem que o protocolo ADB esteja funcionando.

### Controles de rede

Foi aplicada somente em memória, numa sessão de diagnóstico, a configuração:

```text
ifconfig wifi_eth 10.0.2.15 netmask 255.255.255.0 up
ip route add default via 10.0.2.2 dev wifi_eth
ping -c 1 10.0.2.2 -> 1 transmitido, 1 recebido, 0% perda
```

Isso prova que a NIC, a rede user-mode do QEMU e o gateway funcionam quando o
guest recebe IPv4. Mesmo assim, o `adbd` continuou em `tcp6 :::5555`, o probe
CNXN continuou sem resposta e o estado ADB continuou `offline`.

Também foram testados boots diretos com os initrd/kernel oficiais:

```text
ip=10.0.2.15::10.0.2.2:255.255.255.0::wifi_eth:none
net.ifnames=0 ip=10.0.2.15::10.0.2.2:255.255.255.0::eth0:none
```

Nos dois casos o resultado live voltou a ser `wifi_eth` sem IPv4/rota. A
interface é criada/renomeada depois da fase em que o `ip=` do kernel é tratado;
alterar apenas o nome esperado (`eth0`) não corrige o problema.

## Causa raiz

### Causa primária — inicialização de rede do guest

O `/system/etc/init.sh` da imagem foi lido no console root. O trecho relevante
(linhas 42–58) procura `wlan0`, pode criar/remover `virt_wifi`, renomeia a
interface para `wifi_eth` e executa `ifconfig wifi_eth up`. Ele não atribui
IPv4, não adiciona rota e não inicia cliente DHCP.

Os controles adicionais confirmaram:

```text
/system/bin/dhcpcd -> inexistente
/system/bin/dhcpd  -> inexistente
netcfg             -> inexistente
dhcp.wifi_eth.*    -> vazio
```

O servidor DHCP do QEMU só responde a um cliente DHCP no guest; anunciar
`dhcpstart=10.0.2.15` não configura sozinho a interface Android.

### Causa secundária — serviço/socket do adbd

O `/init.usb.rc` define:

```text
service adbd /sbin/adbd --root_seclabel=u:r:su:s0
    disabled
    socket adbd stream 660 system system
```

O serviço é ativado por triggers USB e o listener observado foi exclusivamente
`tcp6 :::5555`; `/proc/net/tcp` permaneceu vazio. Depois que a conectividade
IPv4 foi criada manualmente, ainda não houve handshake CNXN. O trace interno do
`adbd`, habilitado somente em sessão `-snapshot`, registrou após o `adb connect`:

```text
transport: server_socket_thread() starting
server: trying to get new connection from 5555
```

Não apareceu o evento seguinte `server: new connection`. Assim, a conexão que
o host consegue abrir é o frontend TCP do QEMU; ela não chega ao listener IPv6
do guest através do destino IPv4 `10.0.2.15:5555`. Isso é um bloqueio de família
de socket/encaminhamento, não um problema de autenticação RSA: o `adbd` não
recebe o CNXN para iniciar o desafio.

O controle foi repetido com um bootstrap QMP que configurou IPv4, rota,
`service.adb.tcp.port=5555` e reiniciou o serviço. O resultado permaneceu
`offline`, tanto com `hostfwd` para `10.0.2.15` quanto com o destino implícito
do QEMU. O próprio binário também rejeitou a tentativa de forçar o modo
abrangente:

```text
/sbin/adbd -a -> invalid option -- a
```

Num boot direto com `ipv6.disable=1`, o `/proc/net/tcp6` deixou de existir e o
`adbd` não abriu listener IPv4 após `start adbd`; portanto essa imagem não
oferece fallback IPv4 por argumento de boot simples.

### Prova no nível do protocolo

Com `wifi_eth=10.0.2.15/24`, rota via `10.0.2.2` e `adbd` ouvindo em
`:::5555`, um cliente bruto enviou um pacote ADB `CNXN` para o forwarding
`127.0.0.1:5572` com payload `host::\0`, comprimento 7 e checksum 562. O
frontend TCP conectou, mas a leitura permaneceu em zero bytes durante cinco
segundos. O trace do guest não registrou `server: new connection`. O mesmo
resultado ocorreu quando o `adbd` foi parado pelo `init` e iniciado diretamente
como `/sbin/adbd`, sem `--root_seclabel`.

O trace do `adb` 37.0.1 confirmou a sequência: `host:connect` recebeu `OKAY`
do servidor local, abriu o transporte e esperou a resposta de quatro bytes do
guest por dez segundos; terminou com `failed to connect` e o inventário ficou
`127.0.0.1:5572 offline`. Portanto, a porta host aberta e o transporte ADB
registrado não equivalem a uma entrega bem-sucedida ao socket do guest.

No boot normal, `ro.kernel.qemu` ficou vazio. Isso é compatível com o caminho
TCP `server_socket_thread` do ADB Android 7.1; o caminho QEMUD só é selecionado
quando essa propriedade é `1`. O código de referência está no
[AOSP system/core da série Android 7.1.2](https://android.googlesource.com/platform/system/core/%2B/e323976e747c28b78b5e1be565317f500e0f5c06/adb/transport_local.cpp).

## Hipóteses eliminadas

| Hipótese | Evidência contra |
| --- | --- |
| `hostfwd` aponta para o destino errado | Forwarding TCP abre; probes com destino explícito e controles repetidos não obtêm CNXN. |
| NIC/QEMU sem link | `wifi_eth` fica `UP/LOWER_UP`; ping ao gateway funciona após IPv4 manual. |
| DHCP do QEMU indisponível | O bloqueio é a ausência de cliente/configuração IPv4 no guest, não a oferta do servidor. |
| ADB errado ou múltiplo no host | Caminho único conhecido, uma instância do servidor e hash/versionamento registrados. |
| RSA como causa primária | Sem resposta CNXN; teste anterior também usou chave host correspondente e permaneceu offline. |
| Apenas `eth0`/`net.ifnames` | Ambos os boots estáticos foram ignorados e produziram `wifi_eth` sem endereço. |
| Firewall IPv4 do guest | `iptables -L INPUT -n -v` mostrou `policy ACCEPT` e regras `ACCEPT` para todo o tráfego. |
| Bootstrap QMP como correção | IPv4/rota e `adbd running` foram obtidos manualmente, mas o estado host continuou `offline`. |
| `adbd -a` como correção | O binário respondeu `invalid option -- a`. |
| Desabilitar IPv6 para obter IPv4 | O boot `ipv6.disable=1` ficou sem listener após iniciar o `adbd`. |
| Relay BusyBox IPv4→IPv6 | Com `adbd` movido para `:::5556`, `busybox nc -l -p 5555 -e busybox nc ...` não produziu CNXN; o teste direto `busybox nc -w 3 ::1 5556` retornou apenas o usage do BusyBox, indicando que essa implementação não fornece o relay IPv6 necessário. O host permaneceu `offline`. |
| Modelo da NIC `e1000` | Um boot isolado com `virtio-net-pci` (modelo usado pelo launcher upstream consultado) reproduziu `wifi_eth` sem IPv4; após IPv4/rota manual, `adb devices -l` continuou `offline`. |
| Forwarding IPv6 do QEMU | O QEMU 11.1.0 rejeitou os formatos `hostfwd=tcp:[::1]:...-[::]:5555` e `...-[fe80::...]:5555` com `Bad host address`; não há endpoint IPv6 utilizável por esse caminho. |
| Argumento `--root_seclabel` do serviço | O `adbd` iniciado diretamente como `/sbin/adbd` também abriu `:::5555` e não respondeu ao CNXN bruto. |
| Incompatibilidade do protocolo ADB do host | O CNXN bruto mínimo e o trace do ADB 37.0.1 chegaram ao transporte, que não devolveu qualquer resposta; não há evidência de falha RSA antes da resposta CNXN. |
| Entrega host→socket guest | O trace do `adbd` registrou a criação do servidor e `trying to get new connection`, mas nenhum `new connection`; o socket guest continua IPv6 enquanto o destino `hostfwd` é IPv4. |

## Correção e antes/depois

Nenhuma correção intencional foi aplicada ao código, ao `runtime.json`, à ISO,
ao APK, às vozes ou aos arquivos do guest. Os probes posteriores usaram
`-snapshot`; a divergência observada no qcow2 após uma sessão live anterior está
registrada na seção de integridade abaixo. Adicionar apenas `ip=` ao comando
QEMU não é uma correção válida, pois os probes demonstraram que a interface
ainda não existe quando essa configuração é processada.

O backend não possui hoje um canal guest independente e confiável para executar
`ifconfig`/rota e reiniciar `adbd` após a criação de `wifi_eth`. Um workaround
por teclado/QMP ou um relay host-side mascararia o problema e não seria uma
homologação ADB TCP reproduzível. Por isso, não foi incorporado.

Como controle adicional, foi tentado um relay dentro do guest: o `adbd` foi
reiniciado em `:::5556` e o BusyBox `nc` foi colocado para escutar `5555` e
encaminhar para `::1:5556`. Uma conexão limpa do host ao forwarding QEMU
`127.0.0.1:5567` continuou em `offline`; o teste direto do `nc` IPv6 devolveu
somente a tela de uso. Isso não transforma o listener IPv6 do `adbd` em um
endpoint IPv4 homologável.

Também foi executado um probe isolado com `virtio-net-pci` no lugar da NIC
`e1000`, mantendo Android, qcow2, NAT e o restante do boot. O resultado de
`ip addr` foi o mesmo (`wifi_eth` apenas com IPv6); mesmo atribuindo
`10.0.2.15/24` e a rota `10.0.2.2`, o ADB host continuou `offline`. Por fim,
os formatos de `hostfwd` IPv6 foram testados no próprio QEMU sem disco: todos
foram rejeitados pelo parser com `Bad host address`/`Bad guest address`.

O probe de protocolo também foi encerrado sem alteração persistente: o CNXN
bruto recebeu zero bytes de resposta tanto no serviço iniciado pelo `init`
quanto no `/sbin/adbd` direto. O trace do guest não registrou aceitação de uma
conexão no `server_socket_thread`; o trace do cliente registrou dez segundos de
espera pelo header de resposta antes de declarar a conexão falha.

## Ciclos e limpeza

Os probes foram encerrados por QMP `quit`; a verificação final encontrou:

```text
QEMU count = 0
ADB client/server count = 0
TCP 5037 listeners = 0
```

Os três ciclos de restart exigidos para um ADB homologado não foram executados:
o pré-requisito `adb devices -l = device` falhou antes dessa fase. Executá-los
como se fossem ciclos de estabilidade passaria por cima do gate definido.

## Integridade do qcow2

As sessões posteriores usaram `-snapshot`. Uma sessão live anterior, porém,
foi iniciada sem `-snapshot` antes desta constatação. O hash registrado antes
daquela sessão era `6A455FC0D8473F9EDC02294BB3EBD7D95F5E1F1569C7A9100EB68B6CBFA8C3C7`;
o arquivo atual está em `E4F54E76CDB05C88C5E2506595DCBA42DBDD37CB140AAC0D864558F8ED40C5A6`.

Existem cópias de publicação idênticas entre si, mas com outro hash
(`F2D73A4A5C36A288A416811D48B1373A0CDD3CA1AAEB0614A8837706C14C8264`), portanto
elas não foram usadas como restauração automática. A restauração correta exige
a cópia canônica que corresponda ao hash anterior `6A455F…`; não é seguro
substituir o qcow2 por uma imagem diferente.

## Native Bridge

**Estado: BLOQUEADO.** Foi apenas observado `ro.dalvik.vm.native.bridge=libnb.so`
durante a coleta obrigatória de propriedades. A homologação/provisionamento do
Native Bridge não foi iniciada porque o gate ADB `device` não passou.

## Ação recomendada para desbloqueio

Disponibilizar uma imagem/canal de guest com inicialização de rede IPv4 após a
criação de `wifi_eth` e com `adbd` TCP comprovadamente respondendo em IPv4, ou
autorizar uma alteração explícita e auditável no artefato de inicialização do
guest. Depois disso, repetir a sequência ADB live, obter `device`, executar os
três ciclos QMP/QEMU e só então avançar para Native Bridge e demais regressões.
