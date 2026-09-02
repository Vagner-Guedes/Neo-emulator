[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Serial,
    [string]$SdkRoot,
    [string]$ContentUrl = 'https://example.com',
    [int]$BootTimeoutSeconds = 180,
    [int]$ContentTimeoutSeconds = 90,
    [string]$ReportPath = 'reports/webview-content.json',
    [switch]$KeepProbe,
    [switch]$CleanupProbe,
    [switch]$BuildOnly
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuração não encontrada: $ConfigPath" }

$configPathFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$repositoryRoot = [System.IO.Directory]::GetParent([System.IO.Directory]::GetParent($configPathFull).FullName).FullName
$scriptRepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $scriptRepositoryRoot 'scripts\validation\ValidationEvidence.Common.ps1')
$reportFullPath = Initialize-ValidationReport -ReportPath (Resolve-ValidationReportPath -RepositoryRoot $repositoryRoot -ReportPath $ReportPath) -Validator 'Test-WebViewContent'
if ($ContentUrl -notmatch '^https://') { throw "ContentUrl precisa usar HTTPS: $ContentUrl" }
$config = Get-Content -LiteralPath $configPathFull -Raw -Encoding utf8 | ConvertFrom-Json
$probePackage = 'com.neonews.runtime.webviewprobe'

function Resolve-ConfiguredPath {
    param([string]$ConfiguredPath)
    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) { return $ConfiguredPath }
    return [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot ($ConfiguredPath -replace '/', '\')))
}

function Invoke-External {
    param([string]$Executable, [string[]]$Arguments)
    $output = & $Executable @Arguments 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (($output | Out-String).Trim()) }
}

function Invoke-Adb {
    param([string[]]$Arguments)
    Invoke-External -Executable $script:adbPath -Arguments $Arguments
}

