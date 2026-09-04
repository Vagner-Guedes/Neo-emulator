# Arquitetura de empacotamento — NeoNews Runtime V1

**Auditoria:** 04/09/2026  
**Relatório:** `reports/package-architecture.json`  
**Regra:** evidence-only; nenhum download silencioso.

## Modelo

O runtime aprovado é dividido em três grupos:

1. **Baked-in image:** componentes já presentes no qcow2 aprovado e usados no
   boot normal. A imagem é a autoridade operacional; o boot usa apenas um
   overlay esparso descartável.
2. **Required for repair:** artefatos locais necessários somente para reparar
   ou reprovisionar uma cópia. Cada arquivo precisa de nome, tamanho, SHA-256 e
   origem registrada antes de ser usado.
3. **Required for first run:** itens que faltariam em uma imagem não
   provisionada. Para o qcow2 aprovado atual, a lista é vazia. Se surgir um
   item, o processo deve parar e solicitar um artefato local ou oficial
   verificável; não há busca automática em mirrors.

## Componentes confirmados na imagem

O cold-boot 3/3 confirmou, em todos os ciclos, NeoNews, WebView
`119.0.6045.193`, RHVoice e o Native Bridge com `ro.dalvik.vm.native.bridge`
igual a `libnb.so`. O NeoNews iniciou com `primaryCpuAbi=armeabi-v7a` e ficou
estável por 60 s.

RHVoice, WebView, Houdini e os dados do NeoNews não foram alterados nesta
etapa. Não foram executados `uninstall`, `pm clear`, reset ou wipe.

## Artefatos de reparo

O relatório registra todos os arquivos encontrados em `packages/`, inclusive
cópias de staging, com tamanho e SHA-256. Os SFS Houdini estão fixados pelas
URLs oficiais esperadas pelo Android-x86:

- `houdini7_y.sfs` — variante ARM32 `7_y`;
- `houdini7_z.sfs` — variante ARM64 `7_z`.

Os APKs do NeoNews, WebView e RHVoice e os pacotes de idioma/voz estão
presentes, mas a origem histórica de alguns arquivos ainda não está registrada
no manifesto. O estado é, portanto,
`PACKAGE_ARCHITECTURE_EVIDENCE_ONLY_ORIGIN_GAP`, não uma aprovação de
publicação.

## Regra de publicação

Não incluir APKs, SFS, ZIPs ou outros artefatos proprietários no Git. Uma
publicação nova deve carregar o manifesto de provisioning, os hashes e as
origens; se algum arquivo estiver ausente ou tiver identidade divergente, deve
parar antes de modificar o guest.
