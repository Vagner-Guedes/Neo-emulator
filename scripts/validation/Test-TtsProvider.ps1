[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\..\config\runtime.json'),
    [string]$AvdName,
    [int]$Port = 5556,
    [int]$BootTimeoutSeconds = 180,
    [switch]$StartEmulator,
    [switch]$StopEmulator,
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
        [string]$Serial,
        [string[]]$Arguments
    )

    $output = & $AdbPath -s $Serial @Arguments 2>&1
    return (($output | Out-String).Trim())
}

function Wait-ForBoot {
    param(
        [string]$AdbPath,
        [string]$Serial,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $state = (& $AdbPath -s $Serial get-state 2>$null | Out-String).Trim()
        if ($state -eq 'device') {
            $bootCompleted = Invoke-AdbCommand -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', 'getprop', 'sys.boot_completed')
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

if (-not $AvdName) {
    $AvdName = $config.android.preferredAvd
}

$serial = "emulator-$Port"
$startedProcess = $null
if ($StartEmulator) {
    if (-not (Test-Path -LiteralPath $emulatorPath)) {
        throw "Emulator não encontrado: $emulatorPath"
    }

    $env:ANDROID_HOME = $sdkRoot
    $env:ANDROID_SDK_ROOT = $sdkRoot
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
}

$booted = Wait-ForBoot -AdbPath $adbPath -Serial $serial -TimeoutSeconds $BootTimeoutSeconds
if (-not $booted) {
    throw "O AVD $AvdName não concluiu o boot no serial $serial em $BootTimeoutSeconds segundos."
}

$allPackages = Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'pm', 'list', 'packages')
$candidatePackages = @(
    $allPackages -split "`r?`n" |
        ForEach-Object { $_ -replace '^package:', '' } |
        Where-Object { $_ -match '(?i)(rhvoice|tts|svox|pico|speech)' }
)

$enginePackages = New-Object System.Collections.Generic.List[string]
foreach ($package in $candidatePackages) {
    if (-not $package) {
        continue
    }

    $packageDump = Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'dumpsys', 'package', $package)
    if ($packageDump -match 'android\.intent\.action\.TTS_SERVICE') {
        $enginePackages.Add($package)
    }
}

$defaultEngine = Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'settings', 'get', 'secure', 'tts_default_synth')
$serviceList = Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'service', 'list')
$rhvoicePresent = (($enginePackages -join "`n") -match '(?i)rhvoice')
$locale = [string]$config.tts.locale
$engineName = [string]$config.tts.engine

$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    avd = $AvdName
    serial = $serial
    android = [ordered]@{
        release = (Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'getprop', 'ro.build.version.release'))
        apiLevel = (Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'getprop', 'ro.build.version.sdk'))
        abi = (Invoke-AdbCommand -AdbPath $adbPath -Serial $serial -Arguments @('shell', 'getprop', 'ro.product.cpu.abi'))
    }
    requested = [ordered]@{
        engine = $engineName
        locale = $locale
    }
    detected = [ordered]@{
        rhvoicePresent = $rhvoicePresent
        enginePackages = @($enginePackages)
        defaultEngine = $defaultEngine
        textToSpeechService = ($serviceList -match '(?i)texttospeech|tts')
    }
    status = if ($rhvoicePresent) { 'engine-present-locale-pending' } else { 'missing-engine' }
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

