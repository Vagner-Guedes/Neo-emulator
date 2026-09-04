[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [ValidateSet('Matrix', 'ColdBoots')]
    [string]$Mode = 'Matrix',
    [int]$TimeoutSeconds = 240,
    [int]$ColdBootCount = 3,
    [int]$CpuCoresOverride = 0,
    [string]$CpuModelOverride = '',
    [string]$ReportPath = 'reports/boot-diagnostics.json',
    [string]$WhpxReportPath = 'reports/whpx-diagnostics.json',
    [switch]$KeepOverlays
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
. (Join-Path $RepositoryRoot 'scripts\benchmark\QemuBenchmark.Common.ps1')

$configPath = Join-Path $RepositoryRoot 'config\runtime.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
$resolve = {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot ($Path -replace '/', '\')))
}
$qemuPath = & $resolve $config.android.qemu.executable
$qemuImgPath = Join-Path (Split-Path -Parent $qemuPath) 'qemu-img.exe'
$adbPath = & $resolve (Join-Path $config.android.tooling.sdkRoot $config.android.tooling.adbRelativePath)
$rootDisk = & $resolve $config.android.qemu.disk
$androidImage = & $resolve $config.android.qemu.androidImage
$reportFullPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $RepositoryRoot $ReportPath }
$whpxReportFullPath = if ([System.IO.Path]::IsPathRooted($WhpxReportPath)) { $WhpxReportPath } else { Join-Path $RepositoryRoot $WhpxReportPath }
New-Item -ItemType Directory -Path (Split-Path -Parent $reportFullPath), (Split-Path -Parent $whpxReportFullPath) -Force | Out-Null

function Invoke-QemuImageJson {
    param([string]$Command, [string]$ImagePath)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $qemuImgPath $Command '--output=json' $ImagePath 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($exitCode -ne 0) { throw "qemu-img $Command falhou: exit=$exitCode; output=$(($raw | Out-String).Trim())" }
    return (($raw | Out-String).Trim() | ConvertFrom-Json)
}

function Get-QemuHostState {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $optionalFeatures = @()
    foreach ($featureName in @('Microsoft-Hyper-V-All', 'HypervisorPlatform', 'VirtualMachinePlatform')) {
        try {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
            $optionalFeatures += [ordered]@{ name = $featureName; state = [string]$feature.State }
        }
        catch { $optionalFeatures += [ordered]@{ name = $featureName; state = 'unavailable'; error = $_.Exception.Message } }
    }
    [ordered]@{
        capturedAt = (Get-Date).ToUniversalTime().ToString('o')
        windows = if ($os) { [ordered]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber; architecture = $os.OSArchitecture } } else { $null }
        hypervisorPresent = if ($computer) { [bool]$computer.HypervisorPresent } else { $null }
        virtualizationFirmwareEnabled = if ($cpu) { $cpu.VirtualizationFirmwareEnabled } else { $null }
        vmMonitorModeExtensions = if ($cpu) { $cpu.VMMonitorModeExtensions } else { $null }
        secondLevelAddressTranslation = if ($cpu) { $cpu.SecondLevelAddressTranslationExtensions } else { $null }
        cpu = if ($cpu) { [ordered]@{ name = $cpu.Name; manufacturer = $cpu.Manufacturer; cores = $cpu.NumberOfCores; logicalProcessors = $cpu.NumberOfLogicalProcessors } } else { $null }
        optionalFeatures = $optionalFeatures
    }
}

function New-BootOverlay {
    param([string]$Path)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $qemuImgPath 'create' '-f' 'qcow2' '-F' 'qcow2' '-b' $rootDisk $Path 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($exitCode -ne 0) { throw "Não foi possível criar overlay descartável: exit=$exitCode; output=$(($raw | Out-String).Trim())" }
}

