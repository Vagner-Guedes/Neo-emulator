[CmdletBinding()]
param(
    [string]$ExecutablePath,
    [int]$StartupTimeoutSeconds = 20,
    [string]$ReportPath = 'reports/launcher-smoke.json',
    [switch]$TrayObserved,
    [switch]$HotkeyObserved
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $candidates = @(
        (Join-Path $repositoryRoot 'dist\NeoNewsRuntime\NeoNewsRuntime.exe'),
        (Join-Path $repositoryRoot 'launcher\NeoNews.Runtime.Launcher\bin\Release\net8.0-windows\NeoNewsRuntime.exe')
    )
    $ExecutablePath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($ExecutablePath) -or -not (Test-Path -LiteralPath $ExecutablePath)) {
    throw "NeoNewsRuntime.exe nÃ£o encontrado. Informe -ExecutablePath ou publique o runtime antes do smoke test."
}
$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
$workingDirectory = Split-Path -Parent $ExecutablePath

$first = $null
$second = $null
$exitCommand = $null
$responsive = $false
$handle = [IntPtr]::Zero
$title = ''
$firstRunningAfterStartup = $false
$secondExitCode = $null
$exitCommandCode = $null
$remaining = @()
try {
    $first = Start-Process -FilePath $ExecutablePath -ArgumentList '--show' -WorkingDirectory $workingDirectory -PassThru
    $deadline = (Get-Date).AddSeconds([math]::Max(1, $StartupTimeoutSeconds))
    do {
        Start-Sleep -Milliseconds 200
        try {
            $first.Refresh()
            if (-not $first.HasExited) {
                $handle = $first.MainWindowHandle
                $title = $first.MainWindowTitle
            }
        }
        catch { }
        if (-not $first.HasExited -and $handle -ne [IntPtr]::Zero) { $responsive = $true; break }
    } while ((Get-Date) -lt $deadline)
    $firstRunningAfterStartup = -not $first.HasExited

    $second = Start-Process -FilePath $ExecutablePath -ArgumentList '--show' -WorkingDirectory $workingDirectory -PassThru -Wait
    $secondExitCode = $second.ExitCode
    $exitCommand = Start-Process -FilePath $ExecutablePath -ArgumentList '--exit' -WorkingDirectory $workingDirectory -PassThru -Wait
    $exitCommandCode = $exitCommand.ExitCode
    Start-Sleep -Milliseconds 600
}
finally {
    if ($first) {
        try { $first.Refresh() } catch { }
        if (-not $first.HasExited) {
            try {
                $cleanup = Start-Process -FilePath $ExecutablePath -ArgumentList '--exit' -WorkingDirectory $workingDirectory -PassThru -Wait
                $exitCommandCode = if ($null -eq $exitCommandCode) { $cleanup.ExitCode } else { $exitCommandCode }
            }
            catch { }
        }
    }
    Start-Sleep -Milliseconds 300
    $remaining = @(Get-Process -Name 'NeoNewsRuntime' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $ExecutablePath } catch { $false }
    } | Select-Object -ExpandProperty Id)
}

$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    executable = $ExecutablePath
    workingDirectory = $workingDirectory
    outputType = 'WinExe'
    firstProcess = [ordered]@{ running = $firstRunningAfterStartup; responsive = $responsive; mainWindowHandle = $handle.ToInt64(); title = $title }
    singleInstance = [ordered]@{ secondInvocationExitCode = $secondExitCode; passed = $secondExitCode -eq 0 }
    cliExit = [ordered]@{ exitCode = $exitCommandCode; passed = $exitCommandCode -eq 0 }
    manualEvidence = [ordered]@{ trayObserved = [bool]$TrayObserved; hotkeyObserved = [bool]$HotkeyObserved }
    noResidualLauncher = $remaining.Count -eq 0
    remainingProcessIds = $remaining
    status = if ($responsive -and $firstRunningAfterStartup -and $secondExitCode -eq 0 -and $exitCommandCode -eq 0 -and $remaining.Count -eq 0) { 'validated' } else { 'not-validated' }
}
$json = $result | ConvertTo-Json -Depth 10
$reportFullPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $repositoryRoot $ReportPath }
$reportDirectory = Split-Path -Parent $reportFullPath
if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
Set-Content -LiteralPath $reportFullPath -Value $json -Encoding utf8
$json
if ($result.status -ne 'validated') { throw "Smoke test do launcher nÃ£o validado: status=$($result.status). Consulte $reportFullPath." }
