[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $RepositoryRoot 'reports\host-isolation.json' }
elseif (-not [System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath = Join-Path $RepositoryRoot ($ReportPath.Replace('/', [char]92)) }

function Read-RequiredJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Arquivo obrigatorio ausente: $Path" }
    Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

function Add-Check([System.Collections.IDictionary]$Target, [string]$Name, [bool]$Passed, [string]$Detail, [string]$Evidence) {
    $Target[$Name] = [ordered]@{ status = if ($Passed) { 'pass' } else { 'fail' }; detail = $Detail; evidence = $Evidence }
}

$configPath = Join-Path $RepositoryRoot 'config\runtime.json'
$configRaw = Get-Content -LiteralPath $configPath -Raw -Encoding utf8
$config = Read-RequiredJson $configPath
$launcherRoot = Join-Path $RepositoryRoot 'launcher\NeoNews.Runtime.Launcher'
$launcherFiles = @(Get-ChildItem -LiteralPath $launcherRoot -Filter '*.cs' -Recurse)
$launcherSource = (($launcherFiles | Get-Content -Raw -Encoding utf8) -join "`n")
$runtimeContextSource = Get-Content -LiteralPath (Join-Path $launcherRoot 'Services\RuntimeContext.cs') -Raw -Encoding utf8
$runtimePathsSource = Get-Content -LiteralPath (Join-Path $launcherRoot 'Services\RuntimePaths.cs') -Raw -Encoding utf8
$adbSource = Get-Content -LiteralPath (Join-Path $launcherRoot 'Services\AdbService.cs') -Raw -Encoding utf8
$qemuSource = Get-Content -LiteralPath (Join-Path $launcherRoot 'Services\QemuAndroidRuntimeBackend.cs') -Raw -Encoding utf8
$processSource = Get-Content -LiteralPath (Join-Path $launcherRoot 'Services\ProcessRunnerService.cs') -Raw -Encoding utf8
$singleInstanceSource = Get-Content -LiteralPath (Join-Path $launcherRoot 'Services\SingleInstanceService.cs') -Raw -Encoding utf8
$appSource = Get-Content -LiteralPath (Join-Path $launcherRoot 'App.xaml.cs') -Raw -Encoding utf8
$publishSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts\build\Publish-NeoNewsRuntime.ps1') -Raw -Encoding utf8
$genericProcessInvocations = @($launcherSource -split "`r?`n" | Where-Object {
    ($_.IndexOf('Process.Start', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.IndexOf('Start-Process', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -and
    ($_.IndexOf('adb', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.IndexOf('qemu-system', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.IndexOf('emulator', [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
})

$checks = [ordered]@{}
$adb = $config.android.adb
$qemu = $config.android.qemu
$isolation = $config.hostIsolation
$portValues = @([int]$adb.serverPort, [int]$adb.hostPort, [int]$qemu.qmpPort)
$duplicatePorts = @($portValues | Group-Object | Where-Object Count -gt 1)
$configuredRuntimePaths = @([string]$qemu.executable, [string]$qemu.disk, [string]$qemu.androidImage)
$allRuntimePathsRelative = @($configuredRuntimePaths | Where-Object { -not ($_.StartsWith('runtime/', [System.StringComparison]::OrdinalIgnoreCase) -or $_.StartsWith(('runtime' + [char]92), [System.StringComparison]::OrdinalIgnoreCase)) }).Count -eq 0
$hasHostDrivePath = $false
foreach ($letterCode in 65..90) {
    $letter = [char]$letterCode
    $driveSlash = [string]::Concat($letter, ':', [char]92)
    $driveForward = [string]::Concat($letter, ':/')
    if ($configRaw.Contains($driveSlash) -or $configRaw.Contains($driveForward)) { $hasHostDrivePath = $true; break }
}
$privateAdbValid = ([string]$adb.serverHost -eq '127.0.0.1') -and ([int]$adb.serverPort -eq 5038) -and ([string]$adb.host -eq '127.0.0.1') -and ([int]$adb.hostPort -eq 5556) -and ([int]$adb.guestPort -eq 5555) -and ($duplicatePorts.Count -eq 0)

Add-Check $checks 'config.hostIsolation' ([bool]$isolation.requireBundledTools -and [bool]$isolation.clearHostToolEnvironment -and [bool]$isolation.singleInstancePerDistribution -and [bool]$isolation.refusePortConflicts -and [string]$isolation.processOwnership -eq 'child-process-only') 'Politica persistente de ferramentas empacotadas, ambiente limpo, instancia por distribuicao e recusa de conflito.' 'config/runtime.json:hostIsolation'
Add-Check $checks 'config.relativeDistributionPaths' ($allRuntimePathsRelative -and [string]$config.android.tooling.sdkRoot -eq 'runtime') 'QEMU, disco, imagem e SDK logico sao relativos a raiz da distribuicao.' 'config/runtime.json:android.qemu/tooling'
Add-Check $checks 'config.privateAdbContract' $privateAdbValid 'ADB privado em 127.0.0.1:5038; transporte host 5556 para guest 5555; portas distintas.' 'config/runtime.json:android.adb'
Add-Check $checks 'runtimePathsCentralized' ($runtimePathsSource.Contains('class RuntimePaths') -and $runtimePathsSource.Contains('ResolveBundledTool') -and $runtimeContextSource.Contains('Paths = new RuntimePaths')) 'As resolucoes de raiz, estado, logs e ferramentas passam por RuntimePaths.' 'RuntimePaths.cs; RuntimeContext.cs'
Add-Check $checks 'bundledAbsoluteTools' ($runtimeContextSource.Contains('ResolveBundledTool') -and $runtimeContextSource.Contains('AllowEnvironmentFallback') -and $runtimeContextSource.Contains('return configured') -and $genericProcessInvocations.Count -eq 0) 'O launcher resolve executaveis absolutos da distribuicao; fallback de SDK fica restrito ao ramo explicito de diagnostico.' 'RuntimeContext.cs; launcher/*.cs'
Add-Check $checks 'adbUsesPrivateServer' ($adbSource.Contains('"-P"') -and $adbSource.Contains('ServerPort') -and $adbSource.Contains('ANDROID_ADB_SERVER_PORT') -and $adbSource.Contains('BuildEnvironment')) 'Toda chamada ADB recebe -P 5038 e ANDROID_ADB_SERVER_PORT no processo filho.' 'AdbService.cs'
Add-Check $checks 'adbServerOwnedByLauncher' ($adbSource.Contains('StartOwnedServerAsync') -and $adbSource.Contains('nodaemon') -and $adbSource.Contains('"server"') -and $adbSource.Contains('StopServerAsync') -and $adbSource.Contains('AdbServerStatePath') -and $adbSource.Contains('HostPortGuard.EnsureAvailable')) 'O launcher cria o servidor ADB privado em foreground, registra seu PID e encerra somente o processo que criou.' 'AdbService.cs; RuntimePaths.cs; HostIsolationServices.cs'
Add-Check $checks 'qemuUsesPrivatePorts' ($qemuSource.Contains('HostPortGuard.EnsureAvailable') -and $qemuSource.Contains('hostfwd=tcp') -and $qemuSource.Contains('127.0.0.1:{qmpPort}') -and $qemuSource.Contains('EnsureDistinct')) 'QEMU valida 5556/4445, encaminha o transporte ADB e expoe QMP em loopback.' 'QemuAndroidRuntimeBackend.cs; HostIsolationServices.cs'
Add-Check $checks 'noGlobalProcessDiscoveryOrKill' (-not $launcherSource.Contains('GetProcessesByName') -and $launcherSource.IndexOf('taskkill /IM', [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -and $launcherSource.IndexOf('adb kill-server', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) 'Nao ha descoberta por nome global nem encerramento global de ADB/QEMU/emulador.' 'launcher/**/*.cs'
Add-Check $checks 'ownedProcessLifecycle' ($qemuSource.Contains('_process') -and $adbSource.Contains('_serverProcess') -and $qemuSource.Contains('HostProcessOwnership.WriteAsync') -and $adbSource.Contains('HostProcessOwnership.WriteAsync') -and $qemuSource.Contains('HostProcessOwnership.ClearAsync') -and $adbSource.Contains('HostProcessOwnership.ClearAsync') -and $processSource.Contains('Kill(entireProcessTree: true)')) 'QEMU e o servidor ADB sao encerrados somente pelas instancias criadas pelo runtime, com PID gravado no estado privado.' 'QemuAndroidRuntimeBackend.cs; AdbService.cs; ProcessRunnerService.cs; HostIsolationServices.cs'
Add-Check $checks 'singleInstanceScopedToDistribution' ($singleInstanceSource.Contains('SHA256') -and $singleInstanceSource.Contains('distributionRoot') -and $appSource.Contains('new SingleInstanceService(_context.RootDirectory)')) 'Mutex e pipe sao derivados da raiz da distribuicao.' 'SingleInstanceService.cs; App.xaml.cs'
Add-Check $checks 'hostEnvironmentSanitized' ($processSource.Contains('ApplyIsolatedEnvironment') -and $processSource.Contains('ANDROID_HOME') -and $processSource.Contains('JAVA_HOME') -and $processSource.Contains('QEMU_AUDIO_DRV') -and $processSource.Contains('PATH')) 'Processos filhos removem variaveis de SDK/Java/QEMU/ADB do host e recebem PATH minimo.' 'ProcessRunnerService.cs'
Add-Check $checks 'noGlobalEnvironmentMutation' (-not $launcherSource.Contains('Environment.SetEnvironmentVariable') -and $publishSource.IndexOf('setx ', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) 'O runtime nao grava variaveis globais do Windows.' 'launcher/**/*.cs; Publish-NeoNewsRuntime.ps1'
Add-Check $checks 'qemuShutdownIsOwned' ($qemuSource.Contains('RequestQmpShutdownAsync') -and $qemuSource.Contains('qmp_capabilities') -and $qemuSource.Contains('"quit"')) 'O desligamento normal negocia QMP antes do fallback limitado ao ManagedProcess.' 'QemuAndroidRuntimeBackend.cs'
Add-Check $checks 'publishIsSelfContained' ($publishSource.IndexOf('--self-contained true', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and $publishSource.IndexOf('PublishSingleFile=true', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and $publishSource.IndexOf('runtime win-x64', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) 'A publicacao declarada e win-x64, self-contained e single-file.' 'scripts/build/Publish-NeoNewsRuntime.ps1'
Add-Check $checks 'noHostAbsolutePathsInConfig' (-not $hasHostDrivePath) 'runtime.json nao contem caminhos absolutos de uma maquina especifica.' 'config/runtime.json'

$failed = @($checks.GetEnumerator() | Where-Object { $_.Value.status -eq 'fail' } | ForEach-Object { $_.Key })
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    repositoryRoot = $RepositoryRoot
    scope = 'static-host-isolation-quality-gate'
    checks = $checks
    failedChecks = $failed
    dynamicEvidence = [ordered]@{
        cleanDeveloperPc = 'not-run'
        cleanProductionPc = 'not-run'
        androidStudioCoexistence = 'not-run'
        externalQemuCoexistence = 'not-run'
        whpxBoot = 'not-run'
        publishedRuntime = 'not-run'
    }
    staticStatus = if ($failed.Count -eq 0) { 'passed' } else { 'failed' }
    status = if ($failed.Count -eq 0) { 'static-passed-dynamic-not-run' } else { 'failed' }
}
$reportDirectory = Split-Path -Parent $ReportPath
if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
$json = $result | ConvertTo-Json -Depth 12
Set-Content -LiteralPath $ReportPath -Value $json -Encoding utf8
$json
if ($failed.Count -gt 0) { exit 1 }
