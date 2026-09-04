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

if (-not ('NoVisibleConsoleProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class NoVisibleConsoleProbe
{
    private delegate void WinEventDelegate(IntPtr hook, uint eventType, IntPtr hWnd, int objectId, int childId, uint eventThread, uint eventTime);
    private const uint EventObjectCreate = 0x8000;
    private const uint EventObjectShow = 0x8002;
    private const uint WineventOutOfContext = 0;
    private const uint ObjidWindow = 0;
    private const uint Th32csSnapprocess = 0x00000002;
    private const uint WmQuit = 0x0012;

    [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint minEvent, uint maxEvent, IntPtr module, WinEventDelegate callback, uint processId, uint threadId, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint threadId, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern int GetMessage(out NativeMessage message, IntPtr window, uint minFilter, uint maxFilter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder title, int maxCount);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool Process32First(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] private struct NativeMessage
    {
        public IntPtr Window;
        public uint Message;
        public IntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public NativePoint Point;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct ProcessEntry
    {
        public uint Size;
        public uint Usage;
        public uint ProcessId;
        public IntPtr DefaultHeap;
        public uint ModuleId;
        public uint Threads;
        public uint ParentProcessId;
        public int Priority;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ExeFile;
    }

    public sealed class WindowRecord
    {
        public string TimestampUtc { get; set; }
        public string Event { get; set; }
        public int ProcessId { get; set; }
        public int ParentProcessId { get; set; }
        public string ProcessPath { get; set; }
        public long Handle { get; set; }
        public string ClassName { get; set; }
        public string Title { get; set; }
        public bool Visible { get; set; }
    }

    private static readonly object Sync = new object();
    private static readonly List<WindowRecord> Events = new List<WindowRecord>();
    private static readonly WinEventDelegate Callback = OnWinEvent;
    private static readonly ManualResetEvent HookReady = new ManualResetEvent(false);
    private static Thread HookThread;
    private static uint HookThreadId;
    private static bool StopRequested;
    private static IntPtr CreateHook;
    private static IntPtr ShowHook;

    private static string ReadProcessPath(int processId)
    {
        try
        {
            using (var process = Process.GetProcessById(processId))
            {
                return process.MainModule == null ? string.Empty : process.MainModule.FileName;
            }
        }
        catch { return string.Empty; }
    }

    private static int ReadParentProcessId(int processId)
    {
        var snapshot = CreateToolhelp32Snapshot(Th32csSnapprocess, 0);
        if (snapshot == IntPtr.Zero || snapshot.ToInt64() == -1) return 0;
        try
        {
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf(typeof(ProcessEntry)) };
            if (!Process32First(snapshot, ref entry)) return 0;
            do
            {
                if (entry.ProcessId == (uint)processId) return (int)entry.ParentProcessId;
            } while (Process32Next(snapshot, ref entry));
            return 0;
        }
        finally { CloseHandle(snapshot); }
    }

    private static bool IsTechnicalClass(string className)
    {
        return className.IndexOf("console", StringComparison.OrdinalIgnoreCase) >= 0 ||
            className.IndexOf("cascadia", StringComparison.OrdinalIgnoreCase) >= 0 ||
            className.IndexOf("pseudoconsole", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static void OnWinEvent(IntPtr hook, uint eventType, IntPtr hWnd, int objectId, int childId, uint eventThread, uint eventTime)
    {
        if (hWnd == IntPtr.Zero || objectId != (int)ObjidWindow || childId != 0) return;
        var className = new StringBuilder(256);
        GetClassName(hWnd, className, className.Capacity);
        var normalizedClass = className.ToString();
        if (!IsTechnicalClass(normalizedClass)) return;
        uint processId;
        GetWindowThreadProcessId(hWnd, out processId);
        var title = new StringBuilder(512);
        GetWindowText(hWnd, title, title.Capacity);
        lock (Sync)
        {
            Events.Add(new WindowRecord
            {
                TimestampUtc = DateTime.UtcNow.ToString("o"),
                Event = eventType == EventObjectCreate ? "EVENT_OBJECT_CREATE" : "EVENT_OBJECT_SHOW",
                ProcessId = (int)processId,
                ParentProcessId = ReadParentProcessId((int)processId),
                ProcessPath = ReadProcessPath((int)processId),
                Handle = hWnd.ToInt64(),
                ClassName = normalizedClass,
                Title = title.ToString(),
                Visible = IsWindowVisible(hWnd)
            });
        }
    }

    private static void HookThreadProc()
    {
        HookThreadId = GetCurrentThreadId();
        CreateHook = SetWinEventHook(EventObjectCreate, EventObjectCreate, IntPtr.Zero, Callback, 0, 0, WineventOutOfContext);
        ShowHook = SetWinEventHook(EventObjectShow, EventObjectShow, IntPtr.Zero, Callback, 0, 0, WineventOutOfContext);
        HookReady.Set();
        NativeMessage message;
        while (!StopRequested && GetMessage(out message, IntPtr.Zero, 0, 0) > 0) { }
        if (CreateHook != IntPtr.Zero) UnhookWinEvent(CreateHook);
        if (ShowHook != IntPtr.Zero) UnhookWinEvent(ShowHook);
        CreateHook = IntPtr.Zero;
        ShowHook = IntPtr.Zero;
    }

    public static bool StartWinEventMonitor()
    {
        lock (Sync)
        {
            Events.Clear();
            StopRequested = false;
            HookReady.Reset();
            HookThread = new Thread(HookThreadProc);
            HookThread.IsBackground = true;
            HookThread.Start();
        }
        if (!HookReady.WaitOne(3000)) return false;
        return CreateHook != IntPtr.Zero && ShowHook != IntPtr.Zero;
    }

    public static List<WindowRecord> StopWinEventMonitor()
    {
        lock (Sync) { StopRequested = true; }
        if (HookThread != null)
        {
            PostThreadMessage(HookThreadId, WmQuit, IntPtr.Zero, IntPtr.Zero);
            HookThread.Join(3000);
            HookThread = null;
        }
        lock (Sync) { return new List<WindowRecord>(Events); }
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
    eventMonitor = 'SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_SHOW)'
    eventMonitorStarted = $false
    observedTechnicalWindows = @()
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
        $eventMonitorAttempted = $false
        $eventMonitorStarted = $false
        $eventMonitorStopped = $false
        $eventRecords = @()
        $observedProcessIds = New-Object 'System.Collections.Generic.HashSet[int]'
        $scenarioStart = [DateTimeOffset]::UtcNow
        try {
            $eventMonitorAttempted = $true
            $eventMonitorStarted = [NoVisibleConsoleProbe]::StartWinEventMonitor()
            $runtimeObservation.eventMonitorStarted = $eventMonitorStarted
            $null = $process.Start()
            $deadline = (Get-Date).AddSeconds(45)
            [void]$observedProcessIds.Add($process.Id)
            while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
                $ids = @(Get-ProcessTreeIds $process.Id)
                foreach ($id in $ids) { [void]$observedProcessIds.Add([int]$id) }
                Start-Sleep -Milliseconds 50
            }
            if (-not $process.HasExited) {
                try { $process.Kill() } catch { }
            }
            if ($eventMonitorStarted) {
                $eventRecords = @([NoVisibleConsoleProbe]::StopWinEventMonitor())
                $eventMonitorStopped = $true
            }
            $operationRoot = Split-Path -Parent $ExecutablePath
            $ownedEvents = @($eventRecords | Where-Object {
                $path = [string]$_.ProcessPath
                $observedProcessIds.Contains([int]$_.ProcessId) -or
                    $observedProcessIds.Contains([int]$_.ParentProcessId) -or
                    (-not [string]::IsNullOrWhiteSpace($path) -and $path.StartsWith($operationRoot, [StringComparison]::OrdinalIgnoreCase))
            })
            $scenarioEnd = [DateTimeOffset]::UtcNow
            if ($process.HasExited) { $runtimeObservation.exitCode = $process.ExitCode }
            $runtimeObservation.processFinished = $process.HasExited
            $runtimeObservation.observedTechnicalWindows = $ownedEvents
            $runtimeObservation.allTechnicalWindowEvents = $eventRecords
            $runtimeObservation.startTime = $scenarioStart.ToString('o')
            $runtimeObservation.endTime = $scenarioEnd.ToString('o')
            $runtimeObservation.status = if ($eventMonitorStarted -and $process.HasExited -and $process.ExitCode -eq 0 -and $ownedEvents.Count -eq 0) { 'passed' } else { 'failed' }
            $runtimeObservation.detail = if ($runtimeObservation.status -eq 'passed') { 'Diagnóstico do launcher publicado encerrou sem janela de console visível; a detecção usou eventos Win32.' } else { 'A observação encontrou falha do hook, timeout, código de saída diferente de zero ou janela técnica.' }
        } finally {
            if ($eventMonitorAttempted -and -not $eventMonitorStopped) {
                try { $eventRecords = @([NoVisibleConsoleProbe]::StopWinEventMonitor()) } catch { }
            }
            $process.Dispose()
        }
    }
}

$staticPassed = @($staticChecks.Values | Where-Object { -not [bool]$_ }).Count -eq 0
$observationPassed = $runtimeObservation.status -eq 'passed'
$manualScenarioNames = @('installation','firstBoot','startup','runtime','qemu','adb','guardianRecovery','neoNewsRestart','update','f11','f12','uninstallOrUpgrade')
$scenarios = @([ordered]@{
    Scenario = 'launcher-diagnostics'
    StartTime = $runtimeObservation.startTime
    EndTime = $runtimeObservation.endTime
    ObservedTechnicalWindows = @($runtimeObservation.observedTechnicalWindows)
    Status = if ($observationPassed) { 'PASS' } else { [string]$runtimeObservation.status }
    Evidence = 'event-monitor'
})
foreach ($scenarioName in $manualScenarioNames) {
    $declared = [bool]$manualEvidence[$scenarioName]
    $notApplicable = $scenarioName -eq 'uninstallOrUpgrade' -and [bool]$UninstallUpgradeNotApplicable
    $scenarios += [ordered]@{
        Scenario = $scenarioName
        StartTime = $null
        EndTime = $null
        ObservedTechnicalWindows = @()
        Status = if ($notApplicable) { 'NOT_APPLICABLE' } elseif ($declared) { 'MANUAL_ONLY_NOT_VALIDATED' } else { 'NOT_RUN' }
        Evidence = if ($declared) { 'MANUAL_VISUAL_EVIDENCE — requires scenario event capture before PASS' } else { 'event-monitor-observation-required' }
    }
}
$allScenariosPassed = @($scenarios | Where-Object { $_.Status -ne 'PASS' -and $_.Status -ne 'NOT_APPLICABLE' }).Count -eq 0
$status = if ($staticPassed -and $allScenariosPassed) { 'validated' } elseif ($manualMissing.Count -gt 0 -or $runtimeObservation.status -eq 'not-run' -or @($scenarios | Where-Object { $_.Status -eq 'MANUAL_ONLY_NOT_VALIDATED' }).Count -gt 0) { 'pending-evidence' } else { 'not-validated' }
$result = [ordered]@{
    timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    gate = 'NO_VISIBLE_CONSOLE_PASS'
    status = $status
    staticChecks = $staticChecks
    startProcessViolations = $startProcessViolations
    runtimeObservation = $runtimeObservation
    scenarios = $scenarios
    manualEvidence = $manualEvidence
    missingManualEvidence = $manualMissing
    criteria = 'Nenhum console técnico visível em instalação, boot, startup, runtime, QEMU, ADB, Guardian/recovery, restart, update, F11, F12 e uninstall/upgrade quando aplicável.'
}
$reportDirectory = Split-Path -Parent $reportFullPath
if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory -PathType Container)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportFullPath -Encoding utf8
$result | ConvertTo-Json -Depth 12
if ($status -ne 'validated') { exit 1 }
