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
if ($StabilitySeconds -lt 1) { throw 'StabilitySeconds precisa ser pelo menos 1 segundo.' }
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

function Invoke-AdbResult([string[]]$Arguments) {
    $output = & $adbPath @Arguments 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (($output | Out-String).Trim()) }
}

function Invoke-Adb([string[]]$Arguments) {
    return (Invoke-AdbResult $Arguments).Text
}

function Test-ActivityRunning([string]$Dump) {
    $candidates = @(
        $activity,
        "$packageName/.$activityName",
        "$packageName/$packageName.$activityName"
    )
    $foregroundMarkers = 'mResumedActivity|topResumedActivity|ResumedActivity|mFocusedActivity|mCurrentFocus'
    return @($Dump -split "`r?`n" | Where-Object {
        $line = $_
        ($line -match "(?i)$foregroundMarkers") -and @($candidates | Where-Object { $_ -and $line.IndexOf([string]$_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0
    }).Count -gt 0
}

$serverResult = Invoke-AdbResult @('start-server')
if ($serverResult.ExitCode -ne 0) { throw "ADB start-server falhou: $($serverResult.Text)" }
$null = Invoke-AdbResult @('connect', $serial)
$deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
$state = ''
$boot = ''
while ((Get-Date).ToUniversalTime() -lt $deadline) {
    if ($serial -match ':') { $null = Invoke-Adb @('connect', $serial) }
    $stateResult = Invoke-AdbResult @('-s', $serial, 'get-state')
    $state = $stateResult.Text
    if ($stateResult.ExitCode -eq 0 -and $state -eq 'device') {
        $bootResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'sys.boot_completed')
        $boot = $bootResult.Text
        if ($bootResult.ExitCode -eq 0 -and $boot -eq '1') { break }
    }
    Start-Sleep -Seconds 2
}
if ($state -ne 'device' -or $boot -ne '1') { throw "ADB não ficou pronto. serial=$serial state=$state boot=$boot" }

$propertyResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'ro.dalvik.vm.native.bridge')
$guestAbiResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'ro.product.cpu.abi')
$guestAbiListResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'ro.product.cpu.abilist')
$abi2Result = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'ro.product.cpu.abi2')
$releaseResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'ro.build.version.release')
$apiLevelResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'ro.build.version.sdk')
$property = $propertyResult.Text
$guestAbi = $guestAbiResult.Text
$guestAbiList = $guestAbiListResult.Text
$abi2 = $abi2Result.Text
$release = $releaseResult.Text
$apiLevel = $apiLevelResult.Text
$propertyExitCodes = @($propertyResult, $guestAbiResult, $guestAbiListResult, $abi2Result, $releaseResult, $apiLevelResult) | ForEach-Object { [int]$_.ExitCode }
$guestPropertiesReadable = @($propertyExitCodes | Where-Object { $_ -ne 0 }).Count -eq 0
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
    $installResult = Invoke-AdbResult @('-s', $serial, 'install', '-r', $ApkPath)
    $installOutput = $installResult.Text
    $installExitCode = $installResult.ExitCode
    $installSucceeded = $installExitCode -eq 0 -and $installOutput -match '(?im)\bSuccess\b'
}
$packageDumpResult = Invoke-AdbResult @('-s', $serial, 'shell', 'dumpsys', 'package', $packageName)
$packageDump = $packageDumpResult.Text
$packageDumpExitCode = $packageDumpResult.ExitCode
$primaryCpuAbi = if ($packageDump -match 'primaryCpuAbi=([^\s]+)') { $Matches[1] } else { $null }
$preferredApkAbi = if ($config.android.nativeBridge.preferredAbi) { [string]$config.android.nativeBridge.preferredAbi } else { [string]$config.android.preferredApkAbi }
$selectedApkAbi = if ($primaryCpuAbi -and $apkAbis -contains $primaryCpuAbi -and $primaryCpuAbi -eq $preferredApkAbi) { $primaryCpuAbi } else { $null }
$launchOutput = ''
$launchSucceeded = $false
if ($installSucceeded -or $packageDump -match "Package \[$([regex]::Escape($packageName))\]") {
    $launchResult = Invoke-AdbResult @('-s', $serial, 'shell', 'am', 'start', '-W', '-n', $activity)
    $launchOutput = $launchResult.Text
    $launchExitCode = $launchResult.ExitCode
    $launchSucceeded = $launchExitCode -eq 0 -and $launchOutput -notmatch '(?im)(Error:|Exception|does not exist)'
}
Start-Sleep -Seconds ([math]::Max(1, $StabilitySeconds))
$activityDumpResult = Invoke-AdbResult @('-s', $serial, 'shell', 'dumpsys', 'activity', 'activities')
$activityDump = $activityDumpResult.Text
$activityDumpExitCode = $activityDumpResult.ExitCode
$activityRunning = $activityDumpExitCode -eq 0 -and (Test-ActivityRunning $activityDump)
$logcatResult = Invoke-AdbResult @('-s', $serial, 'shell', 'logcat', '-d', '-b', 'all', '-t', '240')
$logcat = $logcatResult.Text
$logcatExitCode = $logcatResult.ExitCode
$relevantLogcat = @($logcat -split "`r?`n" | Where-Object { $_ -match 'com\.in9midia\.neonews\.player|AndroidRuntime|linker|native bridge|SIGSEGV|FATAL|dex2oat|chromium|WebView' })
$failurePattern = 'UnsatisfiedLinkError|linker.*(error|fail)|SIGSEGV|FATAL EXCEPTION|dex2oat.*(error|fail)|zygote.*(error|fail)|chromium.*(error|fail)|WebView.*(error|fail)'
$initialErrors = @($relevantLogcat | Where-Object { $_ -match $failurePattern })
$runtimeStable = $guestPropertiesReadable -and $guestIdentityMatches -and $bridgeReady -and $installSucceeded -and $packageDumpExitCode -eq 0 -and $selectedApkAbi -and $launchSucceeded -and $activityRunning -and $logcatExitCode -eq 0 -and $initialErrors.Count -eq 0

