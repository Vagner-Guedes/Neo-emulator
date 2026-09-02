[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$Serial,
    [switch]$InstallNativeBridge,
    [switch]$InstallWebView,
    [switch]$InstallTts,
    [switch]$SetRhVoiceDefault,
    [int]$BootTimeoutSeconds = 180,
    [string]$ReportPath = 'reports/guest-components.json'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuração não encontrada: $ConfigPath" }
if (-not ($InstallNativeBridge -or $InstallWebView -or $InstallTts)) { throw 'Selecione pelo menos um componente: -InstallNativeBridge, -InstallWebView ou -InstallTts.' }

$configPathFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$repositoryRoot = [System.IO.Directory]::GetParent([System.IO.Directory]::GetParent($configPathFull).FullName).FullName
$config = Get-Content -LiteralPath $configPathFull -Raw -Encoding utf8 | ConvertFrom-Json

function Resolve-ConfiguredPath {
    param([string]$ConfiguredPath)
    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) { return $ConfiguredPath }
    return [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot ($ConfiguredPath -replace '/', '\')))
}

function Invoke-Adb {
    param([string[]]$Arguments)
    $output = & $script:adbPath @Arguments 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (($output | Out-String).Trim()) }
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

function Install-Component {
    param([string]$Name, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Name não encontrado: $Path" }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if (-not $PSCmdlet.ShouldProcess($Path, "instalar $Name no serial $script:Serial com adb install -r")) {
        return [ordered]@{ name = $Name; path = $Path; sha256 = $hash; attempted = $false; succeeded = $false; output = 'WHATIF' }
    }
    $result = Invoke-Adb @('-s', $script:Serial, 'install', '-r', $Path)
    $succeeded = $result.ExitCode -eq 0 -and $result.Text -match '(?im)\bSuccess\b'
    if (-not $succeeded) { throw "Falha ao instalar ${Name}: $($result.Text)" }
    return [ordered]@{ name = $Name; path = $Path; sha256 = $hash; attempted = $true; succeeded = $true; output = $result.Text }
}

$adbRelativePath = Join-Path $config.android.tooling.sdkRoot $config.android.tooling.adbRelativePath
$adbPath = Resolve-ConfiguredPath $adbRelativePath
if (-not (Test-Path -LiteralPath $adbPath) -and $config.android.tooling.allowEnvironmentFallback) {
    $fallbackRoot = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    $adbPath = Join-Path $fallbackRoot 'platform-tools\adb.exe'
}
if (-not (Test-Path -LiteralPath $adbPath)) { throw "ADB não encontrado em $adbPath. Nenhum componente será baixado." }
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

$server = Invoke-Adb @('start-server')
if ($server.ExitCode -ne 0) { throw "Não foi possível iniciar o ADB: $($server.Text)" }
if ($config.android.adb.transport -eq 'tcp') { $null = Invoke-Adb @('connect', $Serial) }
if (-not (Wait-ForBoot -TimeoutSeconds $BootTimeoutSeconds)) { throw "ADB não ficou pronto no serial $Serial em $BootTimeoutSeconds segundos." }

$components = New-Object System.Collections.Generic.List[object]
if ($InstallNativeBridge) { $components.Add((Install-Component 'Native Bridge' (Resolve-ConfiguredPath $config.android.provisioning.nativeBridgePackagePath))) }
if ($InstallWebView) { $components.Add((Install-Component 'WebView' (Resolve-ConfiguredPath $config.android.provisioning.webViewPackagePath))) }
if ($InstallTts) { $components.Add((Install-Component 'RHVoice' (Resolve-ConfiguredPath $config.android.provisioning.ttsPackagePath))) }

$packages = (Invoke-Adb @('-s', $Serial, 'shell', 'pm', 'list', 'packages')).Text
$webViewDump = (Invoke-Adb @('-s', $Serial, 'shell', 'dumpsys', 'package', [string]$config.webView.provider)).Text
$webViewVersionMatch = [regex]::Match($webViewDump, 'versionName=([^\s]+)')
$rhvoicePackages = @($packages -split "`r?`n" | Where-Object { $_ -match '(?i)rhvoice' } | ForEach-Object { $_ -replace '^package:', '' })
$defaultEngine = (Invoke-Adb @('-s', $Serial, 'shell', 'settings', 'get', 'secure', 'tts_default_synth')).Text
$defaultChanged = $false
if ($SetRhVoiceDefault) {
    if ($rhvoicePackages.Count -eq 0) { throw 'Nenhum pacote RHVoice foi encontrado para selecionar como engine padrão.' }
    if ($PSCmdlet.ShouldProcess($Serial, "selecionar $($rhvoicePackages[0]) como tts_default_synth")) {
        $setResult = Invoke-Adb @('-s', $Serial, 'shell', 'settings', 'put', 'secure', 'tts_default_synth', $rhvoicePackages[0])
        if ($setResult.ExitCode -ne 0) { throw "Não foi possível selecionar RHVoice como engine padrão: $($setResult.Text)" }
        $defaultChanged = $true
        $defaultEngine = (Invoke-Adb @('-s', $Serial, 'shell', 'settings', 'get', 'secure', 'tts_default_synth')).Text
    }
}

$statePath = Resolve-ConfiguredPath $config.android.provisioning.statePath
$stateDirectory = Split-Path -Parent $statePath
if (-not (Test-Path -LiteralPath $stateDirectory)) { New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null }
$reportFullPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $repositoryRoot $ReportPath }
$reportDirectory = Split-Path -Parent $reportFullPath
if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }

$state = [ordered]@{
    schema = 1
    androidImageVersion = $config.android.release
    nativeBridgeStatus = if ($InstallNativeBridge) { 'installed-local-pending-runtime-test' } else { 'unchanged' }
    webViewVersion = if ($webViewVersionMatch.Success) { $webViewVersionMatch.Groups[1].Value } else { '' }
    ttsStatus = if ($rhvoicePackages.Count -gt 0 -and $defaultEngine -match '(?i)rhvoice') { 'selected-local-pending-synthesis-test' } elseif ($rhvoicePackages.Count -gt 0) { 'installed-local-not-selected' } else { 'missing' }
    neoNewsVersion = "$($config.neonews.versionName) ($($config.neonews.versionCode))"
    lastValidation = (Get-Date).ToUniversalTime().ToString('o')
    imageHash = ''
    files = @($components)
    guest = [ordered]@{ serial = $Serial; webViewProvider = $config.webView.provider; webViewVersion = if ($webViewVersionMatch.Success) { $webViewVersionMatch.Groups[1].Value } else { $null }; rhvoicePackages = $rhvoicePackages; defaultTtsEngine = $defaultEngine; defaultChanged = $defaultChanged }
}
$stateJson = $state | ConvertTo-Json -Depth 10
$temporaryStatePath = "$statePath.tmp"
Set-Content -LiteralPath $temporaryStatePath -Value $stateJson -Encoding utf8
Move-Item -LiteralPath $temporaryStatePath -Destination $statePath -Force
Set-Content -LiteralPath $reportFullPath -Value $stateJson -Encoding utf8
$stateJson
