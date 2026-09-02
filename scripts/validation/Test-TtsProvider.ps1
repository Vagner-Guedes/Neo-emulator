[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Serial,
    [int]$BootTimeoutSeconds = 180,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuração não encontrada: $ConfigPath" }

$configPathFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$repositoryRoot = [System.IO.Directory]::GetParent([System.IO.Directory]::GetParent($configPathFull).FullName).FullName
. (Join-Path $repositoryRoot 'scripts\validation\ValidationEvidence.Common.ps1')
$reportFullPath = Initialize-ValidationReport -ReportPath (Resolve-ValidationReportPath -RepositoryRoot $repositoryRoot -ReportPath $ReportPath) -Validator 'Test-TtsProvider'
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
if (-not (Wait-ForBoot -TimeoutSeconds $BootTimeoutSeconds)) { throw "ADB não ficou pronto no serial $Serial em $BootTimeoutSeconds segundos." }

$allPackagesResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'pm', 'list', 'packages')
if ($allPackagesResult.ExitCode -ne 0) { throw "Não foi possível listar os pacotes TTS: $($allPackagesResult.Text)" }
$allPackages = $allPackagesResult.Text
$candidatePackages = @($allPackages -split "`r?`n" | ForEach-Object { $_ -replace '^package:', '' } | Where-Object { $_ -match '(?i)(rhvoice|tts|svox|pico|speech)' })
$enginePackages = New-Object System.Collections.Generic.List[string]
foreach ($package in $candidatePackages) {
    if (-not $package) { continue }
    $packageDumpResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'dumpsys', 'package', $package)
    if ($packageDumpResult.ExitCode -eq 0 -and $packageDumpResult.Text -match 'android\.intent\.action\.TTS_SERVICE') { $enginePackages.Add($package) }
}

$defaultEngineResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'settings', 'get', 'secure', 'tts_default_synth')
$localeCheckResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'am', 'broadcast', '-a', 'android.speech.tts.engine.CHECK_TTS_DATA', '--es', 'language', 'por', '--es', 'country', 'BRA', '--es', 'variant', '')
$serviceListResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'service', 'list')
$apiResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'getprop', 'ro.build.version.sdk')
$releaseResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'getprop', 'ro.build.version.release')
$abiResult = Invoke-AdbResult @('-s', $Serial, 'shell', 'getprop', 'ro.product.cpu.abi')
$commandResults = @($defaultEngineResult, $localeCheckResult, $serviceListResult, $apiResult, $releaseResult, $abiResult)
if ($defaultEngineResult.ExitCode -ne 0 -or $localeCheckResult.ExitCode -ne 0 -or $serviceListResult.ExitCode -ne 0 -or @($commandResults | Where-Object { $_.ExitCode -ne 0 }).Count -gt 0) {
    throw 'Uma ou mais consultas do provider TTS retornaram exit code diferente de zero.'
}
$defaultEngine = $defaultEngineResult.Text
$localeCheck = $localeCheckResult.Text
$serviceList = $serviceListResult.Text
$rhvoicePresent = (($enginePackages -join "`n") -match '(?i)rhvoice')
$defaultMatches = $defaultEngine -match '(?i)rhvoice'
$localeReady = $localeCheck -match '(?i)result=1|CHECK_(VOICE|TTS)_DATA_PASS'
$api = $apiResult.Text
$release = $releaseResult.Text
$abi = $abiResult.Text

$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    transport = $config.android.adb.transport
    serial = $Serial
    android = [ordered]@{ release = $release; apiLevel = $api; abi = $abi }
    requested = [ordered]@{ engine = [string]$config.tts.engine; locale = [string]$config.tts.locale }
    detected = [ordered]@{
        rhvoicePresent = $rhvoicePresent
        enginePackages = @($enginePackages)
        defaultEngine = $defaultEngine
        defaultMatches = $defaultMatches
        localeCheck = $localeCheck
        localeReady = $localeReady
        textToSpeechService = ($serviceList -match '(?i)texttospeech|tts')
        synthesis = [ordered]@{ status = 'not-executed'; reason = 'A síntese exige uma chamada TextToSpeech real em um probe Android; presença do provider não é tratada como prova de áudio.' }
    }
    status = if ($rhvoicePresent -and $defaultMatches -and $localeReady) { 'provider-and-locale-validated-synthesis-pending' } elseif (-not $rhvoicePresent) { 'missing-engine' } else { 'engine-or-locale-mismatch' }
}

$json = $result | ConvertTo-Json -Depth 10
if ($ReportPath) {
    Set-Content -LiteralPath $reportFullPath -Value $json -Encoding utf8
}
$json
if ($result.status -notlike 'provider-and-locale-validated*') { throw "RHVoice não foi validado: status=$($result.status)." }
