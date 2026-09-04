[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Serial,
    [string]$SdkRoot,
    [int]$BootTimeoutSeconds = 180,
    [int]$SynthesisTimeoutSeconds = 90,
    [string]$ReportPath = 'reports/tts-synthesis.json',
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
$reportFullPath = Initialize-ValidationReport -ReportPath (Resolve-ValidationReportPath -RepositoryRoot $repositoryRoot -ReportPath $ReportPath) -Validator 'Test-TtsSynthesis'
$config = Get-Content -LiteralPath $configPathFull -Raw -Encoding utf8 | ConvertFrom-Json
$script:adbServerPort = [int]$config.android.adb.serverPort
$probePackage = 'com.neonews.runtime.ttsprobe'

function Resolve-ConfiguredPath {
    param([string]$ConfiguredPath)
    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) { return $ConfiguredPath }
    return [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot ($ConfiguredPath -replace '/', '\')))
}

function Invoke-External {
    param([string]$Executable, [string[]]$Arguments)
    $output = @()
    $exitCode = 1
    try {
        $output = & $Executable @Arguments 2>&1
        $exitCode = [int]$LASTEXITCODE
    }
    catch {
        $output += $_.Exception.Message
        $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 }
    }
    [pscustomobject]@{ ExitCode = $exitCode; Text = (($output | Out-String).Trim()) }
}

function Invoke-Adb {
    param([string[]]$Arguments)
    Invoke-External -Executable $script:adbPath -Arguments (@('-P', [string]$script:adbServerPort) + @($Arguments))
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
$apksignerJar = Join-Path $buildTools 'lib\apksigner.jar'
foreach ($requiredTool in @(@{ Name = 'android.jar'; Path = $androidJar }, @{ Name = 'java'; Path = $javaPath }, @{ Name = 'javac'; Path = $javacPath }, @{ Name = 'jar'; Path = $jarPath }, @{ Name = 'keytool'; Path = $keytoolPath }, @{ Name = 'aapt'; Path = $aaptPath }, @{ Name = 'dx.jar'; Path = $dxJar }, @{ Name = 'apksigner.jar'; Path = $apksignerJar })) {
    if ([string]::IsNullOrWhiteSpace($requiredTool.Path) -or -not (Test-Path -LiteralPath $requiredTool.Path)) { throw "$($requiredTool.Name) não encontrado: $($requiredTool.Path)." }
}
function Invoke-ApkSigner {
    param([string[]]$Arguments)
    & $javaPath '--add-opens=java.base/java.io=ALL-UNNAMED' '--add-exports=java.base/sun.security.x509=ALL-UNNAMED' '--add-exports=java.base/sun.security.pkcs=ALL-UNNAMED' '--add-exports=java.base/sun.security.util=ALL-UNNAMED' '-jar' $apksignerJar @Arguments
    return [int]$LASTEXITCODE
}

$adbRelativePath = Join-Path $config.android.tooling.sdkRoot $config.android.tooling.adbRelativePath
$adbPath = Resolve-ConfiguredPath $adbRelativePath
if (-not (Test-Path -LiteralPath $adbPath) -and $config.android.tooling.allowEnvironmentFallback) { $adbPath = Join-Path $SdkRoot 'platform-tools\adb.exe' }
if (-not (Test-Path -LiteralPath $adbPath) -and -not $BuildOnly) { throw "ADB não encontrado em $adbPath." }
$script:adbPath = $adbPath
if (-not $Serial) {
    $Serial = if ($config.android.adb.transport -eq 'tcp') { "$($config.android.adb.host):$($config.android.adb.hostPort)" } elseif ($config.android.adb.emulatorSerial) { $config.android.adb.emulatorSerial } else { "emulator-$($config.android.emulator.validationPort)" }
}
$script:Serial = $Serial

$probeRoot = Join-Path $scriptRepositoryRoot 'tools\tts-probe'
$buildRoot = Join-Path $probeRoot 'build'
$classesRoot = Join-Path $buildRoot 'classes'
$unsignedApk = Join-Path $buildRoot 'tts-probe-unsigned.apk'
$probeApk = Join-Path $buildRoot 'tts-probe.apk'
$classesDex = Join-Path $buildRoot 'classes.dex'
New-Item -ItemType Directory -Path $classesRoot -Force | Out-Null

& $javacPath -source 7 -target 7 -classpath $androidJar -d $classesRoot (Join-Path $probeRoot 'MainActivity.java')
if ($LASTEXITCODE -ne 0) { throw 'Falha ao compilar o probe TTS.' }
& $javaPath '-jar' $dxJar '--dex' "--output=$classesDex" $classesRoot
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $classesDex)) { throw "Falha ao gerar classes.dex do probe TTS. Verifique Java/DX em $javaRoot." }
& $aaptPath 'package' '-f' '-M' (Join-Path $probeRoot 'AndroidManifest.xml') '-I' $androidJar '-F' $unsignedApk
if ($LASTEXITCODE -ne 0) { throw 'Falha ao empacotar o probe TTS.' }
& $jarPath 'uf' $unsignedApk '-C' $buildRoot 'classes.dex'
if ($LASTEXITCODE -ne 0) { throw 'Falha ao adicionar classes.dex ao probe TTS.' }
$keystorePath = Join-Path $buildRoot 'debug.keystore'
if (-not (Test-Path -LiteralPath $keystorePath)) {
    & $keytoolPath '-genkeypair' '-keystore' $keystorePath '-storepass' 'android' '-keypass' 'android' '-alias' 'androiddebugkey' '-dname' 'CN=Android Debug,O=Android,C=US' '-keyalg' 'RSA' '-keysize' '2048' '-validity' '10000'
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao gerar a chave temporária do probe TTS.' }
}
$signExitCode = Invoke-ApkSigner @('sign', '--ks', $keystorePath, '--ks-pass', 'pass:android', '--key-pass', 'pass:android', '--out', $probeApk, $unsignedApk)
if ($signExitCode -ne 0 -or -not (Test-Path -LiteralPath $probeApk -PathType Leaf)) { throw 'Falha ao assinar o probe TTS.' }
$verifyExitCode = Invoke-ApkSigner @('verify', $probeApk)
if ($verifyExitCode -ne 0) { throw 'A verificação da assinatura do probe TTS falhou.' }

