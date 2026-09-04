# Correcao do Android Setup Wizard

## Causa identificada

Em um snapshot descartavel do qcow2 aprovado, com ADB privado e boot completo,
os flags estavam incompletos:

- `global.device_provisioned=0`
- `secure.user_setup_complete=0`

O package/processo identificado pelo logcat foi
`com.google.android.setupwizard`. A atividade que causou o crash foi
`com.google.android.setupwizard.account.CheckFrp`, com
`NullPointerException: println needs a message` em
`CheckFrpFragment.java:63`. A janela observada foi
`Application Error: com.google.android.setupwizard`.

## Correcao persistente

O launcher agora grava e confirma, de forma idempotente, por meio do mecanismo
`settings` suportado pelo Android:

- `settings put global device_provisioned 1`
- `settings put secure user_setup_complete 1`

O fluxo tenta aplicar os flags assim que o transporte ADB fica `device`, antes
de `sys.boot_completed=1`, e repete a verificacao depois de Package Manager e
Settings Provider. O script `Install-GuestComponents.ps1` tambem grava e
confirma os mesmos flags no guest durante o provisionamento.

Nenhum package e desabilitado, removido, desinstalado ou limpo. RHVoice,
WebView, Native Bridge, NeoNews, PackageInstaller e DownloadManager nao sao
alterados por esta correcao.

## Evidencia do snapshot

O teste antecipado confirmou os dois flags como `1` antes do boot completo.
Depois disso, `TerminalActivity` permaneceu observada por 40 segundos sem
janela `Application Error`, sem crash novo no logcat e sem linhas novas de
Setup Wizard. A amostra final de 20 segundos nao foi contada: o QEMU foi
encerrado externamente para liberar um processo ADB preso. Portanto, o gate
de estabilidade de 60 segundos continua pendente de uma rodada integral.

Os gates foram adicionados ao checklist:

- `ANDROID_SETUP_COMPLETE_PASS`
- `SETUP_WIZARD_SUPPRESSED_PASS`
- `NO_ANDROID_CRASH_DIALOG_PASS`

## Estado

O codigo compila em Release e os validadores de encoding, parser e contratos
do repositorio passam. O validador de repositorio ainda retorna o erro
preexistente `runtimeProcessIsolationContracts`; isso nao foi alterado nesta
correcao. A distribuicao publicada precisa ser recompilada e submetida a uma
rodada live limpa antes de qualquer classificacao `PRODUCTION READY`.
