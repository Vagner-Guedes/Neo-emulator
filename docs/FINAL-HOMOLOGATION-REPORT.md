# Relatório Final de Homologação — NeoNews Runtime V1

**STATUS: BLOCKED**

**Release:** NOT PRODUCTION READY

**Data:** 02/09/2026

**Branch:** `codex/neonews-runtime-homologation`

**Backend obrigatório:** QEMU x86_64 + WHPX, Android-x86 7.1-r5, Android
7.1.2/API 25

**Checkpoint técnico publicado:** `f38b410`

**Push do checkpoint:** concluído em `origin/codex/neonews-runtime-homologation`

**Tag de produção:** não criada

## Conclusão executiva

O NeoNews Runtime V1 não pode ser homologado nesta execução. O bloqueio
determinante é o gate ADB: o endpoint TCP do host é aceito, mas o transporte
permanece `offline`/`Disconnected` e nunca atingiu o estado obrigatório
`device`. Sem uma sessão ADB online não há caminho seguro para validar a
identidade do guest pelo runtime, Native Bridge, NeoNews, RHVoice, WebView,
mídia, persistência funcional ou os ciclos de reinício exigidos.

O diagnóstico completo está em
[`ADB-TCP-HOMOLOGATION-REPORT.md`](ADB-TCP-HOMOLOGATION-REPORT.md). Ele registra
as tentativas controladas, o listener IPv6 do `adbd`, os testes com endereço
IPv4, as variantes de NIC, o rastreamento do `adbd`, o pacote CNXN e o
encerramento QMP sem kill forçado.

Não foram executados debloat, `uninstall`, `pm clear`, exclusão de arquivos,
substituição de APK, alteração de engine TTS ou alteração de dados de voz.
O APK NeoNews, Native Bridge, WebView e RHVoice continuam fora do repositório
e não foram incorporados à publicação.

## Matriz dos gates V1

| Gate | Resultado | Evidência e limite |
| --- | --- | --- |
| Branch e controle de versão | PASS | Branch correta; checkpoint `f38b410` publicado. |
| QEMU/WHPX e layout base | PASS parcial | Build e smoke direto do QEMU/QMP passaram; isso não substitui o guest online. |
| Identidade Android/API 25 | BLOCKED | A identidade foi observada no console de diagnóstico, mas o gate do runtime exige sessão ADB live. |
| Disco qcow2 persistente | BLOCKED | Disco, hash e `qemu-img check` foram observados; marcador após reinício controlado não foi homologado. |
| ADB TCP | BLOCKED | `adb devices -l` nunca exibiu `device`; estado observado `offline`/`Disconnected`. |
| Native Bridge ARM | NOT EXECUTED | Gate depende de ADB online e de componente local legalmente provisionado. |
| NeoNews oficial | NOT EXECUTED | O APK ARM-only não foi instalado nem alterado; `TerminalActivity` não foi iniciada neste backend. |
| RHVoice pt-BR | BLOCKED / PROTECTED | Não houve inventário nem síntese live; nenhuma engine ou arquivo de voz foi modificado. |
| WebView compatível | NOT EXECUTED | Não houve teste live de provider, página HTML/CSS/JavaScript/HTTPS ou NeoNews. |
| Rede, HLS, áudio e offline | NOT EXECUTED | Dependem de guest operacional e conteúdo real. |
| Kiosk, watchdog, startup, tray e hotkey | PASS parcial | Implementação e contratos estáticos preparados; fluxo end-to-end não foi homologado. |
| Estabilidade de 600 segundos | NOT EXECUTED | Não é permitido declarar estabilidade sem ADB, app e conteúdo real. |
| Build e regressão do repositório | PASS | Build Release com 0 erros/0 avisos; 31 scripts, JSONs, contratos e regras de artefatos passaram. |
| Publicação sem binários proprietários | PASS | APK, Native Bridge, WebView, RHVoice, imagem Android e outros componentes externos não foram adicionados ao Git. |

Nenhum resultado `PASS` parcial acima autoriza a conclusão do V1. O status
global permanece `BLOCKED` enquanto qualquer gate essencial não tiver evidência
live correspondente.

## Gate ADB e causa-raiz observada

O contrato configurado é `127.0.0.1:5556` no host encaminhado para
`10.0.2.15:5555` no guest. O backend usa QEMU/WHPX, qcow2 persistente, NIC
`e1000` e Android-x86 7.1-r5.

Durante as tentativas:

- o host conseguiu abrir o endpoint de forwarding;
- o ADB criou o transporte, mas o estado permaneceu `offline`;
- o guest expôs `tcp6 :::5555 LISTEN`, sem resposta funcional equivalente no
  destino IPv4 utilizado pelo forwarding;
- o rastreamento do `adbd` registrou tentativa no socket 5555, mas não
  registrou `server: new connection`;
- um pacote CNXN ADB válido enviado pelo forwarding não recebeu resposta;
- atribuir `10.0.2.15` à interface e configurar rota funcionou apenas dentro do
  guest e não tornou o transporte ADB online;
- `e1000` e `virtio-net-pci`, boot direto do kernel/initrd, `ip=dhcp` e
  variantes de forwarding não produziram `device`;
- QMP negociou capacidades, recebeu `quit` e encerrou sem `forcedKill`, mas
  esse resultado não aprova ADB.

