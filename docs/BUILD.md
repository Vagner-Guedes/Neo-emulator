# Build e publicação do NeoNews Runtime

## Pré-requisitos de desenvolvimento

- Windows x64;
- SDK .NET 8 instalado, ou o SDK local usado pelo projeto;
- QEMU x86_64, Android-x86 7.1-r5/API 25, ADB e disco qcow2 provisionados localmente para executar o runtime e seus testes de integração;
- APK NeoNews não é necessário para compilar ou abrir o painel.

## Build rápido

Na raiz do repositório:

```powershell
dotnet build .\launcher\NeoNews.Runtime.Launcher\NeoNews.Runtime.Launcher.csproj --configuration Release
```

O projeto tem `OutputType=WinExe`, portanto o launcher não é uma aplicação de console.

## Publicação distribuível

```powershell
dotnet publish .\launcher\NeoNews.Runtime.Launcher\NeoNews.Runtime.Launcher.csproj `
  --configuration Release `
  --runtime win-x64 `
  --self-contained true `
  -p:PublishSingleFile=true `
  -p:IncludeNativeLibrariesForSelfExtract=true `
  -p:PublishTrimmed=false `
  -p:PublishReadyToRun=false `
  --output .\dist\NeoNewsRuntime
```

Também é possível executar `scripts/build/Publish-NeoNewsRuntime.ps1`. O diretório de distribuição contém `NeoNewsRuntime.exe`, `config/runtime.json`, `runtime/qemu`, `runtime/android`, `runtime/adb`, `runtime/state`, `packages/`, `logs/`, `reports/` e `docs/`; o PDB pode ser mantido para diagnóstico. QEMU, ADB, a imagem Android e o disco persistente não são embutidos no executável e são copiados somente quando já existem localmente.

O script de publicação não copia APKs, Native Bridge, WebView, RHVoice ou outros pacotes externos. O operador deve provisionar esses arquivos separadamente no diretório `packages/` da distribuição, após confirmar origem, licença e hash. Quando o APK autorizado estiver em `packages/neonews/neonews.apk`, o comando `--start` instala-o automaticamente se o pacote ainda não estiver presente no Android.

Ao atualizar uma distribuição existente, a publicação preserva o qcow2 configurado quando o arquivo persistente já existe no destino. A substituição do disco deve ser uma operação explícita de provisionamento, nunca um efeito colateral da atualização do launcher.

O diagnóstico só marca `installSucceeded=true` quando observou `adb install -r`
retornar `Success`; iniciar um APK já instalado pode comprovar estabilidade e
ABI, mas não falsifica a evidência de uma atualização.

Os limites principais ficam em `timeouts` dentro de `config/runtime.json` (`adbSeconds`, `bootSeconds`, `neoNewsStartSeconds`, `installSeconds`, `emulatorStopSeconds`, `qemuShutdownSeconds`, `adbRetrySeconds` e `nativeBridgeStabilitySeconds`) e podem ser ajustados sem recompilar o launcher.

O provisionamento é explícito e offline: `scripts/provision/Provision-QemuAndroidRuntime.ps1` valida QEMU, ADB, a imagem Android e o qcow2 local, registra hashes e origens em `runtime/state/provisioning.json` e não baixa componentes. Informe `-QemuOrigin`, `-AdbOrigin` e, quando aplicável, `-AndroidImageOrigin`; Native Bridge, WebView e RHVoice também precisam ser fornecidos localmente e legalmente redistribuíveis. O boot normal não instala APKs desconhecidos.

O boot normal exige que esse `provisioning.json` já exista; ele não cria um
registro de provisionamento incompleto. O SHA-256 forte registrado no
provisionamento é preservado, e o launcher mantém um fingerprint barato do
qcow2 como último estado observado. Como o qcow2 é mutável por definição, uma
mudança legítima de tamanho/data não bloqueia o boot seguinte; estado sem
SHA-256/proveniência é rejeitado.

