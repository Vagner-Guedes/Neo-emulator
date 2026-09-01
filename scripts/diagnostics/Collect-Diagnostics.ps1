[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Serial = 'emulator-5556',
    [int]$MaxLogLines = 120,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $PSScriptRoot '..\..\reports\diagnostics.json' }

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

function Get-FirstLines {
    param([string]$Text, [int]$Count)
    return @($Text -split "`r?`n" | Select-Object -First $Count)
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

$os = Get-CimInstance Win32_OperatingSystem
$computer = Get-CimInstance Win32_ComputerSystem
$processor = Get-CimInstance Win32_Processor | Select-Object -First 1
$systemDrive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
$deviceState = (& $adbPath -s $Serial get-state 2>&1 | Out-String).Trim()
$device = $null

if ($deviceState -eq 'device') {
    $packageName = [string]$config.neonews.packageName
    $packageDump = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'dumpsys', 'package', $packageName)
    $device = [ordered]@{
        state = $deviceState
        release = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'getprop', 'ro.build.version.release')
        apiLevel = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'getprop', 'ro.build.version.sdk')
        abi = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'getprop', 'ro.product.cpu.abi')
        fingerprint = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'getprop', 'ro.build.fingerprint')
        bootCompleted = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'getprop', 'sys.boot_completed')
        displaySize = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'wm', 'size')
        displayDensity = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'wm', 'density')
        packagePath = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'pm', 'path', $packageName)
        packageSummary = @(Get-FirstLines -Text (($packageDump -split "`r?`n" | Where-Object { $_ -match 'versionName=|versionCode=|nativeLibraryDir=' }) -join "`n") -Count 20)
        webView = @(Get-FirstLines -Text (Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'dumpsys', 'webviewupdate')) -Count 80)
        ttsDefault = Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'settings', 'get', 'secure', 'tts_default_synth')
        ttsPackages = @((Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'pm', 'list', 'packages')) -split "`r?`n" | Where-Object { $_ -match '(?i)(rhvoice|tts|svox|pico|speech)' })
        memory = @(Get-FirstLines -Text (Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'dumpsys', 'meminfo')) -Count 40)
        graphics = @(Get-FirstLines -Text (Invoke-Adb -AdbPath $adbPath -Arguments @('shell', 'dumpsys', 'gfxinfo')) -Count 40)
        logcat = @(Get-FirstLines -Text (Invoke-Adb -AdbPath $adbPath -Arguments @('logcat', '-d', '-b', 'all', '-t', $MaxLogLines)) -Count $MaxLogLines)
    }
} else {
    $device = [ordered]@{
        state = $deviceState
        status = 'device-unavailable'
    }
}

$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    runtime = $config.runtime
    host = [ordered]@{
        computerName = $env:COMPUTERNAME
        os = $os.Caption
        osVersion = $os.Version
        processor = $processor.Name
        logicalProcessors = $computer.NumberOfLogicalProcessors
        memoryBytes = [int64]$computer.TotalPhysicalMemory
        freeSpaceCBytes = if ($systemDrive) { [int64]$systemDrive.Free } else { $null }
    }
    sdk = [ordered]@{
        root = $sdkRoot
        adb = $adbPath
        adbVersion = ((& $adbPath version 2>&1 | Out-String).Trim())
    }
    device = $device
    status = if ($deviceState -eq 'device') { 'collected' } else { 'host-only' }
}

$json = $result | ConvertTo-Json -Depth 10
if ($ReportPath) {
    $reportDirectory = Split-Path -Parent $ReportPath
    if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) {
        New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    }
    Set-Content -LiteralPath $ReportPath -Value $json -Encoding utf8
}

$json
