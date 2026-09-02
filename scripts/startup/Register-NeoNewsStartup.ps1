[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$TaskName,
    [string]$ExecutablePath,
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
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath = Join-Path $repositoryRoot 'dist\NeoNewsRuntime\NeoNewsRuntime.exe'
}
$ExecutablePath = [System.IO.Path]::GetFullPath($ExecutablePath)
if (-not (Test-Path -LiteralPath $ExecutablePath)) {
    throw "NeoNewsRuntime.exe não encontrado: $ExecutablePath"
}
$workingDirectory = Split-Path -Parent $ExecutablePath
$action = New-ScheduledTaskAction -Execute $ExecutablePath -Argument '--autostart' -WorkingDirectory $workingDirectory
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$trigger.Delay = 'PT30S'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

$result = [ordered]@{
    taskName = $TaskName
    executable = $ExecutablePath
    argument = '--autostart'
    workingDirectory = $workingDirectory
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
