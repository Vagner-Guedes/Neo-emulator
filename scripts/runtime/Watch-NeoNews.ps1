[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Serial,
    [int]$PollSeconds = 5,
    [int]$MaxIterations = 0,
    [switch]$LaunchOnActivityLoss,
    [switch]$Once,
    [switch]$StopWhenUnhealthy,
    [string]$LogPath
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
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $AdbPath -s $Serial @Arguments 2>&1 | Out-String
        return $output.Trim()
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
}

function Get-NeoNewsState {
    param([string]$AdbPath, [string]$PackageName, [string]$ActivityName)

    $state = Invoke-Adb -AdbPath $AdbPath -Arguments @('get-state')
    if ($state -ne 'device') {
        return [pscustomobject]@{ status = 'device-unavailable'; detail = $state; activity = $null }
    }

    $packagePath = Invoke-Adb -AdbPath $AdbPath -Arguments @('shell', 'pm', 'path', $PackageName)
    if ($packagePath -notmatch '^package:') {
        return [pscustomobject]@{ status = 'package-missing'; detail = $packagePath; activity = $null }
    }

    $activityDump = Invoke-Adb -AdbPath $AdbPath -Arguments @('shell', 'dumpsys', 'activity', 'activities')
    $expectedActivity = "$PackageName/.$ActivityName"
    $fullyQualifiedActivity = "$PackageName/$PackageName.$ActivityName"
    $activityPresent = $activityDump -match [regex]::Escape($expectedActivity) -or
                       $activityDump -match [regex]::Escape($fullyQualifiedActivity)
    if ($activityPresent) {
        return [pscustomobject]@{ status = 'healthy'; detail = $expectedActivity; activity = $expectedActivity }
    }

    return [pscustomobject]@{ status = 'activity-lost'; detail = $expectedActivity; activity = $null }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuração não encontrada: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
$sdkRoot = Resolve-SdkRoot
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$adbPath = Join-Path $repositoryRoot (($config.android.tooling.sdkRoot + '\' + $config.android.tooling.adbRelativePath) -replace '/', '\')
if (-not (Test-Path -LiteralPath $adbPath) -and $config.android.tooling.allowEnvironmentFallback) { $adbPath = Join-Path $sdkRoot 'platform-tools\adb.exe' }
if (-not (Test-Path -LiteralPath $adbPath)) {
    throw "ADB não encontrado: $adbPath"
}

$packageName = [string]$config.neonews.packageName
$activityName = [string]$config.neonews.launchActivity
if ($activityName -match '/') { $activityName = ($activityName -split '/')[-1] }
if ($activityName.StartsWith('.')) { $activityName = $activityName.Substring(1) }
if ($activityName.StartsWith("$packageName.", [System.StringComparison]::Ordinal)) { $activityName = $activityName.Substring($packageName.Length + 1) }
$activityComponent = "$packageName/.$activityName"
if ($activityName -match '/') {
    $activityName = $activityName.Split('/')[-1]
}

if (-not $LogPath) {
    $LogPath = Join-Path (Join-Path $PSScriptRoot '..\..\logs') 'supervisor.log'
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

$logDirectory = Split-Path -Parent $LogPath
if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

$iteration = 0
do {
    $iteration++
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $health = Get-NeoNewsState -AdbPath $adbPath -PackageName $packageName -ActivityName $activityName
    $restartAttempted = $false
    $restartResult = $null

    if ($health.status -eq 'activity-lost' -and $LaunchOnActivityLoss) {
        $restartAttempted = $true
        $restartResult = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'am', 'start', '-W', '-n', $activityComponent)
        $health = Get-NeoNewsState -AdbPath $adbPath -PackageName $packageName -ActivityName $activityName
    }

    $event = [ordered]@{
        timestamp = $now
        serial = $Serial
        iteration = $iteration
        packageName = $packageName
        activity = $activityComponent
        status = $health.status
        detail = $health.detail
        restartAttempted = $restartAttempted
        restartResult = $restartResult
    }
    $line = $event | ConvertTo-Json -Compress
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    $line

    if ($StopWhenUnhealthy -and $health.status -ne 'healthy') {
        break
    }

    if ($Once -or ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations)) {
        break
    }

    Start-Sleep -Seconds $PollSeconds
} while ($true)