function Ensure-BootAdbRoot {
    param(
        [string]$Serial,
        [int]$ServerPort
    )

    $rootRequest = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $Serial -Arguments @('root') -ServerPort $ServerPort -TimeoutSeconds 30
    $deadline = (Get-Date).AddSeconds(45)
    $state = $null
    do {
        $state = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $Serial -Arguments @('get-state') -ServerPort $ServerPort
        if ($state.Text -match '(?im)^device$') { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    $identity = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $Serial -Arguments @('shell', 'id') -ServerPort $ServerPort
    [ordered]@{
        request = Get-TextResult $rootRequest
        state = Get-TextResult $state
        identity = Get-TextResult $identity
        ready = $state.Text -match '(?im)^device$' -and $identity.Text -match 'uid=0\(root\)'
    }
}

function Wait-BootAdbSuccess {
    param(
        [string]$Serial,
        [int]$ServerPort,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))
    $last = $null
    do {
        $last = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $Serial -Arguments $Arguments -ServerPort $ServerPort
        if ($last.ExitCode -eq 0 -and $last.Text -notmatch '(?i)Error while|NullPointerException|Operation not permitted|device offline') { return $last }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $last
}

function Sync-BootGuestClock {
    param(
        [string]$Serial,
        [int]$ServerPort,
        [string]$Timezone
    )

    $timezoneResult = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $Serial -Arguments @('shell', 'setprop', 'persist.sys.timezone', $Timezone) -ServerPort $ServerPort
    $autoTimeResult = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $Serial -Arguments @('shell', 'settings', 'put', 'global', 'auto_time', '0') -ServerPort $ServerPort
    $autoZoneResult = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $Serial -Arguments @('shell', 'settings', 'put', 'global', 'auto_time_zone', '0') -ServerPort $ServerPort
    $hostBefore = [DateTimeOffset]::Now
    $dateValue = $hostBefore.LocalDateTime.ToString('MMddHHmmyyyy.ss', [Globalization.CultureInfo]::InvariantCulture)
    $dateResult = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $Serial -Arguments @('shell', 'date', $dateValue) -ServerPort $ServerPort
    $guestEpochResult = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $Serial -Arguments @('shell', 'date', '+%s') -ServerPort $ServerPort
    $guestTimezoneResult = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $Serial -Arguments @('shell', 'getprop', 'persist.sys.timezone') -ServerPort $ServerPort
    $hostAfter = [DateTimeOffset]::Now
    $guestEpoch = $null
    $parsedGuestEpoch = 0L
    if ([long]::TryParse($guestEpochResult.Text.Trim(), [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedGuestEpoch)) { $guestEpoch = $parsedGuestEpoch }
    $skew = if ($null -ne $guestEpoch) { $guestEpoch - $hostAfter.ToUnixTimeSeconds() } else { $null }
    [ordered]@{
        timezone = $guestTimezoneResult.Text.Trim()
        expectedTimezone = $Timezone
        hostEpoch = $hostAfter.ToUnixTimeSeconds()
        guestEpoch = $guestEpoch
        skewSeconds = $skew
        dateValue = $dateValue
        commands = [ordered]@{
            timezone = Get-TextResult $timezoneResult
            autoTime = Get-TextResult $autoTimeResult
            autoTimeZone = Get-TextResult $autoZoneResult
            date = Get-TextResult $dateResult
        }
        validated = $timezoneResult.ExitCode -eq 0 -and $autoTimeResult.ExitCode -eq 0 -and $autoZoneResult.ExitCode -eq 0 -and $dateResult.ExitCode -eq 0 -and $guestTimezoneResult.Text.Trim().Equals($Timezone, [StringComparison]::OrdinalIgnoreCase) -and $null -ne $guestEpoch -and [math]::Abs([double]$skew) -le [int]$config.runtime.maxClockSkewSeconds
    }
}

function Start-BootQemu {
    param([string[]]$Arguments, [string]$StdoutPath, [string]$StderrPath)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $qemuPath
    $startInfo.WorkingDirectory = $RepositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (($Arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + $value.Replace('"', '\"') + '"' } else { $value }
    }) -join ' ')
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Não foi possível iniciar QEMU com aceleração $($Arguments[$Arguments.IndexOf('-accel') + 1])." }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    [pscustomobject]@{ Process = $process; StdoutTask = $stdoutTask; StderrTask = $stderrTask; StdoutPath = $StdoutPath; StderrPath = $StderrPath }
}

function Stop-BootQemu {
    param($Started, [int]$QmpPort)
    if ($null -eq $Started) { return [ordered]@{ exited = $true; forcedKill = $false; processExitCode = $null; qmp = $null } }
    $processExitCode = $null
    try { if ($Started.Process.HasExited) { $processExitCode = $Started.Process.ExitCode } } catch { }
    $stop = Stop-QemuBenchmarkProcess -Process $Started.Process -QmpPort $QmpPort -TimeoutSeconds 20
    try { if ($null -eq $processExitCode -and $Started.Process.HasExited) { $processExitCode = $Started.Process.ExitCode } } catch { }
    try { $Started.StdoutTask.GetAwaiter().GetResult() | Set-Content -LiteralPath $Started.StdoutPath -Encoding utf8 } catch { }
    try { $Started.StderrTask.GetAwaiter().GetResult() | Set-Content -LiteralPath $Started.StderrPath -Encoding utf8 } catch { }
    try { $Started.Process.Dispose() } catch { }
    [ordered]@{ exited = [bool]$stop.Exited; forcedKill = [bool]$stop.ForcedKill; processExitCode = $processExitCode; qmp = $stop }
}

function Get-TextResult {
    param($Result)
    [ordered]@{ exitCode = $Result.ExitCode; text = $Result.Text }
}

function Invoke-BoundedLogcat {
    param([string]$Serial, [int]$ServerPort, [int]$TimeoutMilliseconds = 15000)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $adbPath
    $startInfo.WorkingDirectory = $RepositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $arguments = @('-P', $ServerPort, '-s', $Serial, 'logcat', '-d', '-v', 'threadtime')
    $startInfo.Arguments = (($arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + $value.Replace('"', '\"') + '"' } else { $value }
    }) -join ' ')
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { return [ordered]@{ exitCode = -1; timedOut = $false; text = ''; error = 'adb logcat não iniciou' } }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        $timedOut = $true
        try { $process.Kill() } catch { }
        $null = $process.WaitForExit(5000)
    }
    $stdout = ''
    $stderr = ''
    try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch { }
    try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch { }
    $exitCode = $null
    try { $exitCode = $process.ExitCode } catch { }
    try { $process.Dispose() } catch { }
    [ordered]@{ exitCode = $exitCode; timedOut = $timedOut; text = $stdout.Trim(); error = $stderr.Trim() }
}

