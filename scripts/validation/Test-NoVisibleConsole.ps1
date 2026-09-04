[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ExecutablePath,
    [string]$ReportPath = 'reports/no-visible-console.json',
    [switch]$InstallationObserved,
    [switch]$FirstBootObserved,
    [switch]$StartupObserved,
    [switch]$RuntimeObserved,
    [switch]$QemuObserved,
    [switch]$AdbObserved,
    [switch]$GuardianRecoveryObserved,
    [switch]$NeoNewsRestartObserved,
    [switch]$UpdateObserved,
    [switch]$F11Observed,
    [switch]$F12Observed,
    [switch]$UninstallUpgradeObserved,
    [switch]$UninstallUpgradeNotApplicable,
    [switch]$ObserveLauncher
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if ([System.IO.Path]::IsPathRooted($ReportPath)) {
    $reportFullPath = [System.IO.Path]::GetFullPath($ReportPath)
} else {
    $reportFullPath = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot ($ReportPath -replace '/', '\')))
}

function Read-RequiredText([string]$RelativePath) {
    $path = Join-Path $RepositoryRoot ($RelativePath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Arquivo obrigatório ausente: $RelativePath" }
    return Get-Content -LiteralPath $path -Raw -Encoding utf8
}

function Get-InternalStartProcessViolations([string]$RelativePath) {
    $path = Join-Path $RepositoryRoot ($RelativePath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @($RelativePath) }
    $lines = Get-Content -LiteralPath $path -Encoding utf8
    $violations = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($line -match '(?i)Start-Process' -and $line -notmatch '(?i)^\s*#' -and $line -notmatch '(?i)-WindowStyle\s+Hidden') {
            $violations += [ordered]@{ file = $RelativePath; line = $index + 1; text = $line.Trim() }
        }
    }
    return $violations
}

$project = Read-RequiredText 'launcher/NeoNews.Runtime.Launcher/NeoNews.Runtime.Launcher.csproj'
$manifest = Read-RequiredText 'launcher/NeoNews.Runtime.Launcher/app.manifest'
$processRunner = Read-RequiredText 'launcher/NeoNews.Runtime.Launcher/Services/ProcessRunnerService.cs'
$scriptExecution = Read-RequiredText 'launcher/NeoNews.Runtime.Launcher/Services/ScriptExecutionService.cs'
$qemu = Read-RequiredText 'launcher/NeoNews.Runtime.Launcher/Services/QemuAndroidRuntimeBackend.cs'
$diagnosticsScript = Read-RequiredText 'scripts/diagnostics/Collect-Diagnostics.ps1'
$internalScripts = @(
    'scripts/diagnostics/Collect-Diagnostics.ps1',
    'scripts/runtime/Start-NeoNews.ps1',
    'scripts/runtime/Ensure-NeoNewsRuntime.ps1',
    'scripts/runtime/Watch-NeoNews.ps1'
)
$startProcessViolations = @($internalScripts | ForEach-Object { Get-InternalStartProcessViolations $_ })

$staticChecks = [ordered]@{
    launcherIsWinExe = $project -match '<OutputType>WinExe</OutputType>'
    launcherRunsAsInvoker = $manifest -match 'requestedExecutionLevel level="asInvoker"'
    childProcessUsesNoShell = $processRunner -match 'UseShellExecute\s*=\s*false'
    childProcessNeverCreatesConsole = $processRunner -match 'CreateNoWindow\s*=\s*true'
    childOutputIsRedirected = $processRunner -match 'RedirectStandardOutput\s*=\s*true' -and $processRunner -match 'RedirectStandardError\s*=\s*true'
    powershellExecutionIsHidden = $scriptExecution -match '"-WindowStyle", "Hidden"'
    diagnosticLaunchIsHidden = $diagnosticsScript -match 'Start-Process.*-WindowStyle Hidden'
    internalPowerShellStartsAreHidden = $startProcessViolations.Count -eq 0
    qemuConsoleEndpointsDisabled = $qemu -match '"-monitor", "none"' -and $qemu -match '"-serial", "none"' -and $qemu -match '"-display"'
}

$manualEvidence = [ordered]@{
    installation = [bool]$InstallationObserved
    firstBoot = [bool]$FirstBootObserved
    startup = [bool]$StartupObserved
    runtime = [bool]$RuntimeObserved
    qemu = [bool]$QemuObserved
    adb = [bool]$AdbObserved
    guardianRecovery = [bool]$GuardianRecoveryObserved
    neoNewsRestart = [bool]$NeoNewsRestartObserved
    update = [bool]$UpdateObserved
    f11 = [bool]$F11Observed
    f12 = [bool]$F12Observed
    uninstallOrUpgrade = [bool]$UninstallUpgradeObserved -or [bool]$UninstallUpgradeNotApplicable
    uninstallOrUpgradeNotApplicable = [bool]$UninstallUpgradeNotApplicable
}
$manualMissing = @($manualEvidence.Keys | Where-Object { $_ -ne 'uninstallOrUpgradeNotApplicable' -and -not [bool]$manualEvidence[$_] })

function Get-ProcessTreeIds([int]$RootProcessId) {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId,ParentProcessId)
    $ids = New-Object 'System.Collections.Generic.HashSet[int]'
    [void]$ids.Add($RootProcessId)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($item in $all) {
            if ($ids.Contains([int]$item.ParentProcessId) -and $ids.Add([int]$item.ProcessId)) { $changed = $true }
        }
    }
    return @($ids)
}