function Wait-ForBoot {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $state = (Invoke-Adb @('-s', $script:Serial, 'get-state')).Text
        if ($state -eq 'device') {
            $boot = (Invoke-Adb @('-s', $script:Serial, 'shell', 'getprop', 'sys.boot_completed')).Text
            if ($boot -match '(?m)^1$') { return $true }
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

if ([string]::IsNullOrWhiteSpace($SdkRoot)) {
    $SdkRoot = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
}
$androidJar = Join-Path $SdkRoot 'platforms\android-25\android.jar'
$buildTools = Join-Path $SdkRoot 'build-tools\25.0.3'
$javaRoot = $env:JAVA_HOME
$javacPath = if ($javaRoot) { Join-Path $javaRoot 'bin\javac.exe' } else { (Get-Command javac -ErrorAction SilentlyContinue).Source }
$javaPath = if ($javaRoot) { Join-Path $javaRoot 'bin\java.exe' } else { (Get-Command java -ErrorAction SilentlyContinue).Source }
$jarPath = if ($javaRoot) { Join-Path $javaRoot 'bin\jar.exe' } else { (Get-Command jar -ErrorAction SilentlyContinue).Source }
$keytoolPath = if ($javaRoot) { Join-Path $javaRoot 'bin\keytool.exe' } else { (Get-Command keytool -ErrorAction SilentlyContinue).Source }
if ([string]::IsNullOrWhiteSpace($javaRoot) -and $javacPath) { $javaRoot = Split-Path -Parent (Split-Path -Parent $javacPath) }
if ([string]::IsNullOrWhiteSpace($javaPath) -and $javaRoot) { $javaPath = Join-Path $javaRoot 'bin\java.exe' }
if ([string]::IsNullOrWhiteSpace($jarPath) -and $javaRoot) { $jarPath = Join-Path $javaRoot 'bin\jar.exe' }
if ([string]::IsNullOrWhiteSpace($keytoolPath) -and $javaRoot) { $keytoolPath = Join-Path $javaRoot 'bin\keytool.exe' }
if ($javaRoot -and (Test-Path -LiteralPath (Join-Path $javaRoot 'bin\java.exe'))) {
    $env:JAVA_HOME = $javaRoot
    $env:Path = (Join-Path $javaRoot 'bin') + ';' + $env:Path
}
$aaptPath = Join-Path $buildTools 'aapt.exe'
$dxJar = Join-Path $buildTools 'lib\dx.jar'
$apksignerPath = Join-Path $buildTools 'apksigner.bat'
foreach ($requiredTool in @(@{ Name = 'android.jar'; Path = $androidJar }, @{ Name = 'java'; Path = $javaPath }, @{ Name = 'javac'; Path = $javacPath }, @{ Name = 'jar'; Path = $jarPath }, @{ Name = 'keytool'; Path = $keytoolPath }, @{ Name = 'aapt'; Path = $aaptPath }, @{ Name = 'dx.jar'; Path = $dxJar }, @{ Name = 'apksigner'; Path = $apksignerPath })) {
    if ([string]::IsNullOrWhiteSpace($requiredTool.Path) -or -not (Test-Path -LiteralPath $requiredTool.Path)) { throw "$($requiredTool.Name) não encontrado: $($requiredTool.Path)." }
}

$adbRelativePath = Join-Path $config.android.tooling.sdkRoot $config.android.tooling.adbRelativePath
$adbPath = Resolve-ConfiguredPath $adbRelativePath
if (-not (Test-Path -LiteralPath $adbPath) -and $config.android.tooling.allowEnvironmentFallback) { $adbPath = Join-Path $SdkRoot 'platform-tools\adb.exe' }
if (-not (Test-Path -LiteralPath $adbPath) -and -not $BuildOnly) { throw "ADB não encontrado em $adbPath." }
$script:adbPath = $adbPath
if (-not $Serial) { $Serial = if ($config.android.adb.transport -eq 'tcp') { "$($config.android.adb.host):$($config.android.adb.hostPort)" } elseif ($config.android.adb.emulatorSerial) { $config.android.adb.emulatorSerial } else { "emulator-$($config.android.emulator.validationPort)" } }
$script:Serial = $Serial

$probeRoot = Join-Path $scriptRepositoryRoot 'tools\webview-probe'
$buildRoot = Join-Path $probeRoot 'build'
$classesRoot = Join-Path $buildRoot 'classes'
$unsignedApk = Join-Path $buildRoot 'webview-probe-unsigned.apk'
$probeApk = Join-Path $buildRoot 'webview-probe.apk'
$classesDex = Join-Path $buildRoot 'classes.dex'
New-Item -ItemType Directory -Path $classesRoot -Force | Out-Null
& $javacPath -source 7 -target 7 -classpath $androidJar -d $classesRoot (Join-Path $probeRoot 'MainActivity.java')
if ($LASTEXITCODE -ne 0) { throw 'Falha ao compilar o probe WebView.' }
& $javaPath '-jar' $dxJar '--dex' "--output=$classesDex" $classesRoot
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $classesDex)) { throw "Falha ao gerar classes.dex do probe WebView. Verifique Java/DX em $javaRoot." }
& $aaptPath 'package' '-f' '-M' (Join-Path $probeRoot 'AndroidManifest.xml') '-I' $androidJar '-F' $unsignedApk
if ($LASTEXITCODE -ne 0) { throw 'Falha ao empacotar o probe WebView.' }
& $jarPath 'uf' $unsignedApk '-C' $buildRoot 'classes.dex'
if ($LASTEXITCODE -ne 0) { throw 'Falha ao adicionar classes.dex ao probe WebView.' }
$keystorePath = Join-Path $buildRoot 'debug.keystore'
if (-not (Test-Path -LiteralPath $keystorePath)) {
    & $keytoolPath '-genkeypair' '-keystore' $keystorePath '-storepass' 'android' '-keypass' 'android' '-alias' 'androiddebugkey' '-dname' 'CN=Android Debug,O=Android,C=US' '-keyalg' 'RSA' '-keysize' '2048' '-validity' '10000'
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao gerar a chave temporária do probe WebView.' }
}
& $apksignerPath 'sign' '--ks' $keystorePath '--ks-pass' 'pass:android' '--key-pass' 'pass:android' '--out' $probeApk $unsignedApk
if ($LASTEXITCODE -ne 0) { throw 'Falha ao assinar o probe WebView.' }
& $apksignerPath 'verify' $probeApk
if ($LASTEXITCODE -ne 0) { throw 'A verificação da assinatura do probe WebView falhou.' }
if ($BuildOnly) { [ordered]@{ status = 'probe-built'; apk = $probeApk; package = $probePackage } | ConvertTo-Json -Depth 5; return }

