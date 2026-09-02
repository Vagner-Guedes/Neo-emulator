[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$BootTimeoutSeconds = 180,
    [int]$NeoNewsTimeoutSeconds = 120,
    [int]$StabilitySeconds = 60,
    [int]$HostSampleSeconds = 2,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration not found: $ConfigPath" }
$configPathFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$repositoryRoot = [System.IO.Directory]::GetParent([System.IO.Directory]::GetParent($configPathFull).FullName).FullName
. (Join-Path $repositoryRoot 'scripts\validation\ValidationEvidence.Common.ps1')
$reportFullPath = Initialize-ValidationReport -ReportPath (Resolve-ValidationReportPath -RepositoryRoot $repositoryRoot -ReportPath $ReportPath) -Validator 'Measure-QemuAndroidRuntime'
$config = Get-Content -LiteralPath $configPathFull -Raw -Encoding utf8 | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'QemuBenchmark.Common.ps1')
$paths = Resolve-QemuBenchmarkPaths -RepositoryRoot $repositoryRoot -Config $config
if (-not (Test-QemuBenchmarkNonEmptyFile $paths.Adb) -and $config.android.tooling.allowEnvironmentFallback) { $paths.Adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe' }
Assert-QemuBenchmarkProvisionedRuntime -Config $config -Paths $paths
if (-not (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\WinHvPlatform.dll'))) { throw 'WHPX library not found.' }

$serial = "$($config.android.adb.host):$($config.android.adb.hostPort)"
$arguments = New-QemuBenchmarkArguments -Config $config -DiskPath $paths.Disk -RepositoryRoot $repositoryRoot
$startedAt = Get-Date
$process = Start-QemuBenchmarkProcess -Executable $paths.Qemu -Arguments $arguments -WorkingDirectory $repositoryRoot
$processId = $process.Id
$milestones = $null
$launch = $null
$metrics = $null
$hostIdle = $null
$hostWorkload = $null
$stability = $null
$stopped = $false
try {
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
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    backend = 'qemu-android-x86'
    acceleration = 'whpx'
    qemu = [ordered]@{ executable = $paths.Qemu; processId = $processId; disk = $paths.Disk; gpu = $config.android.qemu.gpu; stopped = $stopped }
    adb = [ordered]@{ serial = $serial; transport = $config.android.adb.transport; ready = $milestones.adbReady; readySeconds = $milestones.adbReadySeconds; booted = $milestones.booted; bootSeconds = $milestones.bootSeconds; adbToBootSeconds = $milestones.adbToBootSeconds }
    app = $launch
    host = [ordered]@{ idle = $hostIdle; neonewsWorkload = $hostWorkload }
    guest = $metrics
    stability = $stability
    status = if ($milestones.booted -and $launch.launchSucceeded -and $launch.activityRunning -and $stability.stable -and $stopped) { 'baseline-collected' } elseif (-not $milestones.booted) { 'boot-timeout' } elseif (-not $stopped) { 'shutdown-failed' } else { 'neonews-or-stability-failed' }
}
$json = $result | ConvertTo-Json -Depth 12
if ($ReportPath) {
    Set-Content -LiteralPath $reportFullPath -Value $json -Encoding utf8
}
$json
if ($result.status -ne 'baseline-collected') { throw "QEMU benchmark failed: status=$($result.status)." }
