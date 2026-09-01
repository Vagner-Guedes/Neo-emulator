[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$AvdName,
    [int]$Port = 5556,
    [int]$BootTimeoutSeconds = 180,
    [switch]$StartEmulator,
    [switch]$StopEmulator,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }

function Resolve-SdkRoot {
    if ($env:ANDROID_SDK_ROOT) { return $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { return $env:ANDROID_HOME }
    return (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
}

function Invoke-AdbCommand {
    param([string]$AdbPath, [string]$Serial, [string[]]$Arguments)
    $output = & $AdbPath -s $Serial @Arguments 2>&1
    return (($output | Out-String).Trim())
}

function Wait-ForBoot {
    param([string]$AdbPath, [string]$Serial, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $state = (& $AdbPath -s $Serial get-state 2>$null | Out-String).Trim()
        if ($state -eq 'device') {
            $boot = Invoke-AdbCommand -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', 'getprop', 'sys.boot_completed')
            if ($boot -match '(?m)^1$') { return $true }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-FirstLines {
    param([string]$Text, [int]$Count = 30)
    return @($Text -split "`r?`n" | Select-Object -First $Count)
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuração não encontrada: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
if (-not $AvdName) { $AvdName = $config.android.preferredAvd }
$sdkRoot = Resolve-SdkRoot
$adbPath = Join-Path $sdkRoot 'platform-tools\adb.exe'
$emulatorPath = Join-Path $sdkRoot 'emulator\emulator.exe'
if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB não encontrado: $adbPath" }
$serial = "emulator-$Port"
$startedProcess = $null
$startedAt = $null
$booted = $false

if ($StartEmulator) {
    if (-not (Test-Path -LiteralPath $emulatorPath)) { throw "Emulator não encontrado: $emulatorPath" }
    $env:ANDROID_HOME = $sdkRoot
    $env:ANDROID_SDK_ROOT = $sdkRoot
    $startedAt = Get-Date
    $arguments = @(
        '-avd', $AvdName,
        '-no-window',
        '-gpu', 'swiftshader',
        '-no-boot-anim',
        '-no-snapshot',
        '-accel', 'auto',
        '-timezone', $config.runtime.timezone,
        '-port', $Port
    )
    $startedProcess = Start-Process -FilePath $emulatorPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $booted = Wait-ForBoot -AdbPath $adbPath -Serial $serial -TimeoutSeconds $BootTimeoutSeconds
} else {
    $booted = Wait-ForBoot -AdbPath $adbPath -Serial $serial -TimeoutSeconds 5
}

$bootDurationSeconds = if ($startedAt -and $booted) { [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2) } else { $null }
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    avd = $AvdName
    serial = $serial
    booted = $booted
    bootDurationSeconds = $bootDurationSeconds
    processId = if ($startedProcess) { $startedProcess.Id } else { $null }
    android = [ordered]@{
        release = if ($booted) { Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'getprop', 'ro.build.version.release') } else { $null }
        apiLevel = if ($booted) { Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'getprop', 'ro.build.version.sdk') } else { $null }
        abi = if ($booted) { Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'getprop', 'ro.product.cpu.abi') } else { $null }
        logicalSize = if ($booted) { Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'wm', 'size') } else { $null }
        logicalDensity = if ($booted) { Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'wm', 'density') } else { $null }
    }
    memory = if ($booted) { Get-FirstLines -Text (Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'dumpsys', 'meminfo')) -Count 20 } else { @() }
    graphics = if ($booted) { Get-FirstLines -Text (Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'dumpsys', 'gfxinfo')) -Count 20 } else { @() }
    status = if ($booted) { 'baseline-collected' } else { 'boot-timeout' }
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
    & $adbPath -s $serial emu kill 2>$null | Out-Null
}
