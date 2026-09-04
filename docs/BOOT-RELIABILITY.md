# Boot Reliability — NeoNews Runtime V1

Este documento define o contrato de boot determinístico do runtime WHPX/QEMU.

## Estado do disco

`runtime/android/neonews-runtime-v1.qcow2` é um disco persistente, não um
artefato imutável de cada boot. O estado de provisionamento mantém:

- `baselineSha256`: SHA-256 do baseline aprovado, registrado no provisionamento;
- `activeDiskMetadata`: observação atual produzida por `qemu-img info/check`,
  incluindo formato, tamanho virtual, backing chain, dirty flag, erros e SHA
  atual do arquivo;
- `diskMutationStatus`: `BASELINE_UNCHANGED`,
  `EXPECTED_PERSISTENT_MUTATION` ou `UNEXPECTED_IMAGE_MUTATION`.

Uma alteração do SHA atual com estrutura QCOW2 válida é uma mutação persistente
esperada e não bloqueia o boot. Formato diferente de QCOW2, backing chain
inesperada, dirty flag, corrupção, erros no `qemu-img check` ou mudança de
geometria são falhas estruturais e bloqueiam o boot sem substituir o disco.

## Estados ADB/readiness

Durante o boot o estado persistido permanece `ADB_CONNECTING` ou `BOOTING`.
`ANDROID_READY` só é alcançado após três probes `adb get-state=device`,
separadas por pelo menos dois segundos, seguidas de:

1. `sys.boot_completed=1`;
2. resposta válida de `pm list packages` e `pm path android`;
3. resposta válida de `settings list global` e `settings list secure`;
4. confirmação dos flags de provisionamento inicial.

Um transporte TCP offline pode usar somente a recuperação privada limitada
(`reconnect offline`, `disconnect <serial>`, `connect <serial>`). O servidor
ADB global em `127.0.0.1:5037` não pertence ao runtime e nunca é encerrado.

## Perfil WHPX aprovado

O perfil persistente usa `qemu.cpuCores=1`. A matriz descartavel mostrou boot
completo, `sys.boot_completed=1`, ADB `device`, Houdini carregado e
`primaryCpuAbi=armeabi-v7a` com 1 vCPU; o perfil de 4 vCPUs perdeu o transporte
ADB durante a inicializacao. A configuracao de 1 vCPU e, portanto, parte do
contrato de boot deterministico ate que uma nova homologacao substitua essa
evidencia.

### Homologação cold boot concluída

Em 04/09/2026, após a reconvergência do `NeonewsGuardianService` ser
aguardada antes do lançamento medido, foram executados três cold boots WHPX
independentes em overlays esparsos descartáveis. O relatório
`reports/boot-diagnostics.json` registrou `BOOT_RELIABILITY_PASS` em 3/3
ciclos, com:

- `sys.boot_completed=1` e cinco probes consecutivos em estado `device`;
- ADB root confirmado e relógio alinhado ao Windows, com desvio de 0–1 s;
- `primaryCpuAbi=armeabi-v7a` e `TerminalActivity` estável por 60 s em cada ciclo;
- overlay com `check-errors=0`, raiz sem alteração e encerramento QMP positivo;
- apenas o ADB privado do teste, sem encerrar o ADB global `127.0.0.1:5037`.

O atraso pós-`force-stop` é deliberado: o Guardian usa restart agendado e a
janela de estabilidade só começa depois que essa reconvergência termina.

## Hotkeys operacionais

- `Ctrl+Alt+Shift+F11`: parada segura e gravação de `UserStoppedRuntime`;
- `Ctrl+Alt+Shift+F12`: alternância fullscreen/janela;
- `Ctrl+Alt+Shift+F10`: exibição do painel.

As teclas simples `F11` e `F12` não são registradas globalmente.

## Gate

O runtime só pode avançar para Power BI, endurance, Guardian e publicação
zero-touch depois de `BOOT_RELIABILITY_PASS`, `ADB_STABILITY_PASS`,
`PROVISIONING_PASS`, `IMAGE_INTEGRITY_MODEL_PASS` e
`PACKAGE_ARCHITECTURE_PASS` com evidência correspondente nos relatórios.
