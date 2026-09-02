[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Serial,
    [string]$Activity,
    [switch]$StartEmulator,
    [switch]$StopEmulator,
    [switch]$Launch,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }

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
$configPathFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$runtimeRoot = [System.IO.Directory]::GetParent([System.IO.Directory]::GetParent($configPathFull).FullName).FullName
if (-not [string]::IsNullOrWhiteSpace($ReportPath) -and -not [System.IO.Path]::IsPathRooted($ReportPath)) {
    $ReportPath = Join-Path $runtimeRoot ($ReportPath -replace '/', '\')
}
$sdkRoot = Resolve-SdkRoot
$adbPath = Join-Path $runtimeRoot (($config.android.tooling.sdkRoot + '\' + $config.android.tooling.adbRelativePath) -replace '/', '\')
if (-not (Test-Path -LiteralPath $adbPath) -and $config.android.tooling.allowEnvironmentFallback) { $adbPath = Join-Path $sdkRoot 'platform-tools\adb.exe' }
$emulatorPath = Join-Path $sdkRoot 'emulator\emulator.exe'

if (-not (Test-Path -LiteralPath $adbPath)) {
    throw "ADB não encontrado: $adbPath"
}

if (-not $Serial) {
    $Serial = if ($config.android.adb.transport -eq 'tcp') {
        "$($config.android.adb.host):$($config.android.adb.hostPort)"
    } elseif ($config.android.adb.emulatorSerial) {
        $config.android.adb.emulatorSerial
    } else {
        "emulator-$($config.android.emulator.validationPort)"
    }
}

$packageName = [string]$config.neonews.packageName
if (-not $Activity) {
    $Activity = $config.neonews.launchActivity
}

if (-not $Activity) {
    $Activity = 'com.in9midia.neonews.player.TerminalActivity'
}
$Activity = [string]$Activity
if ($Activity -match '/') { $Activity = ($Activity -split '/')[-1] }
if ($Activity.StartsWith('.')) { $Activity = $Activity.Substring(1) }
if ($Activity.StartsWith("$packageName.", [System.StringComparison]::Ordinal)) { $Activity = $Activity.Substring($packageName.Length + 1) }
$activityComponent = "$packageName/.$Activity"

$startedProcess = $null
if ($StartEmulator) {
    if ($config.android.backend -eq 'qemu-android-x86') {
        throw 'O backend configurado é QEMU. Use NeoNewsRuntime.exe --start; este script só mantém compatibilidade com AVDs legados.'
    }
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
            $launchResult = Invoke-AdbCommand -AdbPath $adbPath -DeviceSerial $Serial -Arguments @('shell', 'am', 'start', '-W', '-n', $activityComponent)
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
    launchActivity = $activityComponent
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
    if (-not $startedProcess.HasExited) { Stop-Process -Id $startedProcess.Id -Force -ErrorAction SilentlyContinue }
}
