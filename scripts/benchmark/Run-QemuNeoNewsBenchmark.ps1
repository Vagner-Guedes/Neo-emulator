[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$Iterations = 3,
    [int]$BootTimeoutSeconds = 180,
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
if (-not (Test-Path -LiteralPath $paths.Qemu)) { throw "QEMU not found: $($paths.Qemu)" }
if (-not (Test-Path -LiteralPath $paths.Disk)) { throw "Persistent qcow2 not found: $($paths.Disk)" }
if (-not (Test-Path -LiteralPath $paths.Adb)) {
    if ($config.android.tooling.allowEnvironmentFallback) { $paths.Adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe' }
    else { throw "Configured ADB not found: $($paths.Adb)" }
}
if (-not (Test-Path -LiteralPath $paths.Adb)) { throw "ADB not found: $($paths.Adb)" }
if (-not (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\WinHvPlatform.dll'))) { throw 'WHPX library not found.' }

$serial = "$($config.android.adb.host):$($config.android.adb.hostPort)"
$arguments = New-QemuBenchmarkArguments -Config $config -DiskPath $paths.Disk -RepositoryRoot $repositoryRoot
$runs = @()
for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    $startedAt = Get-Date
    $process = Start-QemuBenchmarkProcess -Executable $paths.Qemu -Arguments $arguments -WorkingDirectory $repositoryRoot
    $processId = $process.Id
    $booted = Wait-QemuBenchmarkBoot -AdbPath $paths.Adb -Serial $serial -TimeoutSeconds $BootTimeoutSeconds
    $bootSeconds = if ($booted) { [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2) } else { $null }
    $metrics = if ($booted) { Get-QemuBenchmarkMetrics -AdbPath $paths.Adb -Serial $serial -Config $config } else { $null }
    $stopped = Stop-QemuBenchmarkProcess -Process $process -QmpPort ([int]$config.android.qemu.qmpPort) -TimeoutSeconds ([int]$config.timeouts.qemuShutdownSeconds)
    $runs += [pscustomobject]@{
        iteration = $iteration
        processId = $processId
        booted = $booted
        bootSeconds = $bootSeconds
        stopped = $stopped
        guest = $metrics
    }
    if ($iteration -lt $Iterations) { Start-Sleep -Seconds 2 }
}
$successful = @($runs | Where-Object { $_.booted -and $_.stopped })
$bootValues = @($runs | Where-Object { $null -ne $_.bootSeconds } | ForEach-Object { [double]$_.bootSeconds })
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    backend = 'qemu-android-x86'
    acceleration = 'whpx'
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
