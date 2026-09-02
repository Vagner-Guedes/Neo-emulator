[CmdletBinding()]
param(
    [string]$ExecutablePath,
    [int]$DurationSeconds = 600,
    [int]$PollSeconds = 5,
    [int]$DiagnosticTimeoutSeconds = 30,
    [int]$EvidenceMaxAgeHours = 24,
    [string]$LauncherSmokeEvidencePath = 'reports/launcher-smoke.json',
    [string]$NativeBridgeEvidencePath = 'reports/nativebridge.json',
    [string]$WebViewContentEvidencePath = 'reports/webview-content.json',
    [string]$TtsEvidencePath = 'reports/tts-synthesis.json',
    [string]$NetworkMediaEvidencePath = 'reports/guest-network-media.json',
    [string]$ReportPath = 'reports/runtime-stability.json'
)

$ErrorActionPreference = 'Stop'
if ($DurationSeconds -lt 600) { throw 'DurationSeconds precisa ser pelo menos 600 segundos.' }
if ($PollSeconds -lt 1) { throw 'PollSeconds precisa ser pelo menos 1 segundo.' }
if ($EvidenceMaxAgeHours -lt 1) { throw 'EvidenceMaxAgeHours precisa ser pelo menos 1 hora.' }

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
$expectedSerial = if ($config.android.adb.transport -eq 'tcp') {
    "$($config.android.adb.host):$($config.android.adb.hostPort)"
} elseif ($config.android.adb.emulatorSerial) {
    [string]$config.android.adb.emulatorSerial
} else {
    "emulator-$($config.android.emulator.validationPort)"
}
$diagnosticsPath = Join-Path $runtimeRoot ($config.diagnostics.defaultReport -replace '/', '\')
$reportFullPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $runtimeRoot ($ReportPath -replace '/', '\') }

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
        (Test-ReportFresh $report) -and (Test-ReportTransport $report) -and $null -ne $report -and [bool]$report.runtimeStable -and [int]$report.stabilitySeconds -ge $DurationSeconds
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
$startCommandExitCode = $null
$failure = $null
$startedAt = $null
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
    $startedAt = [DateTimeOffset]::UtcNow
    $deadline = (Get-Date).ToUniversalTime().AddSeconds($DurationSeconds)
    do {
        $probe = Get-FreshDiagnostics
        $samples.Add((Convert-DiagnosticsSample $probe))
        if ((Get-Date).ToUniversalTime() -lt $deadline) { Start-Sleep -Seconds $PollSeconds }
    } while ((Get-Date).ToUniversalTime() -lt $deadline)
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

$observedSeconds = if ($startedAt) { [math]::Round(([DateTimeOffset]::UtcNow - $startedAt).TotalSeconds, 2) } else { 0 }
$sampleFailures = @($samples | Where-Object { -not $_.stable })
$runtimeEvidenceReady = @($evidence.Values | Where-Object { -not $_.ready }).Count -eq 0
$stableForDuration = $samples.Count -gt 0 -and $observedSeconds -ge $DurationSeconds -and $sampleFailures.Count -eq 0
$status = if ([string]::IsNullOrWhiteSpace($failure) -and $startCommandExitCode -eq 0 -and $runtimeEvidenceReady -and $stableForDuration) { 'validated' } else { 'not-validated' }
$result = [ordered]@{
    timestamp = [DateTimeOffset]::UtcNow
    executable = $ExecutablePath
    runtimeDirectory = $runtimeRoot
    transport = $config.android.adb.transport
    serial = $expectedSerial
    requestedDurationSeconds = $DurationSeconds
    observedDurationSeconds = $observedSeconds
    pollSeconds = $PollSeconds
    startCommandExitCode = $startCommandExitCode
    evidence = $evidence
    sampleCount = $samples.Count
    failedSampleCount = $sampleFailures.Count
    samples = @($samples)
    error = $failure
    status = $status
}
$json = $result | ConvertTo-Json -Depth 12
$reportDirectory = Split-Path -Parent $reportFullPath
if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
Set-Content -LiteralPath $reportFullPath -Value $json -Encoding utf8
$json
if ($status -ne 'validated') { throw "Estabilidade integrada não foi homologada: status=$status. Consulte $reportFullPath." }