function Get-LogMatches {
    param([string]$Text)
    $lines = @($Text -split "`r?`n" | Where-Object { $_ -match '(?i)NativeBridge|Houdini|linker|UnsatisfiedLinkError|crash' })
    [ordered]@{ count = $lines.Count; lines = @($lines | Select-Object -First 250) }
}

function Invoke-BootRun {
    param(
        [string]$Acceleration,
        [int]$Iteration,
        [bool]$ValidateNeoNews,
        [string]$EvidenceRoot
    )

    # 5037 is the user/global server and 5038 is the product endpoint. Use a
    # high, test-owned port range so a host service cannot be mistaken for an
    # ADB server during the matrix.
    $adbServerPort = 51239 + (($Iteration - 1) * 3) + $(if ($Acceleration -eq 'tcg') { 1 } else { 0 })
    $adbHostPort = 5569 + (($Iteration - 1) * 3) + $(if ($Acceleration -eq 'tcg') { 1 } else { 0 })
    $qmpPort = 4462 + (($Iteration - 1) * 3) + $(if ($Acceleration -eq 'tcg') { 1 } else { 0 })
    $serial = "127.0.0.1:$adbHostPort"
    $overlayPath = Join-Path $EvidenceRoot "$Acceleration-overlay.qcow2"
    $stdoutPath = Join-Path $EvidenceRoot "$Acceleration-qemu.stdout.log"
    $stderrPath = Join-Path $EvidenceRoot "$Acceleration-qemu.stderr.log"
    New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
    New-BootOverlay -Path $overlayPath

    $testConfig = $config | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $testConfig.android.qemu.showWindow = $false
        $testConfig.android.qemu.qmpPort = $qmpPort
        if ($CpuCoresOverride -gt 0) { $testConfig.android.qemu.cpuCores = $CpuCoresOverride }
        if (-not [string]::IsNullOrWhiteSpace($CpuModelOverride)) { $testConfig.android.qemu | Add-Member -NotePropertyName cpuModel -NotePropertyValue $CpuModelOverride.Trim() -Force }
    $testConfig.android.adb.hostPort = $adbHostPort
    $testConfig.android.adb.serverPort = $adbServerPort
    $arguments = New-QemuBenchmarkArguments -Config $testConfig -DiskPath $overlayPath -RepositoryRoot $RepositoryRoot -Acceleration $Acceleration
    $startedAt = (Get-Date).ToUniversalTime()
    $started = $null
    $processId = $null
    $processExitCode = $null
    $adbStarted = $false
    $observations = New-Object System.Collections.Generic.List[object]
    $firstAdbSeen = $null
    $firstDeviceState = $null
    $bootCompleted = $null
    $lastDeviceAt = $null
    $deviceProbes = 0
    $setupFlags = $null
    $rootEvidence = $null
    $clockEvidence = $null
    $preLaunchStop = $null
    $bootProperty = $null
    $pmResult = $null
    $settingsGlobal = $null
    $settingsSecure = $null
    $neoNews = $null
    $logcat = ''
    $launchActivity = "$($config.neonews.packageName)/$($config.neonews.launchActivity)"
    $classification = 'GUEST_OR_IMAGE_BOOT_FAILURE'

    try {
        $adbStart = Invoke-QemuBenchmarkAdbHost -AdbPath $adbPath -Arguments @('start-server') -ServerPort $adbServerPort
        $adbStarted = $adbStart.ExitCode -eq 0
        if (-not $adbStarted) { throw "Servidor ADB privado não iniciou: $($adbStart.Text)" }
        $started = Start-BootQemu -Arguments $arguments -StdoutPath $stdoutPath -StderrPath $stderrPath
        $processId = $started.Process.Id
        $bootDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $lastConnectAt = [DateTime]::MinValue
        while ((Get-Date) -lt $bootDeadline) {
            if ((Get-Date) -gt $lastConnectAt.AddSeconds(2)) {
                $connect = Invoke-QemuBenchmarkAdbHost -AdbPath $adbPath -Arguments @('connect', $serial) -ServerPort $adbServerPort
                $lastConnectAt = Get-Date
            }
            $stateResult = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $serial -Arguments @('get-state') -ServerPort $adbServerPort
            $stateText = $stateResult.Text.Trim()
            $now = (Get-Date).ToUniversalTime()
            $observations.Add([ordered]@{ at = $now.ToString('o'); state = $stateText; exitCode = $stateResult.ExitCode })
            if (-not $firstAdbSeen -and -not [string]::IsNullOrWhiteSpace($stateText)) { $firstAdbSeen = $now }
            if ($stateText -match '(?im)^device$') {
                if (-not $firstDeviceState) { $firstDeviceState = $now }
                if ($null -eq $lastDeviceAt -or $now - $lastDeviceAt -ge [TimeSpan]::FromSeconds(2)) { $deviceProbes++ }
                $lastDeviceAt = $now
                if (-not $setupFlags) {
                    $globalWrite = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'settings', 'put', 'global', 'device_provisioned', '1') -ServerPort $adbServerPort
                    $secureWrite = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'settings', 'put', 'secure', 'user_setup_complete', '1') -ServerPort $adbServerPort
                    $setupFlags = [ordered]@{ globalWrite = Get-TextResult $globalWrite; secureWrite = Get-TextResult $secureWrite }
                }
                if ($deviceProbes -ge 3) {
                    $bootResult = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'getprop', 'sys.boot_completed') -ServerPort $adbServerPort
                    $bootProperty = $bootResult.Text.Trim()
                    if ($bootProperty -eq '1') { $bootCompleted = $now; break }
                }
            }
            else {
                $deviceProbes = 0
                $lastDeviceAt = $null
            }
            Start-Sleep -Seconds 2
        }

        if ($bootCompleted) {
            $rootEvidence = Ensure-BootAdbRoot -Serial $serial -ServerPort $adbServerPort
            if (-not $rootEvidence.ready) { throw "ADB root não foi confirmado: $($rootEvidence | ConvertTo-Json -Compress -Depth 8)" }
            Start-Sleep -Seconds 5
            $pmPackages = Wait-BootAdbSuccess -Serial $serial -ServerPort $adbServerPort -Arguments @('shell', 'pm', 'list', 'packages')
            $pmAndroid = Wait-BootAdbSuccess -Serial $serial -ServerPort $adbServerPort -Arguments @('shell', 'pm', 'path', 'android')
            $global = Wait-BootAdbSuccess -Serial $serial -ServerPort $adbServerPort -Arguments @('shell', 'settings', 'list', 'global')
            $secure = Wait-BootAdbSuccess -Serial $serial -ServerPort $adbServerPort -Arguments @('shell', 'settings', 'list', 'secure')
            $postRootGlobal = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'settings', 'put', 'global', 'device_provisioned', '1') -ServerPort $adbServerPort
            $postRootSecure = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'settings', 'put', 'secure', 'user_setup_complete', '1') -ServerPort $adbServerPort
            $setupFlags.postRoot = [ordered]@{ globalWrite = Get-TextResult $postRootGlobal; secureWrite = Get-TextResult $postRootSecure }
            $clockEvidence = Sync-BootGuestClock -Serial $serial -ServerPort $adbServerPort -Timezone ([string]$config.runtime.timezone)
            if (-not $clockEvidence.validated) { throw "Relógio do guest não foi homologado: $($clockEvidence | ConvertTo-Json -Compress -Depth 8)" }
            $pmResult = [ordered]@{ packages = Get-TextResult $pmPackages; androidPath = Get-TextResult $pmAndroid; ready = $pmPackages.ExitCode -eq 0 -and $pmPackages.Text -match '(?i)package:' -and $pmAndroid.ExitCode -eq 0 -and $pmAndroid.Text -match '(?i)package:' }
            $settingsGlobal = Get-TextResult $global
            $settingsSecure = Get-TextResult $secure
            $settingsReady = $global.ExitCode -eq 0 -and $secure.ExitCode -eq 0 -and $global.Text -notmatch '(?i)error' -and $secure.Text -notmatch '(?i)error'
            $nativeBridge = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'getprop', 'ro.dalvik.vm.native.bridge') -ServerPort $adbServerPort
            $locale = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'getprop', 'persist.sys.locale') -ServerPort $adbServerPort
            $packages = $pmPackages.Text
            $packageEvidence = [ordered]@{
                neoNews = $packages -match '(?i)com\.in9midia\.neonews\.player'
                webView = $packages -match '(?i)com\.google\.android\.webview'
                rhvoice = $packages -match '(?i)com\.github\.olga_yakovleva\.rhvoice\.android'
                houdiniLogExpected = $true
            }
            $neoPath = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'pm', 'path', $config.neonews.packageName) -ServerPort $adbServerPort
            $neoDump = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'dumpsys', 'package', $config.neonews.packageName) -ServerPort $adbServerPort
            $primaryCpuAbi = [regex]::Match($neoDump.Text, '(?im)primaryCpuAbi=([^\s\r\n]+)').Groups[1].Value
            $neoNews = [ordered]@{ packagePresent = $neoPath.ExitCode -eq 0 -and $neoPath.Text -match '(?i)package:'; primaryCpuAbi = $primaryCpuAbi; expectedAbi = 'armeabi-v7a'; activity = $launchActivity; launch = $null; stable60s = $null }
            if ($ValidateNeoNews -and $neoNews.packagePresent) {
                $preLaunchStop = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'am', 'force-stop', $config.neonews.packageName) -ServerPort $adbServerPort
                Start-Sleep -Seconds 3
                $launchResult = Invoke-QemuBenchmarkAdb -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'am', 'start', '-n', $launchActivity) -ServerPort $adbServerPort
                $stable = Test-QemuBenchmarkStability -Process $started.Process -AdbPath $adbPath -Serial $serial -ActivityComponent $launchActivity -DurationSeconds 60 -PollSeconds 5 -ServerPort $adbServerPort
                $neoNews.launch = [ordered]@{ result = Get-TextResult $launchResult; succeeded = ($launchResult.ExitCode -eq 0 -or $launchResult.Text -match '(?im)Starting: Intent') -and $launchResult.Text -notmatch '(?im)(^|[\r\n])\s*Error:|ActivityNotFound|does not exist|Unable to resolve Intent' }
                $neoNews.stable60s = $stable
            }
            $logResult = Invoke-BoundedLogcat -Serial $serial -ServerPort $adbServerPort
            $logcat = $logResult.text
            $classification = if ($ValidateNeoNews -and $neoNews.launch.succeeded -and $neoNews.stable60s.stable -and $neoNews.primaryCpuAbi -eq 'armeabi-v7a') { 'BOOT_RELIABILITY_PASS' } else { 'BOOTED_GUEST_VALIDATION_INCOMPLETE' }
            if ($Mode -eq 'Matrix' -and $Acceleration -eq 'tcg') { $classification = 'TCG_DIAGNOSTIC_BOOT' }
        }
        else {
            $logResult = Invoke-BoundedLogcat -Serial $serial -ServerPort $adbServerPort
            $logcat = $logResult.text
            $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding utf8 } else { '' }
            $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -Encoding utf8 } else { '' }
            if ($Acceleration -eq 'whpx' -and "$stderr`n$stdout" -match '(?i)WHPX.*Unexpected VP exit|Unexpected VP exit code') { $classification = 'WHPX_HOST_PATH_FAILURE' }
        }
    }
    catch {
        $classification = if ($Acceleration -eq 'whpx' -and $_.Exception.Message -match '(?i)WHPX|Unexpected VP|guest memory|host doesn') { 'WHPX_HOST_PATH_FAILURE' } else { 'GUEST_OR_IMAGE_BOOT_FAILURE' }
        $observations.Add([ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o'); exception = $_.Exception.ToString() })
    }
    finally {
        $stop = Stop-BootQemu -Started $started -QmpPort $qmpPort
        if ($adbStarted) { $null = Invoke-QemuBenchmarkAdbHost -AdbPath $adbPath -Arguments @('kill-server') -ServerPort $adbServerPort }
    }

    $overlayCheck = $null
    if (Test-Path -LiteralPath $overlayPath) {
        try { $overlayCheck = Invoke-QemuImageJson -Command 'check' -ImagePath $overlayPath } catch { $overlayCheck = [ordered]@{ error = $_.Exception.Message } }
    }
    $stderrText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding utf8 } else { '' }
    $stdoutText = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -Encoding utf8 } else { '' }
    $qemuCombined = "$stdoutText`n$stderrText"
    if ($Acceleration -eq 'whpx' -and $qemuCombined -match '(?i)WHPX.*Unexpected VP exit|Unexpected VP exit code') {
        $classification = 'WHPX_HOST_PATH_FAILURE'
    }
    $logMatches = Get-LogMatches -Text $logcat
    $qemuMatches = Get-LogMatches -Text $qemuCombined
    if ($null -ne $stop.processExitCode) { $processExitCode = $stop.processExitCode }
    $result = [ordered]@{
        acceleration = $Acceleration
        iteration = $Iteration
        cpuCores = [int]$testConfig.android.qemu.cpuCores
        cpuModel = if ($testConfig.android.qemu.cpuModel) { [string]$testConfig.android.qemu.cpuModel } else { $null }
        classification = $classification
        startedAt = $startedAt.ToString('o')
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
        qemu = [ordered]@{ executable = $qemuPath; processId = $processId; exitCode = $processExitCode; arguments = $arguments; stdoutPath = $stdoutPath; stderrPath = $stderrPath; qemuMatches = $qemuMatches; stop = $stop }
        adb = [ordered]@{ serverPort = $adbServerPort; serial = $serial; hostPort = $adbHostPort; firstAdbSeen = if ($firstAdbSeen) { $firstAdbSeen.ToString('o') } else { $null }; firstDeviceState = if ($firstDeviceState) { $firstDeviceState.ToString('o') } else { $null }; observations = $observations.ToArray() }
        boot = [ordered]@{ bootCompleted = if ($bootCompleted) { $bootCompleted.ToString('o') } else { $null }; sysBootCompleted = $bootProperty; consecutiveDeviceProbes = $deviceProbes; setupFlags = $setupFlags; packageManager = $pmResult; settingsGlobal = $settingsGlobal; settingsSecure = $settingsSecure; androidReady = [bool]($bootCompleted -and $deviceProbes -ge 3 -and $pmResult.ready -and $settingsGlobal.exitCode -eq 0 -and $settingsSecure.exitCode -eq 0) }
        guest = [ordered]@{ root = $rootEvidence; clock = $clockEvidence; setupAfterRoot = if ($setupFlags.postRoot) { $setupFlags.postRoot } else { $null }; preLaunchStop = if ($preLaunchStop) { Get-TextResult $preLaunchStop } else { $null }; nativeBridgeProperty = if ($nativeBridge) { $nativeBridge.Text.Trim() } else { $null }; locale = if ($locale) { $locale.Text.Trim() } else { $null }; packages = $packageEvidence; neoNews = $neoNews }
        logcat = [ordered]@{ result = $logResult; matches = $logMatches }
        overlay = [ordered]@{ path = $overlayPath; check = $overlayCheck }
    }
    if (-not $KeepOverlays) { try { Remove-Item -LiteralPath $overlayPath -Force -ErrorAction Stop } catch { } }
    return $result
}

