[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\..\config\runtime.json'),
    [string]$Serial,
    [string]$Activity,
    [switch]$StartEmulator,
    [switch]$StopEmulator,
    [switch]$Launch,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'

function Resolve-SdkRoot {
    if ($env:ANDROID_SDK_ROOT) {
        return $env:ANDROID_SDK_ROOT
    }

    if ($env:ANDROID_HOME) {
        return $env:ANDROID_HOME
    }

    return (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
}

function Invoke-AdbCommand {
    param(
        [string]$AdbPath,
        [string]$DeviceSerial,
        [string[]]$Arguments
    )

    $output = & $AdbPath -s $DeviceSerial @Arguments 2>&1
    return (($output | Out-String).Trim())
}

function Wait-ForBoot {
    param(
        [string]$AdbPath,
        [string]$DeviceSerial,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $state = (& $AdbPath -s $DeviceSerial get-state 2>$null | Out-String).Trim()
        if ($state -eq 'device') {
            $bootCompleted = Invoke-AdbCommand -AdbPath $AdbPath -DeviceSerial $DeviceSerial -Arguments @('shell', 'getprop', 'sys.boot_completed')
            if ($bootCompleted -match '(?m)^1$') {
                return $true
            }
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
$adbPath = Join-Path $sdkRoot 'platform-tools\adb.exe'
$emulatorPath = Join-Path $sdkRoot 'emulator\emulator.exe'

if (-not (Test-Path -LiteralPath $adbPath)) {
    throw "ADB não encontrado: $adbPath"
}

if (-not $Serial) {
    $Serial = "emulator-$($config.android.emulator.validationPort)"
    if ($Serial -eq 'emulator-') {
        $Serial = 'emulator-5556'
    }
}

if (-not $Activity) {
    $Activity = $config.neonews.launchActivity
}

if (-not $Activity) {
    $Activity = 'com.in9midia.neonews.player.TerminalActivity'
}

$startedProcess = $null
if ($StartEmulator) {
    if (-not (Test-Path -LiteralPath $emulatorPath)) {
        throw "Emulator não encontrado: $emulatorPath"
    }

    $env:ANDROID_HOME = $sdkRoot
    $env:ANDROID_SDK_ROOT = $sdkRoot
    $arguments = @(
        '-avd', $config.android.preferredAvd,
        '-no-window',
        '-gpu', 'swiftshader',
        '-no-boot-anim',
        '-no-snapshot',
        '-accel', 'auto',
        '-timezone', $config.runtime.timezone,
        '-port', ($Serial -replace '^emulator-', '')
    )
    $startedProcess = Start-Process -FilePath $emulatorPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

$booted = Wait-ForBoot -AdbPath $adbPath -DeviceSerial $Serial
$packageName = [string]$config.neonews.packageName
$packagePath = ''
$installedVersion = $null
$launchResult = $null
$resumedActivity = $null

if ($booted) {
    $packagePath = Invoke-AdbCommand -AdbPath $adbPath -DeviceSerial $Serial -Arguments @('shell', 'pm', 'path', $packageName)
    if ($packagePath -match "^package:") {
        $packageDump = Invoke-AdbCommand -AdbPath $adbPath -DeviceSerial $Serial -Arguments @('shell', 'dumpsys', 'package', $packageName)
        $versionMatch = [regex]::Match($packageDump, 'versionName=([^\s]+)')
        if ($versionMatch.Success) {
            $installedVersion = $versionMatch.Groups[1].Value
        }

        if ($Launch) {
            $launchResult = Invoke-AdbCommand -AdbPath $adbPath -DeviceSerial $Serial -Arguments @('shell', 'am', 'start', '-W', '-n', "$packageName/$Activity")
            $activityDump = Invoke-AdbCommand -AdbPath $adbPath -DeviceSerial $Serial -Arguments @('shell', 'dumpsys', 'activity', 'activities')
            $resumedMatch = [regex]::Match($activityDump, 'mResumedActivity:.*?([^\s/]+/[^\s}]+)')
            if ($resumedMatch.Success) {
                $resumedActivity = $resumedMatch.Groups[1].Value
            }
        }
    }
}

$installed = $packagePath -match "^package:"
$status = if (-not $booted) { 'device-not-booted' } elseif (-not $installed) { 'not-installed' } elseif ($Launch -and $resumedActivity -and ($resumedActivity -match [regex]::Escape($packageName))) { 'launched' } elseif ($Launch) { 'launch-unverified' } else { 'installed' }

$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    serial = $Serial
    avd = $config.android.preferredAvd
    packageName = $packageName
    expectedVersion = [string]$config.neonews.versionName
    installedVersion = $installedVersion
    launchActivity = "$packageName/$Activity"
    packagePath = $packagePath
    launchRequested = [bool]$Launch
    launchResult = $launchResult
    resumedActivity = $resumedActivity
    status = $status
}

$json = $result | ConvertTo-Json -Depth 8
if ($ReportPath) {
    $reportDirectory = Split-Path -Parent $ReportPath
    if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) {
        New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    }
    Set-Content -LiteralPath $ReportPath -Value $json -Encoding utf8
}

$json

if ($StopEmulator -and $startedProcess) {
    & $adbPath -s $Serial emu kill 2>$null | Out-Null
}

