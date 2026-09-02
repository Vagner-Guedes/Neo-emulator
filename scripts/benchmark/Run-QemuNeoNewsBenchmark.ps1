[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$Iterations = 3,
    [int]$BootTimeoutSeconds = 180,
    [int]$NeoNewsTimeoutSeconds = 120,
    [int]$StabilitySeconds = 60,
    [int]$HostSampleSeconds = 2,
    [string]$ReportPath = 'reports/qemu-benchmark.json'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }
if ($Iterations -lt 1) { throw 'Iterations must be at least 1.' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration not found: $ConfigPath" }
$configPathFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$repositoryRoot = [System.IO.Directory]::GetParent([System.IO.Directory]::GetParent($configPathFull).FullName).FullName
$config = Get-Content -LiteralPath $configPathFull -Raw -Encoding utf8 | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'QemuBenchmark.Common.ps1')
$paths = Resolve-QemuBenchmarkPaths -RepositoryRoot $repositoryRoot -Config $config
if (-not (Test-QemuBenchmarkNonEmptyFile $paths.Adb) -and $config.android.tooling.allowEnvironmentFallback) { $paths.Adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe' }
Assert-QemuBenchmarkProvisionedRuntime -Config $config -Paths $paths
if (-not (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\WinHvPlatform.dll'))) { throw 'WHPX library not found.' }

$serial = "$($config.android.adb.host):$($config.android.adb.hostPort)"
$arguments = New-QemuBenchmarkArguments -Config $config -DiskPath $paths.Disk -RepositoryRoot $repositoryRoot
$runs = @()
for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    $startedAt = Get-Date
    $process = $null
    $processId = $null
    $milestones = $null
    $launch = $null
    $hostIdle = $null
    $hostWorkload = $null
    $metrics = $null
    $stability = $null
    $stopped = $false
    try {
        $process = Start-QemuBenchmarkProcess -Executable $paths.Qemu -Arguments $arguments -WorkingDirectory $repositoryRoot
        $processId = $process.Id
        $milestones = Wait-QemuBenchmarkMilestones -AdbPath $paths.Adb -Serial $serial -TimeoutSeconds $BootTimeoutSeconds
        if ($milestones.booted) {
            $hostIdle = Get-QemuHostMetrics -Process $process -SampleSeconds $HostSampleSeconds
            $launch = Start-QemuBenchmarkNeoNews -AdbPath $paths.Adb -Serial $serial -Config $config -TimeoutSeconds $NeoNewsTimeoutSeconds
            if ($launch.activityRunning -and $milestones.bootedAt) { $launch['bootToNeoNewsSeconds'] = [math]::Round(((Get-Date) - $milestones.bootedAt).TotalSeconds, 2) }
            $hostWorkload = if ($launch.activityRunning) { Get-QemuHostMetrics -Process $process -SampleSeconds $HostSampleSeconds } else { $null }
            $metrics = Get-QemuBenchmarkMetrics -AdbPath $paths.Adb -Serial $serial -Config $config
            $metrics.identityMatches = [string]$metrics.release -eq [string]$config.android.release -and [string]$metrics.apiLevel -eq [string]$config.android.apiLevel
            $stability = if ($launch.activityRunning) {
                Test-QemuBenchmarkStability -Process $process -AdbPath $paths.Adb -Serial $serial -ActivityComponent $launch.component -DurationSeconds $StabilitySeconds
            } else { [ordered]@{ durationSeconds = $StabilitySeconds; stable = $false; samples = @(); reason = 'activity-not-running' } }
        }
    }
    finally {
        if ($process) {
            $stopped = Stop-QemuBenchmarkProcess -Process $process -QmpPort ([int]$config.android.qemu.qmpPort) -TimeoutSeconds ([int]$config.timeouts.qemuShutdownSeconds)
            $process = $null
        }
    }
    $runs += [pscustomobject]@{
        iteration = $iteration
        processId = $processId
        adbReady = if ($milestones) { $milestones.adbReady } else { $false }
        adbReadySeconds = if ($milestones) { $milestones.adbReadySeconds } else { $null }
        booted = if ($milestones) { $milestones.booted } else { $false }
        bootSeconds = if ($milestones) { $milestones.bootSeconds } else { $null }
        adbToBootSeconds = if ($milestones) { $milestones.adbToBootSeconds } else { $null }
        stopped = $stopped
        app = $launch
        hostIdle = $hostIdle
        hostWorkload = $hostWorkload
        guest = $metrics
        stability = $stability
    }
    if ($iteration -lt $Iterations) { Start-Sleep -Seconds 2 }
}
$successful = @($runs | Where-Object { $_.booted -and $_.stopped -and $_.guest.identityMatches -and $_.app.launchSucceeded -and $_.app.activityRunning -and $_.stability.stable })
$bootValues = @($runs | Where-Object { $null -ne $_.bootSeconds } | ForEach-Object { [double]$_.bootSeconds })
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    backend = 'qemu-android-x86'
    acceleration = 'whpx'
    transport = $config.android.adb.transport
    serial = $serial
    persistentDisk = $paths.Disk
    iterations = $Iterations
    runs = @($runs)
    summary = [ordered]@{
        successfulIterations = $successful.Count
        bootMinSeconds = if ($bootValues.Count) { ($bootValues | Measure-Object -Minimum).Minimum } else { $null }
        bootAverageSeconds = if ($bootValues.Count) { [math]::Round(($bootValues | Measure-Object -Average).Average, 2) } else { $null }
        bootMaxSeconds = if ($bootValues.Count) { ($bootValues | Measure-Object -Maximum).Maximum } else { $null }
        stableAcrossAllRestarts = $successful.Count -eq $Iterations
        neoNewsLaunchSeconds = @($runs | Where-Object { $null -ne $_.app.launchSeconds } | ForEach-Object { [double]$_.app.launchSeconds })
        bootToNeoNewsSeconds = @($runs | Where-Object { $null -ne $_.app.bootToNeoNewsSeconds } | ForEach-Object { [double]$_.app.bootToNeoNewsSeconds })
        stabilitySeconds = $StabilitySeconds
    }
    status = if ($successful.Count -eq $Iterations) { 'qemu-runtime-stable' } else { 'incomplete' }
}
$json = $result | ConvertTo-Json -Depth 14
$reportFullPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $repositoryRoot $ReportPath }
$reportDirectory = Split-Path -Parent $reportFullPath
if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
Set-Content -LiteralPath $reportFullPath -Value $json -Encoding utf8
$json
if ($result.status -ne 'qemu-runtime-stable') { throw "QEMU benchmark incomplete: status=$($result.status)." }