$restartResults = New-Object System.Collections.Generic.List[object]
for ($restart = 1; $restart -le [math]::Max(0, $RestartCount) -and $runtimeStable; $restart++) {
    $rebootResult = Invoke-AdbResult @('-s', $serial, 'shell', 'reboot')
    $rebootOutput = $rebootResult.Text
    $rebootExitCode = $rebootResult.ExitCode
    $rebootBooted = $false
    $rebootDeadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    do {
        if ($serial -match ':') { $null = Invoke-Adb @('connect', $serial) }
        $rebootStateResult = Invoke-AdbResult @('-s', $serial, 'get-state')
        $rebootState = $rebootStateResult.Text
        if ($rebootStateResult.ExitCode -eq 0 -and $rebootState -eq 'device') {
            $rebootBootResult = Invoke-AdbResult @('-s', $serial, 'shell', 'getprop', 'sys.boot_completed')
            $rebootBoot = $rebootBootResult.Text
            if ($rebootBootResult.ExitCode -eq 0 -and $rebootBoot -eq '1') { $rebootBooted = $true; break }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date).ToUniversalTime() -lt $rebootDeadline)

    $relaunchOutput = ''
    $relaunchExitCode = $null
    $relaunchSucceeded = $false
    $relaunchActivityRunning = $false
    $relaunchErrors = @()
    $relaunchActivityDumpExitCode = $null
    $relaunchLogcatExitCode = $null
    if ($rebootBooted) {
        $relaunchResult = Invoke-AdbResult @('-s', $serial, 'shell', 'am', 'start', '-W', '-n', $activity)
        $relaunchOutput = $relaunchResult.Text
        $relaunchExitCode = $relaunchResult.ExitCode
        $relaunchSucceeded = $relaunchExitCode -eq 0 -and $relaunchOutput -notmatch '(?im)(Error:|Exception|does not exist)'
        Start-Sleep -Seconds ([math]::Max(1, $StabilitySeconds))
        $relaunchActivityDumpResult = Invoke-AdbResult @('-s', $serial, 'shell', 'dumpsys', 'activity', 'activities')
        $relaunchActivityDumpExitCode = $relaunchActivityDumpResult.ExitCode
        $relaunchActivityRunning = $relaunchActivityDumpExitCode -eq 0 -and (Test-ActivityRunning $relaunchActivityDumpResult.Text)
        $relaunchLogcatResult = Invoke-AdbResult @('-s', $serial, 'shell', 'logcat', '-d', '-b', 'all', '-t', '240')
        $relaunchLogcatExitCode = $relaunchLogcatResult.ExitCode
        $relaunchErrors = @($relaunchLogcatResult.Text -split "`r?`n" | Where-Object { $_ -match $failurePattern })
    }
    $restartResults.Add([ordered]@{
        iteration = $restart
        rebootOutput = $rebootOutput
        rebootExitCode = $rebootExitCode
        booted = $rebootBooted
        launchSucceeded = $relaunchSucceeded
        launchExitCode = if ($null -ne $relaunchExitCode) { [int]$relaunchExitCode } else { $null }
        activityRunning = $relaunchActivityRunning
        activityDumpExitCode = $relaunchActivityDumpExitCode
        logcatExitCode = $relaunchLogcatExitCode
        relevantErrors = $relaunchErrors
        stable = $rebootExitCode -eq 0 -and $rebootBooted -and $relaunchSucceeded -and $relaunchActivityDumpExitCode -eq 0 -and $relaunchActivityRunning -and $relaunchLogcatExitCode -eq 0 -and $relaunchErrors.Count -eq 0
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
    stabilitySeconds = $StabilitySeconds
    guestPropertyExitCodes = $propertyExitCodes
    installExitCode = if ($null -ne $installExitCode) { [int]$installExitCode } else { $null }
    packageDumpExitCode = if ($null -ne $packageDumpExitCode) { [int]$packageDumpExitCode } else { $null }
    launchExitCode = if ($null -ne $launchExitCode) { [int]$launchExitCode } else { $null }
    activityDumpExitCode = $activityDumpExitCode
    logcatExitCode = $logcatExitCode
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