if (-not ('NeoNews.NoVisibleConsoleProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class NoVisibleConsoleProbe
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

    public sealed class WindowRecord
    {
        public int ProcessId { get; set; }
        public long Handle { get; set; }
        public string ClassName { get; set; }
    }

    public static List<WindowRecord> GetVisibleConsoleWindows(int[] processIds)
    {
        var allowed = new HashSet<int>(processIds ?? new int[0]);
        var result = new List<WindowRecord>();
        EnumWindows((hWnd, _) =>
        {
            if (!IsWindowVisible(hWnd)) return true;
            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);
            if (!allowed.Contains((int)processId)) return true;
            var className = new StringBuilder(256);
            GetClassName(hWnd, className, className.Capacity);
            var normalized = className.ToString();
            if (normalized.IndexOf("console", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normalized.IndexOf("cascadia", StringComparison.OrdinalIgnoreCase) >= 0 ||
                normalized.IndexOf("pseudoconsole", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                result.Add(new WindowRecord { ProcessId = (int)processId, Handle = hWnd.ToInt64(), ClassName = normalized });
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@
}

$runtimeObservation = [ordered]@{
    requested = [bool]$ObserveLauncher
    status = 'not-run'
    executable = $null
    exitCode = $null
    processFinished = $false
    visibleConsoleWindows = @()
    detail = 'Observação real não executada; forneça -ObserveLauncher e as evidências manuais após observar o produto publicado.'
}

if ($ObserveLauncher) {
    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
        $candidates = @(
            (Join-Path $RepositoryRoot 'dist\NeoNewsRuntime-current\NeoNewsRuntime.exe'),
            (Join-Path $RepositoryRoot 'dist\NeoNewsRuntime\NeoNewsRuntime.exe')
        )
        $ExecutablePath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    }
    if ([string]::IsNullOrWhiteSpace($ExecutablePath) -or -not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        $runtimeObservation.detail = 'NeoNewsRuntime.exe não encontrado para observação.'
    } else {
        $ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
        $runtimeObservation.executable = $ExecutablePath
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $ExecutablePath
        $startInfo.WorkingDirectory = Split-Path -Parent $ExecutablePath
        $startInfo.Arguments = '--diagnostics'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            $null = $process.Start()
            $deadline = (Get-Date).AddSeconds(45)
            $windows = @()
            while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
                $ids = @(Get-ProcessTreeIds $process.Id)
                $windows = @([NoVisibleConsoleProbe]::GetVisibleConsoleWindows([int[]]$ids))
                if ($windows.Count -gt 0) { break }
                Start-Sleep -Milliseconds 250
            }
            if (-not $process.HasExited -and $windows.Count -eq 0) {
                try { $process.Kill() } catch { }
            }
            if ($process.HasExited) { $runtimeObservation.exitCode = $process.ExitCode }
            $runtimeObservation.processFinished = $process.HasExited
            $runtimeObservation.visibleConsoleWindows = $windows
            $runtimeObservation.status = if ($process.HasExited -and $process.ExitCode -eq 0 -and $windows.Count -eq 0) { 'passed' } else { 'failed' }
            $runtimeObservation.detail = if ($runtimeObservation.status -eq 'passed') { 'Diagnóstico do launcher publicado encerrou sem janela de console visível.' } else { 'A observação encontrou timeout, código de saída diferente de zero ou janela de console.' }
        } finally {
            $process.Dispose()
        }
    }
}

$staticPassed = @($staticChecks.Values | Where-Object { -not [bool]$_ }).Count -eq 0
$manualPassed = $manualMissing.Count -eq 0
$observationPassed = $runtimeObservation.status -eq 'passed'
$status = if ($staticPassed -and $manualPassed -and $observationPassed) { 'validated' } elseif (-not $manualPassed -or $runtimeObservation.status -eq 'not-run') { 'pending-evidence' } else { 'not-validated' }
$result = [ordered]@{
    timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    gate = 'NO_VISIBLE_CONSOLE_PASS'
    status = $status
    staticChecks = $staticChecks
    startProcessViolations = $startProcessViolations
    runtimeObservation = $runtimeObservation
    manualEvidence = $manualEvidence
    missingManualEvidence = $manualMissing
    criteria = 'Nenhum console técnico visível em instalação, boot, startup, runtime, QEMU, ADB, Guardian/recovery, restart, update, F11, F12 e uninstall/upgrade quando aplicável.'
}
$reportDirectory = Split-Path -Parent $reportFullPath
if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory -PathType Container)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportFullPath -Encoding utf8
$result | ConvertTo-Json -Depth 12
if ($status -ne 'validated') { exit 1 }
