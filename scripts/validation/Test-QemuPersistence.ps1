[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$BootTimeoutSeconds = 180,
    [string]$GuestPath = '/sdcard/NeoNewsRuntime/persistence-marker.txt',
    [string]$ReportPath = 'reports/qemu-persistence.json'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration not found: $ConfigPath" }
$configPathFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$repositoryRoot = [System.IO.Directory]::GetParent([System.IO.Directory]::GetParent($configPathFull).FullName).FullName
$config = Get-Content -LiteralPath $configPathFull -Raw -Encoding utf8 | ConvertFrom-Json
. (Join-Path $PSScriptRoot '..\benchmark\QemuBenchmark.Common.ps1')
$paths = Resolve-QemuBenchmarkPaths -RepositoryRoot $repositoryRoot -Config $config
if (-not (Test-Path -LiteralPath $paths.Qemu)) { throw "QEMU not found: $($paths.Qemu)" }
if (-not (Test-Path -LiteralPath $paths.Disk)) { throw "Persistent qcow2 not found: $($paths.Disk)" }
if (-not (Test-Path -LiteralPath $paths.Adb)) {
    if ($config.android.tooling.allowEnvironmentFallback) { $paths.Adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe' }
    else { throw "Configured ADB not found: $($paths.Adb)" }
}
if (-not (Test-Path -LiteralPath $paths.Adb)) { throw "ADB not found: $($paths.Adb)" }
if (-not (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\WinHvPlatform.dll'))) { throw 'WHPX library not found.' }
if ($GuestPath -notmatch '^/[^\r\n;]+$') { throw "GuestPath precisa ser um caminho absoluto Android sem quebras de linha: $GuestPath" }

$serial = "$($config.android.adb.host):$($config.android.adb.hostPort)"
$arguments = New-QemuBenchmarkArguments -Config $config -DiskPath $paths.Disk -RepositoryRoot $repositoryRoot
$markerFile = [System.IO.Path]::GetTempFileName()
$markerValue = "neonews-runtime-persistence-$([guid]::NewGuid().ToString('N'))"
[System.IO.File]::WriteAllText($markerFile, $markerValue)
$firstProcess = $null
$secondProcess = $null
$firstStopped = $false
$secondStopped = $false
$firstBooted = $false
$secondBooted = $false
$readBack = ''
try {
    $firstProcess = Start-QemuBenchmarkProcess -Executable $paths.Qemu -Arguments $arguments -WorkingDirectory $repositoryRoot
    $firstBooted = Wait-QemuBenchmarkBoot -AdbPath $paths.Adb -Serial $serial -TimeoutSeconds $BootTimeoutSeconds
    if (-not $firstBooted) { throw 'O primeiro boot não confirmou ADB e sys.boot_completed=1.' }
    $directory = Split-Path -Parent $GuestPath -ErrorAction Stop
    $mkdir = Invoke-QemuBenchmarkAdb -AdbPath $paths.Adb -Serial $serial -Arguments @('shell', 'mkdir', '-p', $directory)
    if ($mkdir.ExitCode -ne 0) { throw "Não foi possível preparar o diretório persistente: $($mkdir.Text)" }
    $push = & $paths.Adb -s $serial push $markerFile $GuestPath 2>&1
    $pushCode = $LASTEXITCODE
    if ($pushCode -ne 0) { throw "Não foi possível gravar o marcador no guest: $(($push | Out-String).Trim())" }
    $firstStopped = Stop-QemuBenchmarkProcess -Process $firstProcess -QmpPort ([int]$config.android.qemu.qmpPort) -TimeoutSeconds ([int]$config.timeouts.qemuShutdownSeconds)
    $firstProcess = $null
    if (-not $firstStopped) { throw 'O primeiro processo QEMU não encerrou.' }

    $secondProcess = Start-QemuBenchmarkProcess -Executable $paths.Qemu -Arguments $arguments -WorkingDirectory $repositoryRoot
    $secondBooted = Wait-QemuBenchmarkBoot -AdbPath $paths.Adb -Serial $serial -TimeoutSeconds $BootTimeoutSeconds
    if ($secondBooted) { $readBack = (Invoke-QemuBenchmarkAdb -AdbPath $paths.Adb -Serial $serial -Arguments @('shell', 'cat', $GuestPath)).Text }
    $secondStopped = Stop-QemuBenchmarkProcess -Process $secondProcess -QmpPort ([int]$config.android.qemu.qmpPort) -TimeoutSeconds ([int]$config.timeouts.qemuShutdownSeconds)
    $secondProcess = $null
}
finally {
    if ($firstProcess) { try { $firstStopped = Stop-QemuBenchmarkProcess -Process $firstProcess -QmpPort ([int]$config.android.qemu.qmpPort) -TimeoutSeconds ([int]$config.timeouts.qemuShutdownSeconds) } catch { } }
    if ($secondProcess) { try { $secondStopped = Stop-QemuBenchmarkProcess -Process $secondProcess -QmpPort ([int]$config.android.qemu.qmpPort) -TimeoutSeconds ([int]$config.timeouts.qemuShutdownSeconds) } catch { } }
    Remove-Item -LiteralPath $markerFile -Force -ErrorAction SilentlyContinue
}

$persisted = $secondBooted -and $readBack.Trim() -eq $markerValue
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    backend = 'qemu-android-x86'
    acceleration = 'whpx'
    transport = $config.android.adb.transport
    serial = $serial
    persistentDisk = $paths.Disk
    guestPath = $GuestPath
    firstBooted = $firstBooted
    firstShutdownSucceeded = $firstStopped
    secondBooted = $secondBooted
    secondShutdownSucceeded = $secondStopped
    markerPersisted = $persisted
    status = if ($persisted -and $firstStopped -and $secondStopped) { 'validated' } else { 'not-validated' }
}
$json = $result | ConvertTo-Json -Depth 10
$reportFullPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $repositoryRoot $ReportPath }
$reportDirectory = Split-Path -Parent $reportFullPath
if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
Set-Content -LiteralPath $reportFullPath -Value $json -Encoding utf8
$json
if ($result.status -ne 'validated') { throw "A persistência do qcow2 não foi validada: status=$($result.status). Consulte $reportFullPath." }