$rootInfoBefore = Invoke-QemuImageJson -Command 'info' -ImagePath $rootDisk
$rootCheckBefore = Invoke-QemuImageJson -Command 'check' -ImagePath $rootDisk
$rootHashBefore = (Get-FileHash -LiteralPath $rootDisk -Algorithm SHA256).Hash
$hostState = Get-QemuHostState
$evidenceRoot = Join-Path $RepositoryRoot ("tmp\boot-reliability\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$runs = New-Object System.Collections.Generic.List[object]
if ($Mode -eq 'Matrix') {
    $runs.Add((Invoke-BootRun -Acceleration 'whpx' -Iteration 1 -ValidateNeoNews $true -EvidenceRoot $evidenceRoot))
    $runs.Add((Invoke-BootRun -Acceleration 'tcg' -Iteration 1 -ValidateNeoNews $false -EvidenceRoot $evidenceRoot))
}
else {
    for ($iteration = 1; $iteration -le [math]::Max(1, $ColdBootCount); $iteration++) {
        $runs.Add((Invoke-BootRun -Acceleration 'whpx' -Iteration $iteration -ValidateNeoNews $true -EvidenceRoot (Join-Path $evidenceRoot "cold-$iteration")))
    }
}
$rootHashAfter = (Get-FileHash -LiteralPath $rootDisk -Algorithm SHA256).Hash
$rootInfoAfter = Invoke-QemuImageJson -Command 'info' -ImagePath $rootDisk
$rootCheckAfter = Invoke-QemuImageJson -Command 'check' -ImagePath $rootDisk
$knownGood = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'runtime'), (Join-Path $RepositoryRoot 'dist') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.qcow2', '.raw') -and $_.FullName -notmatch '(?i)neonews-runtime-v1\.qcow2$' } | Select-Object -ExpandProperty FullName)
$summary = if ($Mode -eq 'Matrix') {
    $whpxRun = $runs | Where-Object { $_.acceleration -eq 'whpx' } | Select-Object -First 1
    $tcgRun = $runs | Where-Object { $_.acceleration -eq 'tcg' } | Select-Object -First 1
    [ordered]@{ whpxClassification = $whpxRun.classification; tcgClassification = $tcgRun.classification; whpxBooted = $whpxRun.boot.androidReady; tcgBooted = $tcgRun.boot.androidReady; diagnosis = if ($tcgRun.boot.androidReady -and -not $whpxRun.boot.androidReady) { 'WHPX_HOST_PATH_FAILURE' } elseif (-not $tcgRun.boot.androidReady -and -not $whpxRun.boot.androidReady) { 'GUEST_OR_IMAGE_BOOT_FAILURE' } else { 'INCONCLUSIVE' } }
} else {
    [ordered]@{ requestedColdBoots = $ColdBootCount; passedColdBoots = @($runs | Where-Object { $_.classification -eq 'BOOT_RELIABILITY_PASS' }).Count; allAndroidReady = @($runs | Where-Object { $_.boot.androidReady }).Count -eq [math]::Max(1, $ColdBootCount); diagnosis = if (@($runs | Where-Object { $_.classification -ne 'BOOT_RELIABILITY_PASS' }).Count -eq 0) { 'BOOT_RELIABILITY_PASS' } else { 'BOOT_RELIABILITY_INCOMPLETE' } }
}
$bootReport = [ordered]@{
    schema = 1
    status = if ($summary.diagnosis -eq 'BOOT_RELIABILITY_PASS') { 'validated' } else { 'diagnostic' }
    mode = $Mode
    capturedAt = (Get-Date).ToUniversalTime().ToString('o')
    rootDisk = [ordered]@{ path = $rootDisk; hashBefore = $rootHashBefore; hashAfter = $rootHashAfter; unchanged = $rootHashBefore -eq $rootHashAfter; infoBefore = $rootInfoBefore; infoAfter = $rootInfoAfter; checkBefore = $rootCheckBefore; checkAfter = $rootCheckAfter }
    approvedImage = $androidImage
    knownGoodImages = $knownGood
    summary = $summary
    runs = $runs.ToArray()
    evidenceRoot = $evidenceRoot
}
$bootReport | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $reportFullPath -Encoding utf8
$whpxReport = [ordered]@{
    schema = 1
    capturedAt = (Get-Date).ToUniversalTime().ToString('o')
    whpx = $hostState
    qemu = [ordered]@{ executable = $qemuPath; qemuImg = $qemuImgPath; configuredAcceleration = $config.android.qemu.acceleration; allowTcgForDiagnostics = [bool]$config.android.qemu.allowTcgForDiagnostics }
    runs = @($runs | ForEach-Object { [ordered]@{ acceleration = $_.acceleration; classification = $_.classification; qemuMatches = $_.qemu.qemuMatches; processId = $_.qemu.processId; exitCode = $_.qemu.exitCode } })
    systemEvents = @(Get-WinEvent -LogName System -MaxEvents 250 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match '(?i)WHPX|Hyper-V|Hypervisor|Virtual Machine Platform' } | Select-Object -First 100 | ForEach-Object { [ordered]@{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); provider = $_.ProviderName; id = $_.Id; level = $_.LevelDisplayName; message = $_.Message } })
}
$whpxReport | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $whpxReportFullPath -Encoding utf8
$bootReport | ConvertTo-Json -Depth 8
if ($Mode -eq 'Matrix' -and $summary.diagnosis -eq 'GUEST_OR_IMAGE_BOOT_FAILURE') { exit 2 }
if ($Mode -eq 'ColdBoots' -and $summary.diagnosis -ne 'BOOT_RELIABILITY_PASS') { exit 3 }
