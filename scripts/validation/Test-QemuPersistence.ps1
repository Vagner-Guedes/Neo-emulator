[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$BootTimeoutSeconds = 180,
    [string]$GuestPath = '/data/local/tmp/NeoNewsRuntime/persistence-marker.txt',
    [string]$ReportPath = 'reports/qemu-persistence.json'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration not found: $ConfigPath" }
$configPathFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$repositoryRoot = [System.IO.Directory]::GetParent([System.IO.Directory]::GetParent($configPathFull).FullName).FullName
$scriptRepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $scriptRepositoryRoot 'scripts\validation\ValidationEvidence.Common.ps1')
$reportFullPath = Initialize-ValidationReport -ReportPath (Resolve-ValidationReportPath -RepositoryRoot $repositoryRoot -ReportPath $ReportPath) -Validator 'Test-QemuPersistence'
$config = Get-Content -LiteralPath $configPathFull -Raw -Encoding utf8 | ConvertFrom-Json
. (Join-Path $PSScriptRoot '..\benchmark\QemuBenchmark.Common.ps1')
$paths = Resolve-QemuBenchmarkPaths -RepositoryRoot $repositoryRoot -Config $config
if (-not (Test-QemuBenchmarkNonEmptyFile $paths.Adb) -and $config.android.tooling.allowEnvironmentFallback) { $paths.Adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe' }
Assert-QemuBenchmarkProvisionedRuntime -Config $config -Paths $paths
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
$firstStopResult = [pscustomobject]@{
    Exited = $false
    QmpCapabilitiesSucceeded = $false
    QmpQuitSent = $false
    QmpQuitResponseSucceeded = $false
    QmpShutdownSucceeded = $false
    ForcedKill = $false
    QmpDetail = 'not-attempted'
}
$secondStopResult = [pscustomobject]@{
    Exited = $false
    QmpCapabilitiesSucceeded = $false
    QmpQuitSent = $false
    QmpQuitResponseSucceeded = $false
    QmpShutdownSucceeded = $false
    ForcedKill = $false
    QmpDetail = 'not-attempted'
}
$firstBooted = $false
$secondBooted = $false
$readBack = ''
try {
    $firstProcess = Start-QemuBenchmarkProcess -Executable $paths.Qemu -Arguments $arguments -WorkingDirectory $repositoryRoot
    $firstBooted = Wait-QemuBenchmarkBoot -AdbPath $paths.Adb -Serial $serial -TimeoutSeconds $BootTimeoutSeconds
    if (-not $firstBooted) { throw 'O primeiro boot não confirmou ADB e sys.boot_completed=1.' }
    # Split-Path is Windows-aware and turns an Android path such as
    # /sdcard/NeoNewsRuntime into a malformed host-style value. Keep the
    # guest path in POSIX form before passing it to adb shell.
    $lastSeparator = $GuestPath.LastIndexOf('/')
    $directory = if ($lastSeparator -gt 0) { $GuestPath.Substring(0, $lastSeparator) } else { '/' }
    $mkdir = Invoke-QemuBenchmarkAdb -AdbPath $paths.Adb -Serial $serial -Arguments @('shell', 'mkdir', '-p', $directory)
    if ($mkdir.ExitCode -ne 0) { throw "Não foi possível preparar o diretório persistente: $($mkdir.Text)" }
    $push = Invoke-QemuBenchmarkAdb -AdbPath $paths.Adb -Serial $serial -Arguments @('push', $markerFile, $GuestPath)
    if ($push.ExitCode -ne 0) { throw "Não foi possível gravar o marcador no guest: $($push.Text)" }
    $sync = Invoke-QemuBenchmarkAdb -AdbPath $paths.Adb -Serial $serial -Arguments @('shell', 'sync')
    if ($sync.ExitCode -ne 0) { throw "Não foi possível sincronizar o filesystem do guest: $($sync.Text)" }
    $firstStopResult = Stop-QemuBenchmarkProcess -Process $firstProcess -QmpPort ([int]$config.android.qemu.qmpPort) -TimeoutSeconds ([int]$config.timeouts.qemuShutdownSeconds)
    $firstStopped = $firstStopResult.Exited
    $firstProcess = $null
    if (-not $firstStopped) { throw 'O primeiro processo QEMU não encerrou.' }

    # Let the host-forwarded ADB socket close and discard the old TCP
    # transport before starting the second QEMU instance. Otherwise adb can
    # keep reporting the first guest while the new forward is being created.
    Start-Sleep -Seconds 3
    $null = Invoke-QemuBenchmarkAdbHost -AdbPath $paths.Adb -Arguments @('disconnect', $serial)
    $secondProcess = Start-QemuBenchmarkProcess -Executable $paths.Qemu -Arguments $arguments -WorkingDirectory $repositoryRoot
    $secondBooted = Wait-QemuBenchmarkBoot -AdbPath $paths.Adb -Serial $serial -TimeoutSeconds $BootTimeoutSeconds
    if ($secondBooted) { $readBack = (Invoke-QemuBenchmarkAdb -AdbPath $paths.Adb -Serial $serial -Arguments @('shell', 'cat', $GuestPath)).Text }
    $secondStopResult = Stop-QemuBenchmarkProcess -Process $secondProcess -QmpPort ([int]$config.android.qemu.qmpPort) -TimeoutSeconds ([int]$config.timeouts.qemuShutdownSeconds)
    $secondStopped = $secondStopResult.Exited
    $secondProcess = $null
}
finally {
    if ($firstProcess) { try { $firstStopResult = Stop-QemuBenchmarkProcess -Process $firstProcess -QmpPort ([int]$config.android.qemu.qmpPort) -TimeoutSeconds ([int]$config.timeouts.qemuShutdownSeconds); $firstStopped = $firstStopResult.Exited } catch { } }
    if ($secondProcess) { try { $secondStopResult = Stop-QemuBenchmarkProcess -Process $secondProcess -QmpPort ([int]$config.android.qemu.qmpPort) -TimeoutSeconds ([int]$config.timeouts.qemuShutdownSeconds); $secondStopped = $secondStopResult.Exited } catch { } }
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
    firstQmpCapabilitiesSucceeded = $firstStopResult.QmpCapabilitiesSucceeded
    firstQmpQuitSent = $firstStopResult.QmpQuitSent
    firstQmpShutdownSucceeded = $firstStopResult.QmpShutdownSucceeded
    firstQmpQuitResponseSucceeded = $firstStopResult.QmpQuitResponseSucceeded
    firstForcedKill = $firstStopResult.ForcedKill
    firstQmpDetail = $firstStopResult.QmpDetail
    secondBooted = $secondBooted
    secondShutdownSucceeded = $secondStopped
    secondQmpCapabilitiesSucceeded = $secondStopResult.QmpCapabilitiesSucceeded
    secondQmpQuitSent = $secondStopResult.QmpQuitSent
    secondQmpShutdownSucceeded = $secondStopResult.QmpShutdownSucceeded
    secondQmpQuitResponseSucceeded = $secondStopResult.QmpQuitResponseSucceeded
    secondForcedKill = $secondStopResult.ForcedKill
    secondQmpDetail = $secondStopResult.QmpDetail
    markerValue = $markerValue
    readBack = $readBack.Trim()
    markerPersisted = $persisted
    status = if ($persisted -and $firstStopped -and $secondStopped -and $firstStopResult.QmpShutdownSucceeded -and $secondStopResult.QmpShutdownSucceeded) { 'validated' } else { 'not-validated' }
}
$json = $result | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $reportFullPath -Value $json -Encoding utf8
$json
if ($result.status -ne 'validated') { throw "A persistência do qcow2 não foi validada: status=$($result.status). Consulte $reportFullPath." }
