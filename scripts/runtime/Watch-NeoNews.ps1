[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\..\config\runtime.json'),
    [string]$Serial = 'emulator-5556',
    [int]$PollSeconds = 5,
    [int]$MaxIterations = 0,
    [switch]$LaunchOnActivityLoss,
    [switch]$Once,
    [switch]$StopWhenUnhealthy,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

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
    $expectedActivity = "$PackageName/$ActivityName"
    $activityPresent = $activityDump -match [regex]::Escape($expectedActivity)
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
$adbPath = Join-Path $sdkRoot 'platform-tools\adb.exe'
if (-not (Test-Path -LiteralPath $adbPath)) {
    throw "ADB não encontrado: $adbPath"
}

$packageName = [string]$config.neonews.packageName
$activityName = [string]$config.neonews.launchActivity
if ($activityName -match '/') {
    $activityName = $activityName.Split('/')[-1]
}

if (-not $LogPath) {
    $LogPath = Join-Path (Join-Path $PSScriptRoot '..\..\logs') 'supervisor.log'
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
        $restartResult = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'am', 'start', '-W', '-n', "$packageName/$activityName")
        $health = Get-NeoNewsState -AdbPath $adbPath -PackageName $packageName -ActivityName $activityName
    }

    $event = [ordered]@{
        timestamp = $now
        serial = $Serial
        iteration = $iteration
        packageName = $packageName
        activity = "$packageName/$activityName"
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
