[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Serial,
    [int]$BootTimeoutSeconds = 180,
    [string]$ContentUrl,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuração não encontrada: $ConfigPath" }

$configPathFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$repositoryRoot = [System.IO.Directory]::GetParent([System.IO.Directory]::GetParent($configPathFull).FullName).FullName
$config = Get-Content -LiteralPath $configPathFull -Raw -Encoding utf8 | ConvertFrom-Json

function Resolve-ConfiguredPath {
    param([string]$ConfiguredPath)
    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) { return $ConfiguredPath }
    return [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot ($ConfiguredPath -replace '/', '\')))
}

function Invoke-AdbCommand {
    param([string[]]$Arguments)
    $output = & $script:adbPath @Arguments 2>&1
    return (($output | Out-String).Trim())
}

function Invoke-AdbResult {
    param([string[]]$Arguments)
    $output = & $script:adbPath @Arguments 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (($output | Out-String).Trim()) }
}

function Wait-ForBoot {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $state = Invoke-AdbCommand @('-s', $script:Serial, 'get-state')
        if ($state -eq 'device') {
            $bootCompleted = Invoke-AdbCommand @('-s', $script:Serial, 'shell', 'getprop', 'sys.boot_completed')
            if ($bootCompleted -match '(?m)^1$') { return $true }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Test-ActiveWebViewProvider {
    param([string]$Dump, [string]$Provider)
    $currentLine = $Dump -split "`r?`n" |
        Where-Object { $_ -match '(?i)Current WebView package' } |
        Select-Object -First 1
    return $null -ne $currentLine -and $currentLine -match [regex]::Escape($Provider)
}

$adbRelativePath = Join-Path $config.android.tooling.sdkRoot $config.android.tooling.adbRelativePath
$adbPath = Resolve-ConfiguredPath $adbRelativePath
if (-not (Test-Path -LiteralPath $adbPath) -and $config.android.tooling.allowEnvironmentFallback) {
    $fallbackRoot = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    $adbPath = Join-Path $fallbackRoot 'platform-tools\adb.exe'
}
if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB não encontrado em $adbPath. O teste não usa PATH nem baixa ferramentas." }
$script:adbPath = $adbPath

if (-not $Serial) {
    $Serial = if ($config.android.adb.transport -eq 'tcp') {
        "$($config.android.adb.host):$($config.android.adb.hostPort)"
    } elseif ($config.android.adb.emulatorSerial) {
        $config.android.adb.emulatorSerial
    } else {
        "emulator-$($config.android.emulator.validationPort)"
    }
}
$script:Serial = $Serial

$server = Invoke-AdbResult @('start-server')
if ($server.ExitCode -ne 0) { throw "ADB start-server falhou: $($server.Text)" }
if ($config.android.adb.transport -eq 'tcp') { $null = Invoke-AdbCommand @('connect', $Serial) }
if (-not (Wait-ForBoot -TimeoutSeconds $BootTimeoutSeconds)) {
    throw "ADB não ficou pronto no serial $Serial em $BootTimeoutSeconds segundos."
}

$packageName = [string]$config.webView.provider
$webViewDumpResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'dumpsys', 'webviewupdate')
$packageListResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'pm', 'list', 'packages', $packageName)
$packageDumpResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'dumpsys', 'package', $packageName)
if ($webViewDumpResult.ExitCode -ne 0 -or $packageListResult.ExitCode -ne 0 -or $packageDumpResult.ExitCode -ne 0) {
    throw "A consulta do provider WebView falhou: webviewupdate=$($webViewDumpResult.ExitCode); packages=$($packageListResult.ExitCode); package=$($packageDumpResult.ExitCode)."
}
$webViewDump = $webViewDumpResult.Text
$packageList = $packageListResult.Text
$packageDump = $packageDumpResult.Text
$release = Invoke-AdbCommand @('-s', $Serial, 'shell', 'getprop', 'ro.build.version.release')
$api = Invoke-AdbCommand @('-s', $Serial, 'shell', 'getprop', 'ro.build.version.sdk')
$abi = Invoke-AdbCommand @('-s', $Serial, 'shell', 'getprop', 'ro.product.cpu.abi')
$versionMatch = [regex]::Match($packageDump, 'versionName=([^\s]+)')
$installedVersion = if ($versionMatch.Success) { $versionMatch.Groups[1].Value } else { $null }
$primaryCpuAbiMatch = [regex]::Match($packageDump, 'primaryCpuAbi=([^\s]+)')
$primaryCpuAbi = if ($primaryCpuAbiMatch.Success) { $primaryCpuAbiMatch.Groups[1].Value } else { $null }
$expectedVersion = [string]$config.webView.homologatedVersion
$providerPresent = $packageList -match [regex]::Escape("package:$packageName")
$providerActive = Test-ActiveWebViewProvider -Dump $webViewDump -Provider $packageName
$versionMatches = $installedVersion -eq $expectedVersion
$apiMatches = $api -eq [string]$config.android.apiLevel
$nativeGuestAbi = $primaryCpuAbi -in @('x86', 'x86_64')
$nativeAbiMatches = -not [bool]$config.webView.requireNativeGuestAbi -or $nativeGuestAbi

