[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$Serial,
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
    $output = & $AdbPath -P $script:adbServerPort -s $Serial @Arguments 2>&1
    return (($output | Out-String).Trim())
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuração não encontrada: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
$script:adbServerPort = [int]$config.android.adb.serverPort
$configPathFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$runtimeRoot = [System.IO.Directory]::GetParent([System.IO.Directory]::GetParent($configPathFull).FullName).FullName
if (-not [string]::IsNullOrWhiteSpace($ReportPath) -and -not [System.IO.Path]::IsPathRooted($ReportPath)) {
    $ReportPath = Join-Path $runtimeRoot ($ReportPath -replace '/', '\')
}
$sdkRoot = Resolve-SdkRoot
$adbPath = Join-Path $runtimeRoot (($config.android.tooling.sdkRoot + '\' + $config.android.tooling.adbRelativePath) -replace '/', '\')
if (-not (Test-Path -LiteralPath $adbPath) -and $config.android.tooling.allowEnvironmentFallback) { $adbPath = Join-Path $sdkRoot 'platform-tools\adb.exe' }
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

$state = Invoke-Adb -AdbPath $adbPath -Arguments @('get-state')
if ($state -ne 'device') {
    throw "Dispositivo não está disponível no serial $Serial. Estado: $state"
}

$kiosk = $config.android.kiosk
if (-not $kiosk) {
    throw 'A seção android.kiosk não está definida na configuração.'
}

$commands = @(
    ,@('shell', 'settings', 'put', 'global', 'stay_on_while_plugged_in', [string]$kiosk.stayAwakePluggedIn)
    ,@('shell', 'settings', 'put', 'system', 'screen_off_timeout', [string]$kiosk.screenOffTimeoutMs)
    ,@('shell', 'settings', 'put', 'secure', 'screensaver_enabled', '0')
    ,@('shell', 'settings', 'put', 'secure', 'immersive_mode_confirmations', 'confirmed')
    ,@('shell', 'settings', 'put', 'global', 'policy_control', [string]$kiosk.immersivePolicy)
    ,@('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
    ,@('shell', 'settings', 'put', 'system', 'user_rotation', '1')
    ,@('shell', 'wm', 'size', [string]$kiosk.displaySize)
    ,@('shell', 'wm', 'density', [string]$kiosk.displayDensity)
)

if ($config.android.guestConfiguration.ui.disableTaskbar) {
    $commands += ,@('shell', 'pm', 'disable-user', '--user', '0', [string]$config.android.guestConfiguration.ui.taskbarPackageName)
}
if ($config.android.guestConfiguration.disableNeoNewsBootReceiver) {
    $commands += ,@('shell', 'pm', 'disable', '--user', '0', [string]$config.android.guestConfiguration.neoNewsBootReceiver)
}

$commandResults = @()
foreach ($command in $commands) {
    $description = $command -join ' '
    $result = if ($PSCmdlet.ShouldProcess($Serial, "executar adb $description")) {
        Invoke-Adb -AdbPath $adbPath -Arguments $command
    } else {
        'WHATIF'
    }
    $commandResults += [pscustomobject]@{ command = $description; result = $result }
}

$packageName = [string]$config.neonews.packageName
$packageInstalled = $false
if (-not $WhatIfPreference) {
    $packageInstalled = (Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'pm', 'path', $packageName)) -match '^package:'
}

$displaySize = $null
$displayDensity = $null
$immersivePolicy = $null
$screenOffTimeoutMs = $null
if (-not $WhatIfPreference) {
    $displaySize = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'wm', 'size')
    $displayDensity = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'wm', 'density')
    $immersivePolicy = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'settings', 'get', 'global', 'policy_control')
    $screenOffTimeoutMs = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'settings', 'get', 'system', 'screen_off_timeout')
}

$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    serial = $Serial
    packageName = $packageName
    packageInstalled = $packageInstalled
    displaySize = $displaySize
    displayDensity = $displayDensity
    immersivePolicy = $immersivePolicy
    screenOffTimeoutMs = $screenOffTimeoutMs
    commandResults = @($commandResults)
    status = if ($WhatIfPreference) { 'whatif' } elseif ($packageInstalled) { 'kiosk-applied-package-present' } else { 'kiosk-applied-package-absent' }
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
