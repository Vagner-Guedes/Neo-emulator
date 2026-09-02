[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ApkPath,
    [string]$ReportPath = 'reports/nativebridge.json',
    [int]$TimeoutSeconds = 180,
    [int]$StabilitySeconds = 10,
    [int]$RestartCount = 1
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$config = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\runtime.json') -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($ApkPath)) { $ApkPath = Join-Path $RepositoryRoot 'app.apk' }
if (-not [System.IO.Path]::IsPathRooted($ApkPath)) { $ApkPath = Join-Path $RepositoryRoot $ApkPath }
if (-not (Test-Path -LiteralPath $ApkPath)) { throw "APK oficial não encontrado: $ApkPath" }
$adbPath = Join-Path $RepositoryRoot ($config.android.tooling.sdkRoot + '\' + $config.android.tooling.adbRelativePath)
if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB não encontrado em $adbPath. O teste não usa PATH nem baixa ferramentas." }
$serial = "$($config.android.adb.host):$($config.android.adb.hostPort)"
$packageName = $config.neonews.packageName
$activityName = [string]$config.neonews.launchActivity
if ($activityName -match '/') { $activityName = ($activityName -split '/')[-1] }
if ($activityName.StartsWith('.')) { $activityName = $activityName.Substring(1) }
if ($activityName.StartsWith("$packageName.", [System.StringComparison]::Ordinal)) { $activityName = $activityName.Substring($packageName.Length + 1) }
$activity = "$packageName/.$activityName"

function Invoke-Adb([string[]]$Arguments) {
    $output = & $adbPath @Arguments 2>&1 | Out-String
    return $output.Trim()
}

function Test-ActivityRunning([string]$Dump) {
    return $Dump.Contains($activity) -or $Dump.Contains("$packageName/.$activityName")
}

$null = Invoke-Adb @('start-server')
$null = Invoke-Adb @('connect', $serial)
$deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
$state = ''
$boot = ''
while ((Get-Date).ToUniversalTime() -lt $deadline) {
    if ($serial -match ':') { $null = Invoke-Adb @('connect', $serial) }
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
$release = Invoke-Adb @('-s', $serial, 'shell', 'getprop', 'ro.build.version.release')
$apiLevel = Invoke-Adb @('-s', $serial, 'shell', 'getprop', 'ro.build.version.sdk')
$guestIdentityMatches = $release -eq [string]$config.android.release -and $apiLevel -eq [string]$config.android.apiLevel
$bridgeReady = -not [string]::IsNullOrWhiteSpace($property) -and $property -ne '0' -and ($guestAbi -in @('x86', 'x86_64')) -and $guestAbiList -match '(?i)(^|,)(x86|x86_64)(,|$)'

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
$preferredApkAbi = if ($config.android.nativeBridge.preferredAbi) { [string]$config.android.nativeBridge.preferredAbi } else { [string]$config.android.preferredApkAbi }
$selectedApkAbi = if ($primaryCpuAbi -and $apkAbis -contains $primaryCpuAbi -and $primaryCpuAbi -eq $preferredApkAbi) { $primaryCpuAbi } else { $null }
$launchOutput = ''
$launchSucceeded = $false
if ($installSucceeded -or $packageDump -match "Package \[$([regex]::Escape($packageName))\]") {
    $launchOutput = Invoke-Adb @('-s', $serial, 'shell', 'am', 'start', '-W', '-n', $activity)
    $launchSucceeded = $launchOutput -notmatch '(?im)(Error:|Exception|does not exist)'
}
Start-Sleep -Seconds ([math]::Max(1, $StabilitySeconds))
$activityDump = Invoke-Adb @('-s', $serial, 'shell', 'dumpsys', 'activity', 'activities')
$activityRunning = Test-ActivityRunning $activityDump
$logcat = Invoke-Adb @('-s', $serial, 'shell', 'logcat', '-d', '-b', 'all', '-t', '240')
$relevantLogcat = @($logcat -split "`r?`n" | Where-Object { $_ -match 'com\.in9midia\.neonews\.player|AndroidRuntime|linker|native bridge|SIGSEGV|FATAL|dex2oat|chromium|WebView' })
$failurePattern = 'UnsatisfiedLinkError|linker.*(error|fail)|SIGSEGV|FATAL EXCEPTION|dex2oat.*(error|fail)|zygote.*(error|fail)|chromium.*(error|fail)|WebView.*(error|fail)'
$initialErrors = @($relevantLogcat | Where-Object { $_ -match $failurePattern })
$runtimeStable = $guestIdentityMatches -and $bridgeReady -and $installSucceeded -and $selectedApkAbi -and $launchSucceeded -and $activityRunning -and $initialErrors.Count -eq 0

$restartResults = New-Object System.Collections.Generic.List[object]
for ($restart = 1; $restart -le [math]::Max(0, $RestartCount) -and $runtimeStable; $restart++) {
    $rebootOutput = Invoke-Adb @('-s', $serial, 'shell', 'reboot')
    $rebootBooted = $false
    $rebootDeadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    do {
        if ($serial -match ':') { $null = Invoke-Adb @('connect', $serial) }
        $rebootState = Invoke-Adb @('-s', $serial, 'get-state')
        if ($rebootState -eq 'device') {
            $rebootBoot = Invoke-Adb @('-s', $serial, 'shell', 'getprop', 'sys.boot_completed')
            if ($rebootBoot -eq '1') { $rebootBooted = $true; break }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date).ToUniversalTime() -lt $rebootDeadline)

    $relaunchOutput = ''
    $relaunchSucceeded = $false
    $relaunchActivityRunning = $false
    $relaunchErrors = @()
    if ($rebootBooted) {
        $relaunchOutput = Invoke-Adb @('-s', $serial, 'shell', 'am', 'start', '-W', '-n', $activity)
        $relaunchSucceeded = $relaunchOutput -notmatch '(?im)(Error:|Exception|does not exist)'
        Start-Sleep -Seconds ([math]::Max(1, $StabilitySeconds))
        $relaunchActivityDump = Invoke-Adb @('-s', $serial, 'shell', 'dumpsys', 'activity', 'activities')
        $relaunchActivityRunning = Test-ActivityRunning $relaunchActivityDump
        $relaunchLogcat = Invoke-Adb @('-s', $serial, 'shell', 'logcat', '-d', '-b', 'all', '-t', '240')
        $relaunchErrors = @($relaunchLogcat -split "`r?`n" | Where-Object { $_ -match $failurePattern })
    }
    $restartResults.Add([ordered]@{
        iteration = $restart
        rebootOutput = $rebootOutput
        booted = $rebootBooted
        launchSucceeded = $relaunchSucceeded
        activityRunning = $relaunchActivityRunning
        relevantErrors = $relaunchErrors
        stable = $rebootBooted -and $relaunchSucceeded -and $relaunchActivityRunning -and $relaunchErrors.Count -eq 0
    })
}
$restartStable = @($restartResults | Where-Object { -not $_.stable }).Count -eq 0
$runtimeStable = $runtimeStable -and $restartStable

$report = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    transport = 'tcp'
    serial = $serial
    androidRelease = $release
    androidApiLevel = $apiLevel
    guestIdentityMatches = $guestIdentityMatches
    guestAbi = $guestAbi
    guestAbiList = $guestAbiList
    nativeBridgeProperty = $property
    nativeBridgeAbi2 = $abi2
    nativeBridgeReady = $bridgeReady
    apkAbis = $apkAbis
    selectedApkAbi = $selectedApkAbi
    installSucceeded = $installSucceeded
    primaryCpuAbi = $primaryCpuAbi
    launchSucceeded = $launchSucceeded
    activityRunning = $activityRunning
    runtimeStable = $runtimeStable
    restartCount = [math]::Max(0, $RestartCount)
    restartResults = @($restartResults)
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
