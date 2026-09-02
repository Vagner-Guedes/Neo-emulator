[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ApkPath,
    [string]$ReportPath = 'reports/nativebridge.json',
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$config = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\runtime.json') -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($ApkPath)) { $ApkPath = Join-Path $RepositoryRoot 'app.apk' }
if (-not [System.IO.Path]::IsPathRooted($ApkPath)) { $ApkPath = Join-Path $RepositoryRoot $ApkPath }
$adbPath = Join-Path $RepositoryRoot ($config.android.tooling.sdkRoot + '\' + $config.android.tooling.adbRelativePath)
if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB não encontrado em $adbPath. O teste não usa PATH nem baixa ferramentas." }
$serial = "$($config.android.adb.host):$($config.android.adb.hostPort)"
$packageName = $config.neonews.packageName
$activity = "$packageName/$($config.neonews.launchActivity)"

function Invoke-Adb([string[]]$Arguments) {
    $output = & $adbPath @Arguments 2>&1 | Out-String
    return $output.Trim()
}

$null = Invoke-Adb @('start-server')
$null = Invoke-Adb @('connect', $serial)
$deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
$state = ''
$boot = ''
while ((Get-Date).ToUniversalTime() -lt $deadline) {
    $state = Invoke-Adb @('-s', $serial, 'get-state')
    if ($state -eq 'device') {
        $boot = Invoke-Adb @('-s', $serial, 'shell', 'getprop', 'sys.boot_completed')
        if ($boot -eq '1') { break }
    }
    Start-Sleep -Seconds 2
}
if ($state -ne 'device' -or $boot -ne '1') { throw "ADB não ficou pronto. serial=$serial state=$state boot=$boot" }

$property = Invoke-Adb @('-s', $serial, 'shell', 'getprop', 'ro.dalvik.vm.native.bridge')
$guestAbi = Invoke-Adb @('-s', $serial, 'shell', 'getprop', 'ro.product.cpu.abi')
$guestAbiList = Invoke-Adb @('-s', $serial, 'shell', 'getprop', 'ro.product.cpu.abilist')
$abi2 = Invoke-Adb @('-s', $serial, 'shell', 'getprop', 'ro.product.cpu.abi2')
$bridgeReady = -not [string]::IsNullOrWhiteSpace($property) -and $property -ne '0' -and ($guestAbi -in @('x86', 'x86_64'))

$apkAbis = @()
if (Test-Path -LiteralPath $ApkPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ApkPath)
    try {
        $apkAbis = @($archive.Entries | ForEach-Object {
            if ($_.FullName -match '^lib/([^/]+)/') { $Matches[1] }
        } | Sort-Object -Unique)
    }
    finally { $archive.Dispose() }
}

$installOutput = ''
$installSucceeded = $false
if (Test-Path -LiteralPath $ApkPath) {
    $installOutput = Invoke-Adb @('-s', $serial, 'install', '-r', $ApkPath)
    $installSucceeded = $installOutput -match '(?im)\bSuccess\b'
}
$packageDump = Invoke-Adb @('-s', $serial, 'shell', 'dumpsys', 'package', $packageName)
$primaryCpuAbi = if ($packageDump -match 'primaryCpuAbi=([^\s]+)') { $Matches[1] } else { $null }
$launchOutput = ''
$launchSucceeded = $false
if ($installSucceeded -or $packageDump -match "Package \[$([regex]::Escape($packageName))\]") {
    $launchOutput = Invoke-Adb @('-s', $serial, 'shell', 'am', 'start', '-W', '-n', $activity)
    $launchSucceeded = $launchOutput -notmatch '(?im)(Error:|Exception|does not exist)'
}
Start-Sleep -Seconds 10
$activityDump = Invoke-Adb @('-s', $serial, 'shell', 'dumpsys', 'activity', 'activities')
$activityRunning = $activityDump.Contains($activity)
$logcat = Invoke-Adb @('-s', $serial, 'shell', 'logcat', '-d', '-b', 'all', '-t', '240')
$relevantLogcat = @($logcat -split "`r?`n" | Where-Object { $_ -match 'com\.in9midia\.neonews\.player|AndroidRuntime|linker|native bridge|SIGSEGV|FATAL|dex2oat|chromium|WebView' })
$runtimeStable = $bridgeReady -and $installSucceeded -and $launchSucceeded -and $activityRunning -and ($relevantLogcat -notmatch 'UnsatisfiedLinkError|FATAL EXCEPTION|SIGSEGV')

$report = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    transport = 'tcp'
    serial = $serial
    guestAbi = $guestAbi
    guestAbiList = $guestAbiList
    nativeBridgeProperty = $property
    nativeBridgeAbi2 = $abi2
    nativeBridgeReady = $bridgeReady
    apkAbis = $apkAbis
    selectedApkAbi = $primaryCpuAbi
    installSucceeded = $installSucceeded
    primaryCpuAbi = $primaryCpuAbi
    launchSucceeded = $launchSucceeded
    activityRunning = $activityRunning
    runtimeStable = $runtimeStable
    installOutput = $installOutput
    launchOutput = $launchOutput
    relevantLogcat = $relevantLogcat
}
$fullReportPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $RepositoryRoot $ReportPath }
$reportDirectory = Split-Path -Parent $fullReportPath
if (-not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fullReportPath -Encoding utf8
$report | ConvertTo-Json -Depth 8
if (-not $runtimeStable) { throw "Native Bridge não foi homologado: runtimeStable=false. Consulte $fullReportPath." }
