# Plano de limpeza de storage — NeoNews Runtime V1

**Data do inventário:** 2026-09-04
**Status:** `NOT EXECUTED — espaço insuficiente e artefatos preservados`

## Inventário observado

| Caminho | Tamanho aproximado | Tratamento |
|---|---:|---|
| `tmp/NeoNewsRuntime-FinalPublish-Portable` | 15.206.514.410 bytes | Preservar até fechar a auditoria; contém a base de prova aprovada. |
| `tmp/NeoNewsRuntime-FinalPublish-ApprovedOverlay` | 2.874.600.648 bytes | Preservar como evidência da execução integrada. |
| `dist/NeoNewsRuntime-current` | 3.090.648.691 bytes | Preservar como publicação local atual. |
| `dist/NeoNewsRuntime` | 235.346.330 bytes | Preservar até confirmar qual publicação será promovida. |
| espaço livre em C: | 533.557.248 bytes | Insuficiente para nova cópia integral da distribuição. |

Os tamanhos incluem imagens/arquivos gerados localmente. O qcow2 aprovado da
raiz, os arquivos do usuário em `tmp/`, `.tmp-network/`,
`docs/STORAGE-MIGRATION-E.md` e `docs/ui-reference/` não foram apagados nem
movidos.

## O que não pode ser removido

- `runtime/android/neonews-runtime-v1.qcow2` aprovado;
- qualquer cópia usada como base de rollback;
- pacotes e dados RHVoice;
- WebView 119 validado;
- Houdini/Native Bridge validado;
- APK NeoNews e seus dados quando estiverem dentro da publicação aprovada;
- `.gclient`, `.tmp-network/`, `tmp/` e demais arquivos não rastreados do
  usuário;
- qualquer arquivo que ainda seja evidência referenciada por um relatório.

## Ação segura pendente

Depois de liberar espaço no host e revisar as evidências, a limpeza deve ser
feita por caminhos explícitos e individualmente, mantendo ao menos uma cópia
íntegra do runtime aprovado. Antes de cada remoção, registrar caminho,
tamanho, hash quando aplicável e motivo; depois repetir:

1. `Test-RuntimeRepository.ps1`;
2. `Test-TextEncoding.ps1`;
3. `Test-HostIsolation.ps1`;
4. validação da publicação e do qcow2;
5. smoke e endurance integrados.

Nenhuma limpeza foi executada nesta etapa. O smoke de caminho com espaços
falhou por falta de espaço durante a cópia da ISO Android, não por uma ação de
remoção.
