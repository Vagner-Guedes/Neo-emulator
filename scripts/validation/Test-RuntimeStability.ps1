[CmdletBinding()]
param(
    [string]$ExecutablePath,
    [int]$DurationSeconds = 600,
    [int]$PollSeconds = 5,
    [int]$DiagnosticTimeoutSeconds = 30,
    [int]$ReadinessTimeoutSeconds = 300,
    [int]$NativeBridgeEvidenceMinimumSeconds = 60,
    [int]$EvidenceMaxAgeHours = 24,
    [string]$LauncherSmokeEvidencePath = 'reports/launcher-smoke.json',
    [string]$NativeBridgeEvidencePath = 'reports/nativebridge.json',
    [string]$WebViewContentEvidencePath = 'reports/webview-content.json',
    [string]$TtsEvidencePath = 'reports/tts-synthesis.json',
    [string]$NetworkMediaEvidencePath = 'reports/guest-network-media.json',
    [string]$ReportPath = 'reports/runtime-stability.json',
    [string]$LogcatReportPath = 'reports/runtime-stability-600s.logcat-filtered.txt'
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
if ([string]::IsNullOrWhiteSpace($ExecutablePath) -or -not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
    throw 'NeoNewsRuntime.exe não encontrado. Informe -ExecutablePath ou publique o runtime.'
}
$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
$runtimeRoot = Split-Path -Parent $ExecutablePath
$configPath = Join-Path $runtimeRoot 'config\runtime.json'
if (-not (Test-Path -LiteralPath $configPath)) { throw "runtime.json não encontrado ao lado da publicação: $configPath" }
$config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
$adbPath = Join-Path $runtimeRoot ($config.android.tooling.sdkRoot -replace '/', '\')
$adbPath = Join-Path $adbPath ($config.android.tooling.adbRelativePath -replace '/', '\')
$qemuPath = Join-Path $runtimeRoot ($config.android.qemu.executable -replace '/', '\')
$adbServerPort = [int]$config.android.adb.serverPort
$qmpPort = [int]$config.android.qemu.qmpPort
$expectedSerial = if ($config.android.adb.transport -eq 'tcp') {
    "$($config.android.adb.host):$($config.android.adb.hostPort)"
} elseif ($config.android.adb.emulatorSerial) {
    [string]$config.android.adb.emulatorSerial
} else {
    "emulator-$($config.android.emulator.validationPort)"
}
$diagnosticsPath = Join-Path $runtimeRoot ($config.diagnostics.defaultReport -replace '/', '\')
$reportFullPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $runtimeRoot ($ReportPath -replace '/', '\') }
. (Join-Path $repositoryRoot 'scripts\validation\ValidationEvidence.Common.ps1')
$reportFullPath = Initialize-ValidationReport -ReportPath $reportFullPath -Validator 'Test-RuntimeStability'
if ($DurationSeconds -lt 600) { throw 'DurationSeconds precisa ser pelo menos 600 segundos.' }
if ($PollSeconds -lt 1) { throw 'PollSeconds precisa ser pelo menos 1 segundo.' }
if ($EvidenceMaxAgeHours -lt 1) { throw 'EvidenceMaxAgeHours precisa ser pelo menos 1 hora.' }
if ($ReadinessTimeoutSeconds -lt 1) { throw 'ReadinessTimeoutSeconds precisa ser pelo menos 1 segundo.' }
if ($NativeBridgeEvidenceMinimumSeconds -lt 1) { throw 'NativeBridgeEvidenceMinimumSeconds precisa ser pelo menos 1 segundo.' }

function Resolve-EvidencePath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $runtimeRoot ($Path -replace '/', '\')
}

function Read-JsonEvidence {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { return $null }
}

function Test-ReportFresh {
    param([object]$Report)
    if ($null -eq $Report) { return $false }
    if ([string]$Report.evidenceState -eq 'invalidated') { return $false }
    try { $timestamp = [DateTimeOffset]::Parse([string]$Report.timestamp) }
    catch { return $false }
    $now = [DateTimeOffset]::UtcNow
    return $timestamp -le $now.AddMinutes(5) -and $timestamp -ge $now.AddHours(-$EvidenceMaxAgeHours)
}

function Test-ReportTransport {
    param([object]$Report)
    if ($null -eq $Report) { return $false }
    return [string]$Report.transport -eq [string]$config.android.adb.transport -and [string]$Report.serial -eq $expectedSerial
}

function Test-RequiredEvidence {
    param([object]$Report, [string]$Status)
    return (Test-ReportFresh $Report) -and (Test-ReportTransport $Report) -and [string]$Report.status -eq $Status
}

function Test-NeoNewsContentEvidence {
    param([object]$Report)
    if (-not (Test-ReportFresh $Report)) { return $false }
    if ([string]$Report.status -ne 'validated') { return $false }
    try {
        $reportExecutable = [System.IO.Path]::GetFullPath([string]$Report.executable)
        $selectedExecutable = [System.IO.Path]::GetFullPath($ExecutablePath)
        return $reportExecutable.Equals($selectedExecutable, [StringComparison]::OrdinalIgnoreCase) -and
            [bool]$Report.manualEvidence.neoNewsContentObserved -and
            [bool]$Report.manualEvidence.neoNewsPlaybackObserved
    }
    catch { return $false }
}

function Send-LauncherCommand {
    param([string]$Argument)
    $process = Start-Process -FilePath $ExecutablePath -ArgumentList $Argument -WorkingDirectory $runtimeRoot -PassThru -Wait
    return [int]$process.ExitCode
}

function Get-FreshDiagnostics {
    $before = if (Test-Path -LiteralPath $diagnosticsPath -PathType Leaf) {
        (Get-Item -LiteralPath $diagnosticsPath).LastWriteTimeUtc
    } else {
        [datetime]::MinValue
    }
    $command = Start-Process -FilePath $ExecutablePath -ArgumentList '--diagnostics' -WorkingDirectory $runtimeRoot -PassThru -Wait
    $deadline = (Get-Date).ToUniversalTime().AddSeconds($DiagnosticTimeoutSeconds)
    $fresh = $false
    do {
        if (Test-Path -LiteralPath $diagnosticsPath -PathType Leaf) {
            $fresh = (Get-Item -LiteralPath $diagnosticsPath).LastWriteTimeUtc -gt $before
        }
        if (-not $fresh) { Start-Sleep -Milliseconds 250 }
    } while (-not $fresh -and (Get-Date).ToUniversalTime() -lt $deadline)
    $report = if ($fresh) { Read-JsonEvidence $diagnosticsPath } else { $null }
    [pscustomobject]@{
        commandExitCode = [int]$command.ExitCode
        fresh = $fresh
        report = $report
    }
}

function Convert-ToProcessArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-ExternalWithTimeout {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 3
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $runtimeRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (($Arguments | ForEach-Object { Convert-ToProcessArgument ([string]$_) }) -join ' ')
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        if (-not $process.WaitForExit([math]::Max(1000, $TimeoutSeconds * 1000))) {
            try { $process.Kill() } catch { }
            return [pscustomobject]@{ exitCode = $null; timedOut = $true; text = 'process-timeout' }
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $text = (($stdout, $stderr | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n").Trim()
        return [pscustomobject]@{ exitCode = $process.ExitCode; timedOut = $false; text = $text }
    }
    catch {
        return [pscustomobject]@{ exitCode = $null; timedOut = $false; text = $_.Exception.Message }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-FastAdb {
    param(
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 3
    )
    return Invoke-ExternalWithTimeout -FilePath $adbPath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Read-QmpResponseLine {
    param([System.IO.StreamReader]$Reader)
    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        try { $line = $Reader.ReadLine() } catch { return $null }
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        try {
            $message = $line | ConvertFrom-Json
            if ($null -ne $message.return -or $null -ne $message.error) { return $message }
        }
        catch { return $null }
    }
    return $null
}

function Get-QmpRuntimeObservation {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $client.ConnectAsync('127.0.0.1', $qmpPort)
        if (-not $connectTask.Wait(1200) -or -not $client.Connected) {
            return [ordered]@{ port = $qmpPort; connected = $false; capabilities = $false; queryStatus = $false; status = ''; response = 'connect-timeout' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 1200
        $encoding = [System.Text.UTF8Encoding]::new($false)
        $reader = [System.IO.StreamReader]::new($stream, $encoding, $false, 4096, $true)
        $writer = [System.IO.StreamWriter]::new($stream, $encoding, 4096, $true)
        $greeting = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($greeting)) {
            return [ordered]@{ port = $qmpPort; connected = $true; capabilities = $false; queryStatus = $false; status = ''; response = 'missing-greeting' }
        }
        $writer.WriteLine('{"execute":"qmp_capabilities"}')
        $writer.Flush()
        $capabilities = Read-QmpResponseLine $reader
        $capabilitiesOk = $null -ne $capabilities -and $null -ne $capabilities.return -and $null -eq $capabilities.error
        if (-not $capabilitiesOk) {
            return [ordered]@{ port = $qmpPort; connected = $true; capabilities = $false; queryStatus = $false; status = ''; response = 'qmp-capabilities-failed' }
        }
        $writer.WriteLine('{"execute":"query-status"}')
        $writer.Flush()
        $statusResponse = Read-QmpResponseLine $reader
        $statusOk = $null -ne $statusResponse -and $null -ne $statusResponse.return -and $null -eq $statusResponse.error
        $status = if ($statusOk -and $null -ne $statusResponse.return.status) { [string]$statusResponse.return.status } else { '' }
        return [ordered]@{ port = $qmpPort; connected = $true; capabilities = $capabilitiesOk; queryStatus = $statusOk; status = $status; response = if ($statusOk) { 'query-status-ok' } else { 'query-status-failed' } }
    }
    catch {
        return [ordered]@{ port = $qmpPort; connected = $false; capabilities = $false; queryStatus = $false; status = ''; response = $_.Exception.Message }
    }
    finally {
        $client.Dispose()
    }
}

function Get-ProcessObservation {
    param([string]$ExpectedPath, [string]$Name)
    $records = @()
    try {
        $records = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -ieq $Name -and (
                ([string]$_.ExecutablePath).Equals($ExpectedPath, [StringComparison]::OrdinalIgnoreCase) -or
                [string]$_.CommandLine -match [regex]::Escape($ExpectedPath)
            )
        })
    }
    catch { $records = @() }
    $record = $records | Select-Object -First 1
    [ordered]@{
        alive = $null -ne $record
        pid = if ($null -ne $record) { [int]$record.ProcessId } else { $null }
        path = if ($null -ne $record) { [string]$record.ExecutablePath } else { $ExpectedPath }
        state = if ($null -ne $record) { 'running' } else { 'not-found' }
        commandLine = if ($null -ne $record) { [string]$record.CommandLine } else { '' }
    }
}

function Get-AdbServerObservation {
    $observation = Get-ProcessObservation -ExpectedPath $adbPath -Name 'adb.exe'
    $listener = $null
    try {
        $listener = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $adbServerPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    catch { $listener = $null }
    $observation.listener = $null -ne $listener
    $observation.port = $adbServerPort
    $observation.transport = [string]$config.android.adb.transport
    return $observation
}

function Get-HeartbeatObservation {
    $path = Join-Path $runtimeRoot 'logs\watchdog.log'
    $line = ''
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { $line = @(Get-Content -LiteralPath $path -Tail 40 -ErrorAction Stop | Where-Object { $_ -match 'WATCHDOG_HEARTBEAT' } | Select-Object -Last 1)[0] } catch { $line = '' }
    }
    $heartbeatAt = $null
    if ($line -match 'WATCHDOG_HEARTBEAT\s+(?<at>[^\s]+)') {
        try { $heartbeatAt = [DateTimeOffset]::Parse($Matches.at) } catch { $heartbeatAt = $null }
    }
    $age = if ($heartbeatAt) { [math]::Round(([DateTimeOffset]::UtcNow - $heartbeatAt.ToUniversalTime()).TotalSeconds, 3) } else { $null }
    [ordered]@{
        active = $null -ne $heartbeatAt -and $age -ge 0 -and $age -le [math]::Max(15, $PollSeconds * 3)
        lastHeartbeat = $heartbeatAt
        ageSeconds = $age
        path = $path
        line = $line
    }
}

function Get-FastRuntimeSample {
    param([int]$LauncherPid)
    $at = [DateTimeOffset]::UtcNow
    $deviceResult = Invoke-FastAdb @('-P', $adbServerPort, 'devices')
    $deviceLine = @($deviceResult.text -split '\r?\n' | Where-Object { $_ -match ('^' + [regex]::Escape($expectedSerial) + '\s+') } | Select-Object -First 1)
    $deviceState = if ($deviceLine.Count -gt 0 -and $deviceLine[0] -match '\s+(?<state>\S+)\s*$') { $Matches.state } else { '' }
    $stateResult = Invoke-FastAdb @('-P', $adbServerPort, '-s', $expectedSerial, 'get-state')
    $bootResult = Invoke-FastAdb @('-P', $adbServerPort, '-s', $expectedSerial, 'shell', 'getprop', 'sys.boot_completed')
    $activityResult = Invoke-FastAdb @('-P', $adbServerPort, '-s', $expectedSerial, 'shell', 'dumpsys', 'activity', 'activities')
    $pidResult = Invoke-FastAdb @('-P', $adbServerPort, '-s', $expectedSerial, 'shell', 'pidof', [string]$config.neonews.packageName)
    $releaseResult = Invoke-FastAdb @('-P', $adbServerPort, '-s', $expectedSerial, 'shell', 'getprop', 'ro.build.version.release')
    $apiResult = Invoke-FastAdb @('-P', $adbServerPort, '-s', $expectedSerial, 'shell', 'getprop', 'ro.build.version.sdk')
    $bridgeResult = Invoke-FastAdb @('-P', $adbServerPort, '-s', $expectedSerial, 'shell', 'getprop', [string]$config.android.nativeBridge.property)
    $packageResult = Invoke-FastAdb @('-P', $adbServerPort, '-s', $expectedSerial, 'shell', 'dumpsys', 'package', [string]$config.neonews.packageName)
    $logcatResult = Invoke-FastAdb @('-P', $adbServerPort, '-s', $expectedSerial, 'shell', 'logcat', '-d', '-v', 'threadtime', '-t', '80') -TimeoutSeconds 5
    $qemu = Get-ProcessObservation -ExpectedPath $qemuPath -Name 'qemu-system-x86_64.exe'
    $adbServer = Get-AdbServerObservation
    $qmp = Get-QmpRuntimeObservation
    $heartbeat = Get-HeartbeatObservation
    $neoPid = @($pidResult.text -split '\s+' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
    $packagePrimaryAbi = if ($packageResult.text -match 'primaryCpuAbi=(?<abi>[^\s]+)') { $Matches.abi } else { '' }
    $terminalActivity = $activityResult.text -match '(?im)(mResumedActivity|mFocusedActivity|topResumedActivity).*com\.in9midia\.neonews\.player(?:/|\s).*TerminalActivity'
    $bootCompleted = $bootResult.text.Trim() -eq '1'
    $adbReady = $deviceState -eq 'device' -and $stateResult.text.Trim() -eq 'device' -and -not $deviceResult.timedOut
    $criticalLines = @($logcatResult.text -split '\r?\n' | Where-Object { $_ -match '(?i)UnsatisfiedLinkError|SIGSEGV|SIGABRT|FATAL EXCEPTION|ANR in com\.in9midia\.neonews\.player|linker.*(error|fail)|NativeBridge.*(error|fail)|Houdini.*(error|fail)' })
    $launcherAlive = $false
    try { $launcherAlive = $null -ne (Get-Process -Id $LauncherPid -ErrorAction SilentlyContinue) } catch { $launcherAlive = $false }
    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $launcherAlive) { $reasons.Add('LAUNCHER_NOT_RUNNING') }
    if (-not $qemu.alive) { $reasons.Add('QEMU_PROCESS_NOT_RUNNING') }
    if (-not $qmp.connected -or -not $qmp.capabilities -or -not $qmp.queryStatus -or $qmp.status -ne 'running') { $reasons.Add('QMP_NOT_RUNNING') }
    if (-not $adbServer.alive -or -not $adbServer.listener) { $reasons.Add('ADB_SERVER_NOT_LISTENING') }
    if (-not $adbReady) { $reasons.Add('ADB_DEVICE_NOT_READY') }
    if (-not $bootCompleted) { $reasons.Add('ANDROID_BOOT_INCOMPLETE') }
    if (-not $terminalActivity) { $reasons.Add('TERMINAL_ACTIVITY_NOT_FOREGROUND') }
    if ($neoPid.Count -eq 0) { $reasons.Add('NEONEWS_PID_NOT_FOUND') }
    if ([string]$releaseResult.text.Trim() -ne [string]$config.android.release -or [string]$apiResult.text.Trim() -ne [string]$config.android.apiLevel) { $reasons.Add('ANDROID_IDENTITY_MISMATCH') }
    if ([string]$bridgeResult.text.Trim() -eq '') { $reasons.Add('NATIVE_BRIDGE_PROPERTY_EMPTY') }
    if ($packagePrimaryAbi -ne [string]$config.android.nativeBridge.preferredAbi) { $reasons.Add('NEONEWS_PRIMARY_ABI_MISMATCH') }
    if (-not $heartbeat.active) { $reasons.Add('WATCHDOG_HEARTBEAT_STALE') }
    if ($criticalLines.Count -gt 0) { $reasons.Add('CRITICAL_LOGCAT_FAILURE') }
    $stable = $reasons.Count -eq 0
    [ordered]@{
        at = $at
        launcher = [ordered]@{ pid = $LauncherPid; alive = $launcherAlive }
        qemu = $qemu
        adb = [ordered]@{ server = $adbServer; serial = $expectedSerial; deviceState = $deviceState; getState = $stateResult.text.Trim(); transport = [string]$config.android.adb.transport; port = [int]$config.android.adb.hostPort }
        qmp = $qmp
        android = [ordered]@{ release = $releaseResult.text.Trim(); apiLevel = $apiResult.text.Trim(); bootCompleted = $bootResult.text.Trim(); identityMatches = $releaseResult.text.Trim() -eq [string]$config.android.release -and $apiResult.text.Trim() -eq [string]$config.android.apiLevel; nativeBridge = $bridgeResult.text.Trim() }
        neoNews = [ordered]@{ package = [string]$config.neonews.packageName; pid = if ($neoPid.Count -gt 0) { $neoPid[0] } else { '' }; primaryCpuAbi = $packagePrimaryAbi; terminalActivityForeground = $terminalActivity }
        watchdog = $heartbeat
        logcat = [ordered]@{ criticalCount = $criticalLines.Count; criticalLines = $criticalLines }
        failureReasons = $reasons.ToArray()
        stable = $stable
        effectiveStable = $stable
        failureClassification = 'NONE'
        confirmation = $null
    }
}

function Get-ConfirmedRuntimeSample {
    param([int]$LauncherPid)
    $initial = Get-FastRuntimeSample -LauncherPid $LauncherPid
    if ([bool]$initial.stable) { return [pscustomobject]$initial }
    Start-Sleep -Milliseconds 1500
    $confirmation = Get-FastRuntimeSample -LauncherPid $LauncherPid
    $initial.confirmation = $confirmation
    if ([bool]$confirmation.stable) {
        $initial.failureClassification = 'TRANSIENT_PROBE_FAILURE'
        $initial.effectiveStable = $true
    }
    else {
        $initial.failureClassification = 'REAL_RUNTIME_FAILURE'
        $initial.effectiveStable = $false
    }
    return [pscustomobject]$initial
}

function Capture-FinalLogcat {
    param([string]$Path)
    $result = Invoke-FastAdb @('-P', $adbServerPort, '-s', $expectedSerial, 'shell', 'logcat', '-d', '-b', 'all', '-v', 'threadtime', '-t', '2000') -TimeoutSeconds 120
    $matches = @($result.text -split '\r?\n' | Where-Object { $_ -match '(?i)NativeBridge|Houdini|linker|UnsatisfiedLinkError|FATAL EXCEPTION|SIGSEGV|SIGABRT|ANR|crash' })
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value (($matches -join [Environment]::NewLine) + [Environment]::NewLine) -Encoding utf8
    [ordered]@{ path = $Path; adbExitCode = $result.exitCode; timedOut = $result.timedOut; matchedLineCount = $matches.Count; matchedLines = $matches }
}

function Test-KioskState {
    param([object]$Report)
    if ($null -eq $Report) { return $false }
    $kiosk = $Report.android.kiosk
    $expectedRotation = switch ([string]$config.android.kiosk.orientation) {
        'portrait' { '0'; break }
        'reverse-portrait' { '2'; break }
        'landscape' { '1'; break }
        'reverse-landscape' { '3'; break }
        default { '1' }
    }
    return [string]$Report.android.displaySize -match [regex]::Escape([string]$config.android.kiosk.displaySize) -and
        [string]$Report.android.displayDensity -match [regex]::Escape([string]$config.android.kiosk.displayDensity) -and
        [string]$kiosk.policyControl -match [regex]::Escape([string]$config.android.kiosk.immersivePolicy) -and
        [string]$kiosk.screenOffTimeout -eq [string]$config.android.kiosk.screenOffTimeoutMs -and
        [string]$kiosk.stayAwake -eq [string]$config.android.kiosk.stayAwakePluggedIn -and
        [string]$kiosk.screensaverEnabled -eq '0' -and
        [string]$kiosk.rotation -eq $expectedRotation
}

function Convert-DiagnosticsSample {
    param([object]$Probe)
    $report = $Probe.report
    $logcatErrors = if ($null -ne $report) {
        @($report.logcat | Where-Object { [string]$_ -match '(?i)UnsatisfiedLinkError|linker.*(error|fail)|SIGSEGV|FATAL EXCEPTION|ANR|chromium.*(error|fail)|WebView.*(error|fail)' })
    } else { @() }
    $identity = $null -ne $report -and
        [string]$report.tools.backend -eq 'QEMU Android-x86' -and
        [string]$report.tools.transport -eq [string]$config.android.adb.transport -and
        [string]$report.tools.serial -eq $expectedSerial -and
        [bool]$report.android.identityMatches
    $guestReady = $identity -and [bool]$report.android.adb.online -and [string]$report.android.bootCompleted -eq '1'
    $neoNewsRunning = $null -ne $report.neoNews -and [bool]$report.neoNews.installed -and [bool]$report.neoNews.running
    $webViewReady = $null -ne $report.webView -and [string]$report.webView.status -eq 'validated'
    $ttsReady = $null -ne $report.voice -and [bool]$report.voice.localeReady -and [string]$report.voice.defaultEngine -match '(?i)rhvoice'
    $nativeBridgeReady = $null -ne $report.abiCompatibility -and [bool]$report.abiCompatibility.runtimeStable
    $stable = $Probe.commandExitCode -eq 0 -and $Probe.fresh -and $identity -and $guestReady -and $neoNewsRunning -and
        [bool]$report.watchdog.active -and (Test-KioskState $report) -and $nativeBridgeReady -and $webViewReady -and $ttsReady -and $logcatErrors.Count -eq 0
    [ordered]@{
        at = [DateTimeOffset]::UtcNow
        diagnosticsFresh = [bool]$Probe.fresh
        diagnosticsExitCode = $Probe.commandExitCode
        backendRunning = if ($null -ne $report) { [bool]$report.tools.backendProcess } else { $false }
        adbOnline = if ($null -ne $report) { [bool]$report.android.adb.online } else { $false }
        guestIdentityMatches = if ($null -ne $report) { [bool]$report.android.identityMatches } else { $false }
        neoNewsRunning = $neoNewsRunning
        nativeBridgeRuntimeStable = $nativeBridgeReady
        webViewValidated = $webViewReady
        ttsValidated = $ttsReady
        watchdogActive = if ($null -ne $report) { [bool]$report.watchdog.active } else { $false }
        kioskApplied = Test-KioskState $report
        logcatErrorCount = $logcatErrors.Count
        stable = $stable
    }
}

$evidence = [ordered]@{}
$launcherSmokePath = Resolve-EvidencePath $LauncherSmokeEvidencePath
$launcherSmoke = Read-JsonEvidence $launcherSmokePath
$evidence.neoNewsContent = [ordered]@{
    path = $launcherSmokePath
    fresh = Test-ReportFresh $launcherSmoke
    executableMatches = if ($null -ne $launcherSmoke) { try { [System.IO.Path]::GetFullPath([string]$launcherSmoke.executable).Equals([System.IO.Path]::GetFullPath($ExecutablePath), [StringComparison]::OrdinalIgnoreCase) } catch { $false } } else { $false }
    observed = if ($null -ne $launcherSmoke) { [bool]$launcherSmoke.manualEvidence.neoNewsContentObserved } else { $false }
    playbackObserved = if ($null -ne $launcherSmoke) { [bool]$launcherSmoke.manualEvidence.neoNewsPlaybackObserved } else { $false }
    ready = Test-NeoNewsContentEvidence $launcherSmoke
}
foreach ($entry in @(
    [ordered]@{ name = 'nativeBridge'; path = $NativeBridgeEvidencePath; status = 'runtimeStable' },
    [ordered]@{ name = 'webViewContent'; path = $WebViewContentEvidencePath; status = 'validated' },
    [ordered]@{ name = 'ttsSynthesis'; path = $TtsEvidencePath; status = 'validated' },
    [ordered]@{ name = 'networkMedia'; path = $NetworkMediaEvidencePath; status = 'validated' }
)) {
    $path = Resolve-EvidencePath $entry.path
    $report = Read-JsonEvidence $path
    $statusReady = if ($entry.status -eq 'runtimeStable') {
        # The standalone Native Bridge preflight is intentionally shorter than
        # this integrated endurance run. The 600-second gate is enforced by
        # the diagnostics samples below, which validate the bridge on every
        # sample while NeoNews remains active.
        (Test-ReportFresh $report) -and (Test-ReportTransport $report) -and $null -ne $report -and [bool]$report.runtimeStable -and [int]$report.stabilitySeconds -ge $NativeBridgeEvidenceMinimumSeconds
    } else {
        Test-RequiredEvidence $report $entry.status
    }
    $evidence[$entry.name] = [ordered]@{
        path = $path
        fresh = Test-ReportFresh $report
        transportMatches = Test-ReportTransport $report
        status = if ($null -ne $report) { [string]$report.status } else { $null }
        runtimeStable = if ($null -ne $report) { [bool]$report.runtimeStable } else { $false }
        stabilitySeconds = if ($null -ne $report) { $report.stabilitySeconds } else { $null }
        ready = $statusReady
    }
}

$main = $null
$samples = New-Object System.Collections.Generic.List[object]
$readinessAttempts = New-Object System.Collections.Generic.List[object]
$startCommandExitCode = $null
$failure = $null
$startedAt = $null
$readinessAt = $null
$enduranceEndedAt = $null
$logcatCapture = $null
$logcatReportFullPath = Resolve-EvidencePath $LogcatReportPath
try {
    $existing = @(Get-Process -Name 'NeoNewsRuntime' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $ExecutablePath } catch { $false }
    })
    if ($existing.Count -gt 0) { throw "Já existe uma instância de $ExecutablePath. Encerre-a antes do teste de estabilidade integrado." }

    $main = Start-Process -FilePath $ExecutablePath -ArgumentList '--show' -WorkingDirectory $runtimeRoot -PassThru
    $windowDeadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 200
        try { $main.Refresh() } catch { }
        if (-not $main.HasExited -and $main.MainWindowHandle -ne 0) { break }
    } while ((Get-Date) -lt $windowDeadline)
    if ($main.HasExited) { throw 'O launcher encerrou antes do teste de estabilidade iniciar.' }

    $startCommandExitCode = Send-LauncherCommand '--start'
    if ($startCommandExitCode -ne 0) { throw "O comando --start falhou com exit code $startCommandExitCode." }
    $readinessDeadline = (Get-Date).ToUniversalTime().AddSeconds($ReadinessTimeoutSeconds)
    $readinessSample = $null
    do {
        $candidate = Get-ConfirmedRuntimeSample -LauncherPid $main.Id
        $readinessAttempts.Add($candidate)
        if ($candidate.effectiveStable) {
            $readinessSample = $candidate
            break
        }
        if ((Get-Date).ToUniversalTime() -lt $readinessDeadline) { Start-Sleep -Seconds $PollSeconds }
    } while ((Get-Date).ToUniversalTime() -lt $readinessDeadline)
    if ($null -eq $readinessSample) {
        throw "O runtime não atingiu Ready estável em $ReadinessTimeoutSeconds segundos antes do endurance."
    }
    $samples.Add($readinessSample)
    $readinessAt = [DateTimeOffset]::UtcNow
    $startedAt = $readinessAt
    $deadline = (Get-Date).ToUniversalTime().AddSeconds($DurationSeconds)
    do {
        $samples.Add((Get-ConfirmedRuntimeSample -LauncherPid $main.Id))
        if ((Get-Date).ToUniversalTime() -lt $deadline) { Start-Sleep -Seconds $PollSeconds }
    } while ((Get-Date).ToUniversalTime() -lt $deadline)
    $enduranceEndedAt = [DateTimeOffset]::UtcNow
    $logcatCapture = Capture-FinalLogcat -Path $logcatReportFullPath
}
catch {
    $failure = $_.Exception.Message
}
finally {
    if ($main -and -not $main.HasExited) {
        try { $null = Send-LauncherCommand '--exit' } catch { }
        try { $main.WaitForExit(30000) } catch { }
    }
}

$observedSeconds = if ($startedAt -and $enduranceEndedAt) { [math]::Round(($enduranceEndedAt - $startedAt).TotalSeconds, 2) } else { 0 }
$sampleFailures = @($samples | Where-Object { -not $_.effectiveStable })
$transientProbeFailures = @($samples + $readinessAttempts.ToArray() | Where-Object { $_.failureClassification -eq 'TRANSIENT_PROBE_FAILURE' })
$realRuntimeFailures = @($samples + $readinessAttempts.ToArray() | Where-Object { $_.failureClassification -eq 'REAL_RUNTIME_FAILURE' })
$runtimeEvidenceReady = @($evidence.GetEnumerator() | Where-Object { $_.Key -ne 'neoNewsContent' -and -not $_.Value.ready }).Count -eq 0
$stableForDuration = $samples.Count -gt 0 -and $observedSeconds -ge $DurationSeconds -and $sampleFailures.Count -eq 0
$status = if ([string]::IsNullOrWhiteSpace($failure) -and $startCommandExitCode -eq 0 -and $runtimeEvidenceReady -and $stableForDuration) { 'validated' } else { 'not-validated' }
$result = [ordered]@{
    timestamp = [DateTimeOffset]::UtcNow
    executable = $ExecutablePath
    runtimeDirectory = $runtimeRoot
    transport = $config.android.adb.transport
    serial = $expectedSerial
    requestedDurationSeconds = $DurationSeconds
    readinessTimeoutSeconds = $ReadinessTimeoutSeconds
    readinessReachedAt = $readinessAt
    observedDurationSeconds = $observedSeconds
    pollSeconds = $PollSeconds
    startCommandExitCode = $startCommandExitCode
    evidence = $evidence
    sampleCount = $samples.Count
    failedSampleCount = $sampleFailures.Count
    transientProbeFailureCount = $transientProbeFailures.Count
    realRuntimeFailureCount = $realRuntimeFailures.Count
    readinessAttemptCount = $readinessAttempts.Count
    readinessFailedAttemptCount = @($readinessAttempts.ToArray() | Where-Object { -not $_.effectiveStable }).Count
    logcatCapture = $logcatCapture
    # Convert the generic List explicitly. PowerShell's ConvertTo-Json throws
    # "Os tipos de argumento não correspondem" when a List[object] is wrapped
    # directly in @(...), which used to discard the completed endurance report.
    readinessAttempts = $readinessAttempts.ToArray()
    samples = $samples.ToArray()
    error = $failure
    status = $status
}
$json = $result | ConvertTo-Json -Depth 12
$reportDirectory = Split-Path -Parent $reportFullPath
if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
Set-Content -LiteralPath $reportFullPath -Value $json -Encoding utf8
$json
if ($status -ne 'validated') { throw "Estabilidade integrada não foi homologada: status=$status. Consulte $reportFullPath." }
