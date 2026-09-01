[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$TaskName,
    [switch]$Apply,
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuração não encontrada: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
if (-not $TaskName) {
    $TaskName = [string]$config.startup.taskName
}
if (-not $TaskName) {
    $TaskName = 'NeoNews Runtime Supervisor'
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$supervisorScript = (Resolve-Path (Join-Path $PSScriptRoot '..\runtime\Watch-NeoNews.ps1')).Path
$powershellCommand = Get-Command pwsh -ErrorAction SilentlyContinue
if ($powershellCommand) {
    $powershellPath = $powershellCommand.Source
} else {
    $powershellPath = Join-Path $PSHOME 'powershell.exe'
}

$logPath = Join-Path $repositoryRoot $config.supervisor.logPath
$serial = if ($config.android.emulator.validationPort) { "emulator-$($config.android.emulator.validationPort)" } else { 'emulator-5556' }
$actionArguments = "-NoLogo -NonInteractive -ExecutionPolicy Bypass -File `"$supervisorScript`" -Serial $serial -LogPath `"$logPath`""
$action = New-ScheduledTaskAction -Execute $powershellPath -Argument $actionArguments -WorkingDirectory $repositoryRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$trigger.Delay = 'PT30S'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

$result = [ordered]@{
    taskName = $TaskName
    powershell = $powershellPath
    supervisorScript = $supervisorScript
    workingDirectory = $repositoryRoot
    serial = $serial
    actionArguments = $actionArguments
    applyRequested = [bool]$Apply
    unregisterRequested = [bool]$Unregister
    status = 'preview'
}

if ($Unregister) {
    if ($Apply -and $PSCmdlet.ShouldProcess($TaskName, 'remover tarefa agendada')) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        $result.status = 'unregistered'
    } else {
        $result.status = 'unregister-preview'
    }
} elseif ($Apply -and $PSCmdlet.ShouldProcess($TaskName, 'registrar tarefa agendada no logon do usuário')) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    $result.status = 'registered'
}

$result | ConvertTo-Json -Depth 8