$contentTest = $null
if (-not [string]::IsNullOrWhiteSpace($ContentUrl)) {
    $launchResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', $ContentUrl)
    $launchOutput = $launchResult.Text
    Start-Sleep -Seconds 4
    $activityResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'dumpsys', 'activity', 'activities')
    $activityDump = $activityResult.Text
    $contentLogcat = Invoke-AdbCommand @('-s', $Serial, 'shell', 'logcat', '-d', '-b', 'all', '-t', '160')
    $contentErrors = @($contentLogcat -split "`r?`n" | Where-Object { $_ -match '(?i)WebView|chromium|AndroidRuntime|FATAL|SIGSEGV|net::ERR_' -and $_ -match '(?i)error|exception|fatal|crash|ERR_' })
    $contentSucceeded = $launchResult.ExitCode -eq 0 -and $launchOutput -notmatch '(?i)Error:|Exception|does not exist' -and $activityResult.ExitCode -eq 0 -and $activityDump.Length -gt 0 -and $contentErrors.Count -eq 0
    $contentTest = [ordered]@{
        url = $ContentUrl
        launchSucceeded = $launchResult.ExitCode -eq 0 -and $launchOutput -notmatch '(?i)Error:|Exception|does not exist'
        launchExitCode = $launchResult.ExitCode
        activityObserved = $activityResult.ExitCode -eq 0 -and $activityDump.Length -gt 0
        activityDumpExitCode = $activityResult.ExitCode
        relevantErrors = $contentErrors
        succeeded = $contentSucceeded
        launchOutput = $launchOutput
    }
}

$providerValidated = $providerPresent -and $providerActive -and $versionMatches -and $apiMatches -and $nativeAbiMatches
$status = if ($providerValidated -and ($null -eq $contentTest -or $contentTest.succeeded)) { 'validated' } elseif (-not $providerPresent) { 'missing-provider' } elseif (-not $versionMatches) { 'version-mismatch' } elseif (-not $apiMatches) { 'api-mismatch' } elseif (-not $nativeAbiMatches) { 'non-native-guest-abi' } elseif ($null -ne $contentTest) { 'content-test-failed' } else { 'provider-inactive' }
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    transport = $config.android.adb.transport
    serial = $Serial
    android = [ordered]@{ release = $release; apiLevel = $api; abi = $abi; expectedApiLevel = [string]$config.android.apiLevel }
    provider = [ordered]@{
        packageName = $packageName
        expectedVersion = $expectedVersion
        installedVersion = $installedVersion
        packagePresent = $providerPresent
        providerActive = $providerActive
        versionMatches = $versionMatches
        primaryCpuAbi = $primaryCpuAbi
        nativeGuestAbi = $nativeGuestAbi
        nativeAbiMatches = $nativeAbiMatches
        status = if ($providerValidated) { 'validated' } else { 'not-validated' }
    }
    contentTest = $contentTest
    rawWebViewUpdate = $webViewDump
    status = $status
}

$json = $result | ConvertTo-Json -Depth 10
if ($ReportPath) {
    $reportFullPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $repositoryRoot $ReportPath }
    $reportDirectory = Split-Path -Parent $reportFullPath
    if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
    Set-Content -LiteralPath $reportFullPath -Value $json -Encoding utf8
}
$json
if ($status -ne 'validated') { throw "WebView não foi homologado: status=$status." }