Com o guest online, `scripts/provision/Install-GuestComponents.ps1` faz a
instalação opt-in desses componentes com `adb install -r`, sem uninstall ou
limpeza de dados. O script exige o estado base com SHA-256 e provenance antes
de instalar qualquer componente, e preserva esses campos ao atualizá-lo. A
síntese RHVoice continua exigindo um teste real separado.

Para validar o repositório sem o APK, execute `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validation\Test-RuntimeRepository.ps1`. O script verifica o parse dos scripts, o JSON, os caminhos obrigatórios e se o APK proprietário está fora do Git.

Depois de gerar os relatórios live, execute `Test-HomologationChecklist.ps1`.
Ele agrega exatamente 30 gates da especificação e retorna código diferente de
zero enquanto houver evidência pendente ou falha. Relatórios ausentes ficam
pendentes; relatórios inválidos ou com mais de 24 horas ficam em falha e não
são contados como aprovação. O limite pode ser ajustado com
`-EvidenceMaxAgeHours`.

```powershell
.\scripts\validation\Test-LauncherSmoke.ps1 `
  -ExecutablePath .\dist\NeoNewsRuntime\NeoNewsRuntime.exe `
  -PathWithSpaces
.\scripts\validation\Test-HomologationChecklist.ps1
```

Os switches `-NoConsoleObserved`, `-QemuNoConsoleObserved`, `-TrayObserved`,
`-HotkeyObserved`, `-KioskObserved`, `-WatchdogActivityObserved`,
`-WatchdogQemuObserved`, `-WindowsRestartObserved` e
`-UpdatePreservationObserved` só devem ser usados depois da confirmação
correspondente no executável/runtime publicado; eles registram evidência
manual e não simulam essa observação.

O ícone `launcher/NeoNews.Runtime.Launcher/Assets/NeoNewsRuntime.ico` é embutido no `.exe`. Para recriá-lo após uma alteração visual, execute `scripts/build/New-NeoNewsRuntimeIcon.ps1` antes da publicação.

## Execução

```powershell
Push-Location .\dist\NeoNewsRuntime
.\NeoNewsRuntime.exe --show
Pop-Location
```

Argumentos: `--show`, `--start`, `--stop`, `--restart`, `--kiosk`, `--exit-kiosk`, `--diagnostics`, `--autostart` e `--exit`. A segunda execução não abre outra janela; ela envia o comando para a instância principal via named pipe.

O menu do tray oferece abrir painel, iniciar/parar/reiniciar o sistema, kiosk, diagnóstico e encerramento. Fechar a janela apenas a oculta no tray. O startup do Windows, quando ativado na configuração, cria a tarefa `NeoNews Runtime Supervisor` com a ação `NeoNewsRuntime.exe --autostart`; nenhum PowerShell é usado pelo caminho de operação normal.

## Checklist manual de zero-console

1. Publique em `dist/NeoNewsRuntime`.
2. Execute `NeoNewsRuntime.exe --show` por duplo clique e confirme o painel escuro, tray e ausência de janela de terminal.
3. Execute novamente `NeoNewsRuntime.exe --show`; confirme que só há uma instância.
4. Execute `NeoNewsRuntime.exe --diagnostics`; confira `reports/` e `logs/`.
5. Execute `NeoNewsRuntime.exe --exit`; confirme que o processo encerrou.
6. Copie a pasta para `C:\NeoNews Runtime Test\NeoNewsRuntime\` e repita os passos 2–5. Caminhos com espaços devem funcionar.
7. Se todos os componentes estiverem provisionados, use `--start`, `--install`, `--kiosk` e `--stop`; sem QEMU/disco/ADB ou sem o APK, o painel deve mostrar um erro gráfico explicando a dependência ausente.

O registro da tarefa do Agendador depende da permissão do Windows. O launcher tenta primeiro sem elevação e solicita UAC somente para `schtasks.exe` quando recebe `Acesso negado`; confirme que a ação contém somente `NeoNewsRuntime.exe --autostart`.

Os logs são gravados ao lado da distribuição em `logs/`; diagnósticos ficam em `reports/`. Não versionar APK, SDK Android, `bin/`, `obj/`, `dist/`, logs ou relatórios gerados.