$null = Invoke-Adb @('start-server')
if ($config.android.adb.transport -eq 'tcp') { $null = Invoke-Adb @('connect', $Serial) }
if (-not (Wait-ForBoot -TimeoutSeconds $BootTimeoutSeconds)) { throw "ADB não ficou pronto no serial $Serial." }
$webViewDumpResult = Invoke-Adb @('-s', $Serial, 'shell', 'dumpsys', 'webviewupdate')
$packageDumpResult = Invoke-Adb @('-s', $Serial, 'shell', 'dumpsys', 'package', [string]$config.webView.provider)
if ($webViewDumpResult.ExitCode -ne 0 -or $packageDumpResult.ExitCode -ne 0) {
    throw "A consulta do provider WebView falhou: webviewupdate=$($webViewDumpResult.ExitCode); package=$($packageDumpResult.ExitCode)."
}
$webViewDump = $webViewDumpResult.Text
$packageDump = $packageDumpResult.Text
$versionMatch = [regex]::Match($packageDump, 'versionName=([^\s]+)')
$installedVersion = if ($versionMatch.Success) { $versionMatch.Groups[1].Value } else { '' }
$primaryCpuAbiMatch = [regex]::Match($packageDump, 'primaryCpuAbi=([^\s]+)')
$primaryCpuAbi = if ($primaryCpuAbiMatch.Success) { $primaryCpuAbiMatch.Groups[1].Value } else { $null }
$providerActive = Test-ActiveWebViewProvider -Dump $webViewDump -Provider ([string]$config.webView.provider)
$guestApiResult = Invoke-Adb @('-s', $Serial, 'shell', 'getprop', 'ro.build.version.sdk')
if ($guestApiResult.ExitCode -ne 0) { throw "Não foi possível ler a API do guest: $($guestApiResult.Text)" }
$guestApi = $guestApiResult.Text
$apiMatches = $guestApi -eq [string]$config.android.apiLevel
$versionMatches = $installedVersion -eq [string]$config.webView.homologatedVersion
$nativeGuestAbi = $primaryCpuAbi -in @('x86', 'x86_64')
$nativeAbiMatches = -not [bool]$config.webView.requireNativeGuestAbi -or $nativeGuestAbi
$install = Invoke-Adb @('-s', $Serial, 'install', '-r', $probeApk)
if ($install.ExitCode -ne 0 -or $install.Text -notmatch '(?im)\bSuccess\b') { throw "Falha ao instalar o probe WebView: $($install.Text)" }
$null = Invoke-Adb @('-s', $Serial, 'shell', 'am', 'force-stop', $probePackage)
$start = Invoke-Adb @('-s', $Serial, 'shell', 'am', 'start', '-W', '-n', "$probePackage/.MainActivity", '--es', 'url', $ContentUrl)
if ($start.ExitCode -ne 0 -or $start.Text -match '(?i)Error:|Exception|does not exist') { throw "Falha ao iniciar o probe WebView: $($start.Text)" }

$deadline = (Get-Date).AddSeconds($ContentTimeoutSeconds)
$probeResult = ''
while ((Get-Date) -lt $deadline) {
    $probeResult = (Invoke-Adb @('-s', $Serial, 'shell', 'run-as', $probePackage, 'cat', 'files/webview-result.txt')).Text
    if ($probeResult -match '^status=(ok|error)') { break }
    Start-Sleep -Seconds 1
}
$providerValidated = $providerActive -and $versionMatches -and $apiMatches -and $nativeAbiMatches
$probeValidated = $probeResult -match '(?i)^status=ok;.*localHtml=True;.*localCss=True;.*localJs=True;.*remoteHttps=True;.*remoteContent=True'
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    transport = $config.android.adb.transport
    serial = $Serial
    provider = [ordered]@{ packageName = $config.webView.provider; expectedVersion = $config.webView.homologatedVersion; installedVersion = $installedVersion; providerActive = $providerActive; versionMatches = $versionMatches; guestApiLevel = $guestApi; apiMatches = $apiMatches; primaryCpuAbi = $primaryCpuAbi; nativeGuestAbi = $nativeGuestAbi; nativeAbiMatches = $nativeAbiMatches }
    content = [ordered]@{ url = $ContentUrl; probePackage = $probePackage; result = $probeResult; validated = $probeValidated }
    status = if ($providerValidated -and $probeValidated) { 'validated' } elseif (-not $providerValidated) { 'provider-not-validated' } else { 'content-test-failed' }
}
$json = $result | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $reportFullPath -Value $json -Encoding utf8
# Probe cleanup changes guest state. Require an explicit operator switch;
# -KeepProbe remains accepted for compatibility.
if ($CleanupProbe -and -not $KeepProbe) {
    $cleanup = Invoke-Adb @('-s', $Serial, 'uninstall', $probePackage)
    if ($cleanup.ExitCode -ne 0) { throw "Falha ao remover explicitamente o probe WebView: $($cleanup.Text)" }
}
$json
if ($result.status -ne 'validated') { throw "WebView não foi homologado: status=$($result.status)." }
