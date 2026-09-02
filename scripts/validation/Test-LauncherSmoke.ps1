[CmdletBinding()]
param(
    [string]$ExecutablePath,
    [int]$StartupTimeoutSeconds = 20,
    [string]$ReportPath,
    [switch]$PathWithSpaces,
    [switch]$NoConsoleObserved,
    [switch]$TrayObserved,
    [switch]$HotkeyObserved,
    [switch]$KioskObserved,
    [switch]$QemuNoConsoleObserved,
    [switch]$WatchdogActivityObserved,
    [switch]$WatchdogQemuObserved,
    [switch]$WindowsRestartObserved,
    [switch]$UpdatePreservationObserved,
    [switch]$NeoNewsContentObserved,
    [switch]$NeoNewsPlaybackObserved
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repositoryRoot 'scripts\validation\ValidationEvidence.Common.ps1')
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $candidates = @(
        (Join-Path $repositoryRoot 'dist\NeoNewsRuntime\NeoNewsRuntime.exe'),
        (Join-Path $repositoryRoot 'launcher\NeoNews.Runtime.Launcher\bin\Release\net8.0-windows\NeoNewsRuntime.exe')
    )
    $ExecutablePath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($ExecutablePath) -or -not (Test-Path -LiteralPath $ExecutablePath)) {
    throw "NeoNewsRuntime.exe não encontrado. Informe -ExecutablePath ou publique o runtime antes do smoke test."
}
$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
$workingDirectory = Split-Path -Parent $ExecutablePath
$reportPathToUse = if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    Join-Path $workingDirectory 'reports\launcher-smoke.json'
} else {
    Resolve-ValidationReportPath -RepositoryRoot $repositoryRoot -ReportPath $ReportPath
}
$reportFullPath = Initialize-ValidationReport -ReportPath $reportPathToUse -Validator 'Test-LauncherSmoke'

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
$pathWithSpacesPassed = $false
$spaceTest = $null
$spaceRoot = $null
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

if ($PathWithSpaces) {
    $spaceRoot = Join-Path $env:TEMP ("NeoNews Runtime Smoke " + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $spaceRoot -Force | Out-Null
    try {
        Copy-Item -Path (Join-Path $workingDirectory '*') -Destination $spaceRoot -Recurse -Force
        $spaceExecutable = Join-Path $spaceRoot (Split-Path -Leaf $ExecutablePath)
        $spaceFirst = Start-Process -FilePath $spaceExecutable -ArgumentList '--show' -WorkingDirectory $spaceRoot -PassThru
        $spaceDeadline = (Get-Date).AddSeconds([math]::Max(1, $StartupTimeoutSeconds))
        $spaceHandle = [IntPtr]::Zero
        $spaceTitle = ''
        do {
            Start-Sleep -Milliseconds 200
            try {
                $spaceFirst.Refresh()
                if (-not $spaceFirst.HasExited) {
                    $spaceHandle = $spaceFirst.MainWindowHandle
                    $spaceTitle = $spaceFirst.MainWindowTitle
                }
            }
            catch { }
            if (-not $spaceFirst.HasExited -and $spaceHandle -ne [IntPtr]::Zero) { break }
        } while ((Get-Date) -lt $spaceDeadline)
        $spaceResponsive = -not $spaceFirst.HasExited -and $spaceHandle -ne [IntPtr]::Zero
        $spaceExit = Start-Process -FilePath $spaceExecutable -ArgumentList '--exit' -WorkingDirectory $spaceRoot -PassThru -Wait
        Start-Sleep -Milliseconds 500
        $spaceRemaining = @(Get-Process -Name 'NeoNewsRuntime' -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -eq $spaceExecutable } catch { $false }
        } | Select-Object -ExpandProperty Id)
        $pathWithSpacesPassed = $spaceResponsive -and $spaceExit.ExitCode -eq 0 -and $spaceRemaining.Count -eq 0
        $spaceTest = [ordered]@{
            executable = $spaceExecutable
            workingDirectory = $spaceRoot
            responsive = $spaceResponsive
            mainWindowHandle = $spaceHandle.ToInt64()
            title = $spaceTitle
            exitCode = $spaceExit.ExitCode
            noResidual = $spaceRemaining.Count -eq 0
            remainingProcessIds = $spaceRemaining
            passed = $pathWithSpacesPassed
        }
    }
    finally {
        try {
            if ($spaceFirst -and -not $spaceFirst.HasExited) {
                $cleanup = Start-Process -FilePath $spaceExecutable -ArgumentList '--exit' -WorkingDirectory $spaceRoot -PassThru -Wait
                $spaceFirst.Refresh()
            }
        }
        catch { }
        if ($spaceRoot -and (Test-Path -LiteralPath $spaceRoot)) { Remove-Item -LiteralPath $spaceRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$launcherRoot = (Join-Path $repositoryRoot 'launcher').TrimEnd([char]92, [char]47) + [System.IO.Path]::DirectorySeparatorChar
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    executable = $ExecutablePath
    workingDirectory = $workingDirectory
    outputType = 'WinExe'
    firstProcess = [ordered]@{ running = $firstRunningAfterStartup; responsive = $responsive; mainWindowHandle = $handle.ToInt64(); title = $title }
    singleInstance = [ordered]@{ secondInvocationExitCode = $secondExitCode; passed = $secondExitCode -eq 0 }
    cliExit = [ordered]@{ exitCode = $exitCommandCode; passed = $exitCommandCode -eq 0 }
    manualEvidence = [ordered]@{
        noConsoleObserved = [bool]$NoConsoleObserved
        qemuNoConsoleObserved = [bool]$QemuNoConsoleObserved
        trayObserved = [bool]$TrayObserved
        hotkeyObserved = [bool]$HotkeyObserved
        kioskObserved = [bool]$KioskObserved
        watchdogActivityObserved = [bool]$WatchdogActivityObserved
        watchdogQemuObserved = [bool]$WatchdogQemuObserved
        windowsRestartObserved = [bool]$WindowsRestartObserved
        updatePreservationObserved = [bool]$UpdatePreservationObserved
        neoNewsContentObserved = [bool]$NeoNewsContentObserved
        neoNewsPlaybackObserved = [bool]$NeoNewsPlaybackObserved
    }
    outsideProject = -not $ExecutablePath.StartsWith($launcherRoot, [StringComparison]::OrdinalIgnoreCase)
    pathWithSpaces = [ordered]@{ requested = [bool]$PathWithSpaces; passed = $pathWithSpacesPassed; details = $spaceTest }
    noResidualLauncher = $remaining.Count -eq 0
    remainingProcessIds = $remaining
    status = if ($responsive -and $firstRunningAfterStartup -and $secondExitCode -eq 0 -and $exitCommandCode -eq 0 -and $remaining.Count -eq 0) { 'validated' } else { 'not-validated' }
}
$json = $result | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $reportFullPath -Value $json -Encoding utf8
$json
if ($result.status -ne 'validated') { throw "Smoke test do launcher não validado: status=$($result.status). Consulte $reportFullPath." }