O diagnóstico não aponta para autorização de chave, múltiplos servidores ADB
ou erro de porta do host como correção suficiente. A causa operacional ainda
é a ausência de uma resposta CNXN funcional do `adbd` Android-x86 no caminho
IPv4 encaminhado. O próximo trabalho deve corrigir esse transporte ou
fornecer uma imagem Android-x86 compatível que mantenha o contrato do backend.

## Proteção absoluta do sistema de voz

A proteção RHVoice foi preservada e verificada no código, mas não foi
homologada no guest por causa do bloqueio ADB.

O script
[`Optimize-AndroidGuest.ps1`](../scripts/provision/Optimize-AndroidGuest.ps1)
contém os controles necessários para o futuro fluxo autorizado:

- inventaria packages e procura evidências RHVoice em nomes e dumps de
  packages;
- descobre os packages relacionados à voz e os inclui automaticamente em
  `critical` antes de criar o plano;
- registra packages descobertos, engine padrão e locale no
  `android-package-policy.json`;
- bloqueia Apply sem RHVoice presente, selecionada e com `pt-BR` disponível;
- exige síntese real e saída de áudio não vazia antes e depois de cada grupo;
- verifica a presença dos caminhos dos packages protegidos;
- permite somente `disable-user` para candidatos aprovados e recusa qualquer
  ação sobre packages críticos, required ou de voz;
- executa rollback imediato do grupo em caso de falha;
- não executa uninstall, `pm clear`, remoção de arquivos, remoção de dados de
  voz ou substituição automática da engine.

O arquivo versionado
[`android-package-policy.json`](../config/android-package-policy.json)
continua com `critical: []` porque nenhum inventário real foi concluído nesta
execução. Isso é uma consequência do gate ADB bloqueado; não é autorização
para preencher a lista por inferência nem para executar Apply. A descoberta
automática só deve gravar os nomes observados no guest após uma auditoria ADB
online.

Google TTS não foi desabilitada. Nenhuma engine foi alterada e a voz utilizada
pelo NeoNews não foi substituída.

## Verificações executadas

As verificações locais não destrutivas executadas após o checkpoint foram:

1. `Test-RuntimeRepository.ps1`: passou com 31 scripts, zero erros de parse,
   configuração válida, zero caminhos obrigatórios ausentes, zero erros de
   contrato, APK proprietário ignorado e zero artefatos proprietários
   rastreados.
2. Build Release do launcher WPF: passou com 0 erros e 0 avisos.
3. Diagnóstico QEMU/ADB já registrado: `boot-timeout`, `adb.ready=false`,
   `adb.booted=false`, com desligamento QMP confirmado e `forcedKill=false`.
4. Checklist funcional existente: permanece `not-approved`; evidências
   ausentes ou invalidadas não foram promovidas a aprovação.

Os relatórios em `reports/`, os binários locais, o qcow2, a ISO, o APK, as
vozes e os logs não fazem parte do commit técnico. Os cinco PNGs já staged em
`docs/ui-reference/` foram preservados e ficaram fora do checkpoint.

## Trabalho não iniciado por bloqueio

Para evitar alterar o sistema sem uma rota de recuperação comprovada, estes
gates não foram executados depois que o bloqueio ADB foi confirmado:

- instalação e validação prática da Native Bridge ARM;
- instalação, lançamento e estabilidade do NeoNews oficial;
- identificação de packages RHVoice, engine padrão, locale `pt-BR`, síntese e
  áudio;
- validação do provider WebView e do conteúdo real;
- rede, DNS, HTTPS, HLS/`.m3u8`, MediaPlayer, áudio, cache e modo offline;
- marcador de persistência após reinícios;
- kiosk, watchdog, startup, tray, hotkey, CLI e teste prolongado integrado.

Não é correto marcar esses itens como `PASS` a partir da existência de código,
configuração ou relatórios históricos.

## Critério para retomar

O V1 só pode avançar quando uma execução fresca registrar, no mesmo runtime:

1. `adb devices -l` com o serial configurado no estado `device`;
2. propriedades Android e `sys.boot_completed` confirmadas;
3. três ciclos de reinício controlados com ADB online;
4. Native Bridge ARM em execução prática e instalação do APK com ABI
   comprovada;
5. NeoNews em foreground com conteúdo real e logcat estável;
6. RHVoice preservada, engine padrão confirmada, locale `pt-BR`, síntese real
   e áudio não vazio antes de qualquer debloat;
7. WebView, mídia, offline, persistência, kiosk, watchdog, startup, tray e
   estabilidade de 600 segundos aprovados;
8. revalidação da proteção RHVoice depois de cada grupo, caso debloat seja
   explicitamente autorizado.

Até esses critérios serem satisfeitos, o resultado oficial é **STATUS:
BLOCKED / NOT PRODUCTION READY** e não deve receber tag de produção.

## Histórico técnico do branch

| Commit | Conteúdo | Publicação |
| --- | --- | --- |
| `20b984c` | Registro anterior do probe DHCP/ADB | já existente no branch |
| `f38b410` | Checkpoint do diagnóstico ADB TCP e causa-raiz API 25 | pushed para `origin/codex/neonews-runtime-homologation` |

O commit que adiciona este relatório deve ser publicado antes do handoff; a
verificação final de SHA, branch, push e exclusão dos PNGs staged será feita no
encerramento desta rodada.