if ($BuildOnly) {
    [ordered]@{ status = 'probe-built'; apk = $probeApk; package = $probePackage } | ConvertTo-Json -Depth 5
    return
}

$null = (Invoke-Adb @('start-server'))
if ($config.android.adb.transport -eq 'tcp') { $null = Invoke-Adb @('connect', $Serial) }
if (-not (Wait-ForBoot -TimeoutSeconds $BootTimeoutSeconds)) { throw "ADB não ficou pronto no serial $Serial." }
$defaultEngine = (Invoke-Adb @('-s', $Serial, 'shell', 'settings', 'get', 'secure', 'tts_default_synth')).Text
$defaultEngineMatches = $defaultEngine -match '(?i)rhvoice'
$install = Invoke-Adb @('-s', $Serial, 'install', '-r', $probeApk)
if ($install.ExitCode -ne 0 -or $install.Text -notmatch '(?im)\bSuccess\b') { throw "Falha ao instalar o probe TTS: $($install.Text)" }
$null = Invoke-Adb @('-s', $Serial, 'shell', 'am', 'force-stop', $probePackage)
$start = Invoke-Adb @('-s', $Serial, 'shell', 'am', 'start', '-W', '-n', "$probePackage/.MainActivity")
if ($start.ExitCode -ne 0 -or $start.Text -match '(?i)Error:|Exception|does not exist') { throw "Falha ao iniciar o probe TTS: $($start.Text)" }

