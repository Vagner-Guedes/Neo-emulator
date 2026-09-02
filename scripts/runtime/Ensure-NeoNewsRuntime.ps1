[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Serial,
    [int]$MaxAttempts,
    [int]$RetryDelaySeconds,
    [switch]$StartEmulator,
    [switch]$StopEmulatorOnFailure,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }

function Resolve-SdkRoot {
    if ($env:ANDROID_SDK_ROOT) { return $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { return $env:ANDROID_HOME }
    return (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
}

function Invoke-Adb {
    param([string]$AdbPath, [string[]]$Arguments)
    $output = & $AdbPath -s $Serial @Arguments 2>&1
    return (($output | Out-String).Trim())
}

function Wait-ForBoot {
    param([string]$AdbPath, [int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $stableBootChecks = 0
    do {
        $state = (& $AdbPath -s $Serial get-state 2>$null | Out-String).Trim()
        if ($state -eq 'device') {
            $boot = (& $AdbPath -s $Serial shell getprop sys.boot_completed 2>$null | Out-String).Trim()
            if ($boot -match '(?m)^1$') {
                $stableBootChecks++
                if ($stableBootChecks -ge 2) {
                    Start-Sleep -Seconds 2
                    $finalState = (& $AdbPath -s $Serial get-state 2>$null | Out-String).Trim()
                    if ($finalState -eq 'device') { return $true }
                }
            } else {
                $stableBootChecks = 0
            }
        } else {
            $stableBootChecks = 0
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuração não encontrada: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
$sdkRoot = Resolve-SdkRoot
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$adbPath = Join-Path $repositoryRoot (($config.android.tooling.sdkRoot + '\' + $config.android.tooling.adbRelativePath) -replace '/', '\')
$allowEnvironmentFallback = [bool]$config.android.tooling.allowEnvironmentFallback
if (-not (Test-Path -LiteralPath $adbPath) -and $allowEnvironmentFallback) { $adbPath = Join-Path $sdkRoot 'platform-tools\adb.exe' }
$emulatorPath = Join-Path $sdkRoot 'emulator\emulator.exe'
if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB não encontrado: $adbPath" }

if (-not $Serial) {
    if ($config.android.adb.transport -eq 'tcp') {
        $Serial = "$($config.android.adb.host):$($config.android.adb.hostPort)"
    } else {
        $port = if ($config.android.emulator.validationPort) { $config.android.emulator.validationPort } else { 5556 }
        $Serial = if ($config.android.adb.emulatorSerial) { $config.android.adb.emulatorSerial } else { "emulator-$port" }
    }
}
if (-not $MaxAttempts) { $MaxAttempts = [int]$config.resilience.maxAttempts }
if (-not $MaxAttempts) { $MaxAttempts = 3 }
if (-not $RetryDelaySeconds) { $RetryDelaySeconds = [int]$config.resilience.retryDelaySeconds }
if (-not $RetryDelaySeconds) { $RetryDelaySeconds = 5 }

$lockPath = Join-Path (Join-Path $PSScriptRoot '..\..') $config.resilience.lockPath
$lockDirectory = Split-Path -Parent $lockPath
if (-not (Test-Path -LiteralPath $lockDirectory)) {
    New-Item -ItemType Directory -Path $lockDirectory -Force | Out-Null
}

$lockStream = $null
$startedProcess = $null
$result = $null
try {
    try {
        $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
        $result = [ordered]@{
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
            serial = $Serial
            status = 'already-running'
            attempts = 0
        }
    }

    if (-not $result) {
        if ($StartEmulator) {
            if (-not (Test-Path -LiteralPath $emulatorPath)) { throw "Emulator não encontrado: $emulatorPath" }
            $env:ANDROID_HOME = $sdkRoot
            $env:ANDROID_SDK_ROOT = $sdkRoot
            $port = $Serial -replace '^emulator-', ''
            $startedProcess = Start-Process -FilePath $emulatorPath -ArgumentList @('-avd', $config.android.preferredAvd, '-no-window', '-gpu', 'swiftshader', '-no-boot-anim', '-no-snapshot', '-accel', 'auto', '-timezone', $config.runtime.timezone, '-port', $port) -WindowStyle Hidden -PassThru
        }

        $attemptEvents = @()
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $event = [ordered]@{ attempt = $attempt; status = $null; detail = $null }
            try {
                & $adbPath start-server 2>&1 | Out-Null
                $booted = Wait-ForBoot -AdbPath $adbPath
                if (-not $booted) {
                    $event.status = 'device-not-booted'
                    $event.detail = 'sys.boot_completed não confirmou o boot'
                } else {
                    $packageName = [string]$config.neonews.packageName
                    $packagePath = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'pm', 'path', $packageName)
                    if ($packagePath -notmatch '^package:') {
                        $event.status = 'package-missing'
                        $event.detail = 'APK não instalado; não há recuperação automática possível'
                        $attemptEvents += [pscustomobject]$event
                        break
                    }

                    $activity = [string]$config.neonews.launchActivity
                    $launch = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'am', 'start', '-W', '-n', "$packageName/$activity")
                    $activityDump = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'dumpsys', 'activity', 'activities')
                    if ($activityDump -match [regex]::Escape("$packageName/$activity")) {
                        $event.status = 'healthy'
                        $event.detail = 'atividade operacional em primeiro plano'
                        $attemptEvents += [pscustomobject]$event
                        break
                    }

                    $event.status = 'activity-unverified'
                    $event.detail = $launch
                }
            } catch {
                $event.detail = $_.Exception.Message
                if ($event.detail -match '(?i)device .+ not found|no devices') {
                    $event.status = 'device-unavailable'
                } else {
                    $event.status = 'attempt-error'
                }
            }
            $attemptEvents += [pscustomobject]$event
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $RetryDelaySeconds }
        }

        $lastEvent = $attemptEvents | Select-Object -Last 1
        $result = [ordered]@{
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
            serial = $Serial
            maxAttempts = $MaxAttempts
            retryDelaySeconds = $RetryDelaySeconds
            attempts = @($attemptEvents)
            status = if ($lastEvent) { $lastEvent.status } else { 'no-attempt' }
        }
    }
} finally {
    if ($StopEmulatorOnFailure -and $startedProcess -and $result -and $result.status -ne 'healthy') {
        if ($startedProcess -and -not $startedProcess.HasExited) {
            Stop-Process -Id $startedProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if ($lockStream) { $lockStream.Dispose() }
}

$json = $result | ConvertTo-Json -Depth 8
if ($ReportPath) {
    $reportDirectory = Split-Path -Parent $ReportPath
    if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
    Set-Content -LiteralPath $ReportPath -Value $json -Encoding utf8
}
$json
