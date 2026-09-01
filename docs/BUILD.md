# Build e publicação do NeoNews Runtime

## Pré-requisitos de desenvolvimento

- Windows x64;
- SDK .NET 8 instalado, ou o SDK local usado pelo projeto;
- SDK Android/ADB e Emulator apenas para executar o runtime e seus testes de integração;
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

Também é possível executar `scripts/build/Publish-NeoNewsRuntime.ps1`. O diretório de distribuição contém `NeoNewsRuntime.exe`, `config/runtime.json`, `runtime/`, `packages/`, `logs/`, `reports/` e `docs/`; o PDB pode ser mantido para diagnóstico. O SDK Android não é embutido no executável: em produção, configure `android.tooling.sdkRoot` para um SDK distribuído junto ou permita o fallback para `ANDROID_SDK_ROOT`, `ANDROID_HOME` ou `%LOCALAPPDATA%\Android\Sdk`.

Quando `app.apk` existir na raiz do repositório (ou `packages/neonews/neonews.apk` já existir), o script de publicação o inclui na distribuição. O comando `--start` também instala automaticamente esse APK autorizado quando o pacote ainda não estiver presente no Android.

Os limites principais ficam em `timeouts` dentro de `config/runtime.json` (`adbSeconds`, `bootSeconds`, `neoNewsStartSeconds`, `installSeconds` e `emulatorStopSeconds`) e podem ser ajustados sem recompilar o launcher.

Para validar o repositório sem o APK, execute `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validation\Test-RuntimeRepository.ps1`. O script verifica o parse dos scripts, o JSON, os caminhos obrigatórios e se o APK proprietário está fora do Git.

O ícone `launcher/NeoNews.Runtime.Launcher/Assets/NeoNewsRuntime.ico` é embutido no `.exe`. Para recriá-lo após uma alteração visual, execute `scripts/build/New-NeoNewsRuntimeIcon.ps1` antes da publicação.

## Execução

```powershell
Push-Location .\dist\NeoNewsRuntime
.\NeoNewsRuntime.exe --show
Pop-Location
```

Argumentos: `--show`, `--start`, `--stop`, `--restart`, `--kiosk`, `--exit-kiosk`, `--diagnostics`, `--autostart` e `--exit`. A segunda execução não abre outra janela; ela envia o comando para a instância principal via named pipe.

O menu do tray oferece abrir painel, iniciar/parar/reiniciar Android, kiosk, diagnóstico e encerramento. Fechar a janela apenas a oculta no tray. O startup do Windows, quando ativado na configuração, cria a tarefa `NeoNews Runtime Supervisor` com a ação `NeoNewsRuntime.exe --autostart`; nenhum PowerShell é usado pelo caminho de operação normal.

## Checklist manual de zero-console

1. Publique em `dist/NeoNewsRuntime`.
2. Execute `NeoNewsRuntime.exe --show` por duplo clique e confirme o painel escuro, tray e ausência de janela de terminal.
3. Execute novamente `NeoNewsRuntime.exe --show`; confirme que só há uma instância.
4. Execute `NeoNewsRuntime.exe --diagnostics`; confira `reports/` e `logs/`.
5. Execute `NeoNewsRuntime.exe --exit`; confirme que o processo encerrou.
6. Copie a pasta para `C:\NeoNews Runtime Test\NeoNewsRuntime\` e repita os passos 2–5. Caminhos com espaços devem funcionar.
7. Se o APK estiver disponível, use `--start`, `--install`, `--kiosk` e `--stop`; sem APK, o painel deve mostrar um erro gráfico explicando a dependência ausente.

O registro da tarefa do Agendador depende da permissão do Windows. O launcher tenta primeiro sem elevação e solicita UAC somente para `schtasks.exe` quando recebe `Acesso negado`; confirme que a ação contém somente `NeoNewsRuntime.exe --autostart`.

Os logs são gravados ao lado da distribuição em `logs/`; diagnósticos ficam em `reports/`. Não versionar APK, SDK Android, `bin/`, `obj/`, `dist/`, logs ou relatórios gerados.