$deadline = (Get-Date).AddSeconds($SynthesisTimeoutSeconds)
$probeResult = ''
while ((Get-Date) -lt $deadline) {
    $probeRead = Invoke-Adb @('-s', $Serial, 'shell', 'run-as', $probePackage, 'cat', 'files/tts-result.txt')
    $probeResult = $probeRead.Text
    if ($probeRead.ExitCode -ne 0 -and $probeResult -match '(?i)Could not set capabilities|not debuggable|run-as:') {
        # Android-x86 7.1 may reject run-as even for the local probe. The
        # guest is intentionally rooted; read only the probe-owned evidence
        # through the supported root shell path instead of treating that
        # transport limitation as a failed RHVoice synthesis.
        $probeResult = (Invoke-Adb @('-s', $Serial, 'shell', 'su', '0', 'cat', "/data/data/$probePackage/files/tts-result.txt")).Text
    }
    if ($probeResult -match '^status=(ok|error)') { break }
    Start-Sleep -Seconds 1
}
$audioStat = Invoke-Adb @('-s', $Serial, 'shell', 'run-as', $probePackage, 'stat', '-c', '%s', 'files/tts.wav')
if ($audioStat.ExitCode -ne 0 -and $audioStat.Text -match '(?i)Could not set capabilities|not debuggable|run-as:') {
    $audioStat = Invoke-Adb @('-s', $Serial, 'shell', 'su', '0', 'stat', '-c', '%s', "/data/data/$probePackage/files/tts.wav")
}
$audioBytes = 0L
if ($audioStat.ExitCode -eq 0 -and $audioStat.Text -match '(?m)^\s*(\d+)\s*$') {
    $audioBytes = [int64]$Matches[1]
} else {
    # Android-x86 7.1 images can expose different toybox/stat behavior;
    # retain a conservative ls fallback without treating a parse failure as
    # successful synthesis.
    $audioListingResult = Invoke-Adb @('-s', $Serial, 'shell', 'run-as', $probePackage, 'ls', '-l', 'files/tts.wav')
    if ($audioListingResult.ExitCode -ne 0 -and $audioListingResult.Text -match '(?i)Could not set capabilities|not debuggable|run-as:') {
        $audioListingResult = Invoke-Adb @('-s', $Serial, 'shell', 'su', '0', 'ls', '-l', "/data/data/$probePackage/files/tts.wav")
    }
    $audioListing = $audioListingResult.Text
    $audioSizeMatch = [regex]::Match($audioListing, '(?m)\s(\d+)\s+(?:\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}|tts\.wav)')
    if ($audioSizeMatch.Success) { $audioBytes = [int64]$audioSizeMatch.Groups[1].Value }
}
$probeEngineMatch = [regex]::Match($probeResult, 'engine=([^;]+)')
$probeEngine = if ($probeEngineMatch.Success) { $probeEngineMatch.Groups[1].Value } else { '' }
$probeLocale = $probeResult -match '(?i)locale=pt-BR'
$synthesisSucceeded = $probeResult -match '^status=ok' -and $audioBytes -gt 0 -and $defaultEngineMatches -and $probeEngine -match '(?i)rhvoice' -and $probeLocale
$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    transport = $config.android.adb.transport
    serial = $Serial
    package = $probePackage
    phrase = 'Teste de voz do NeoNews Runtime.'
    locale = [string]$config.tts.locale
    requestedEngine = [string]$config.tts.engine
    defaultEngine = $defaultEngine
    defaultEngineMatches = $defaultEngineMatches
    probeResult = $probeResult
    probeEngine = $probeEngine
    probeLocale = $probeLocale
    audio = [ordered]@{ path = 'files/tts.wav'; bytes = $audioBytes; nonEmpty = $audioBytes -gt 0 }
    status = if ($synthesisSucceeded) { 'validated' } else { 'synthesis-failed' }
}
$json = $result | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $reportFullPath -Value $json -Encoding utf8
# Probe cleanup changes guest state. Require an explicit operator switch;
# -KeepProbe remains accepted for compatibility.
if ($CleanupProbe -and -not $KeepProbe) {
    $cleanup = Invoke-Adb @('-s', $Serial, 'uninstall', $probePackage)
    if ($cleanup.ExitCode -ne 0) { throw "Falha ao remover explicitamente o probe TTS: $($cleanup.Text)" }
}
$json
if (-not $synthesisSucceeded) { throw "RHVoice não produziu áudio no probe: status=$($result.status); resultado=$probeResult; bytes=$audioBytes." }
