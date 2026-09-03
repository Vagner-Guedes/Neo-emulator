[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$Serial,
    [switch]$InstallNativeBridge,
    [switch]$InstallWebView,
    [switch]$InstallTts,
    [switch]$SetRhVoiceDefault,
    [string]$NativeBridgeOrigin,
    [string]$WebViewOrigin,
    [string]$TtsOrigin,
    [int]$BootTimeoutSeconds = 180,
    [string]$ReportPath = 'reports/guest-components.json'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\..\config\runtime.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuração não encontrada: $ConfigPath" }
if ($InstallNativeBridge) {
    throw 'Native Bridge Houdini nao e um APK: adb install -r foi bloqueado. Use scripts/provision/Provision-NativeBridgeOfficial.ps1 com os artefatos oficiais SFS.'
}
if (-not ($InstallNativeBridge -or $InstallWebView -or $InstallTts)) { throw 'Selecione pelo menos um componente: -InstallNativeBridge, -InstallWebView ou -InstallTts.' }

$configPathFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$repositoryRoot = [System.IO.Directory]::GetParent([System.IO.Directory]::GetParent($configPathFull).FullName).FullName
$config = Get-Content -LiteralPath $configPathFull -Raw -Encoding utf8 | ConvertFrom-Json

function Resolve-ConfiguredPath {
    param([string]$ConfiguredPath)
    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) { return $ConfiguredPath }
    return [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot ($ConfiguredPath -replace '/', '\')))
}

function Test-NonEmptyFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { return (Get-Item -LiteralPath $Path).Length -gt 0 } catch { return $false }
}

$statePath = Resolve-ConfiguredPath $config.android.provisioning.statePath
if (-not (Test-Path -LiteralPath $statePath)) {
    throw "Estado base de provisionamento não encontrado: $statePath. Execute Provision-QemuAndroidRuntime.ps1 antes de instalar componentes."
}
try { $existingState = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json }
catch { throw "O estado de provisionamento existente não pôde ser lido: $statePath. $($_.Exception.Message)" }
$existingImageHash = [string]$existingState.imageHash
$existingProvenance = if ($existingState.provenance) { @($existingState.provenance.PSObject.Properties) } else { @() }
if ($existingImageHash -notmatch '^[0-9a-fA-F]{64}$' -or $existingProvenance.Count -eq 0) {
    throw "O estado base de provisionamento é incompleto ou não possui SHA-256/proveniência fortes: $statePath. Reexecute Provision-QemuAndroidRuntime.ps1."
}

if ([string]::IsNullOrWhiteSpace([string]$existingState.androidImageVersion) -or [string]$existingState.androidImageVersion -ne [string]$config.android.release) {
    throw "A release Android do estado base diverge da configuracao: registrada=$($existingState.androidImageVersion); esperada=$($config.android.release)."
}

$requestedOrigins = [ordered]@{
    nativeBridge = $NativeBridgeOrigin
    webView = $WebViewOrigin
    tts = $TtsOrigin
}
foreach ($requestedComponent in @(
    if ($InstallNativeBridge) { 'nativeBridge' }
    if ($InstallWebView) { 'webView' }
    if ($InstallTts) { 'tts' }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$requestedOrigins[$requestedComponent])) {
        throw "Informe -$requestedComponent`Origin ao instalar esse componente. A origem/licença precisa ser registrada antes do provisionamento."
    }
}

$basePaths = [ordered]@{
    qemu = Resolve-ConfiguredPath $config.android.qemu.executable
    adb = Resolve-ConfiguredPath (Join-Path $config.android.tooling.sdkRoot $config.android.tooling.adbRelativePath)
    disk = Resolve-ConfiguredPath $config.android.qemu.disk
    installerImage = Resolve-ConfiguredPath $config.android.qemu.androidImage
}
foreach ($baseName in $basePaths.Keys) {
    $record = $existingState.provenance.$baseName
    if ($null -eq $record -or [string]$record.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [string]::IsNullOrWhiteSpace([string]$record.origin)) {
        throw "A provenance do componente-base '$baseName' não possui hash SHA-256 forte: $statePath."
    }
    if (-not (Test-NonEmptyFile $basePaths[$baseName])) {
        throw "O componente-base '$baseName' não foi encontrado ou está vazio: $($basePaths[$baseName])."
    }
    if ($baseName -ne 'disk') {
        $currentHash = (Get-FileHash -LiteralPath $basePaths[$baseName] -Algorithm SHA256).Hash
        if ($currentHash -ne [string]$record.sha256) {
            throw "O hash do componente-base '$baseName' diverge do provisionamento: registrado=$($record.sha256); atual=$currentHash."
        }
    }
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
    param([string]$Name, [string]$Path, [string]$Origin)
    if (-not (Test-NonEmptyFile $Path)) { throw "$Name não encontrado ou vazio: $Path" }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if (-not $PSCmdlet.ShouldProcess($Path, "instalar $Name no serial $script:Serial com adb install -r")) {
        return [ordered]@{ name = $Name; path = $Path; sha256 = $hash; origin = if ($Origin) { $Origin } else { 'not-recorded' }; attempted = $false; succeeded = $false; output = 'WHATIF' }
    }
    $result = Invoke-Adb @('-s', $script:Serial, 'install', '-r', $Path)
    $succeeded = $result.ExitCode -eq 0 -and $result.Text -match '(?im)\bSuccess\b'
    if (-not $succeeded) { throw "Falha ao instalar ${Name}: $($result.Text)" }
    return [ordered]@{ name = $Name; path = $Path; sha256 = $hash; origin = if ($Origin) { $Origin } else { 'not-recorded' }; attempted = $true; succeeded = $true; output = $result.Text }
}

function Assert-NativeWebViewAbi {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $abis = @($archive.Entries | ForEach-Object {
                if ($_.FullName -match '^lib/([^/]+)/') { $Matches[1] }
            } | Sort-Object -Unique)
        }
        finally { $archive.Dispose() }
    }
    catch { throw "O pacote WebView não pôde ser lido como APK/ZIP: $Path. $($_.Exception.Message)" }
    if ($abis.Count -eq 0 -or ($abis -notcontains 'x86' -and $abis -notcontains 'x86_64')) {
        throw "O WebView fornecido não contém ABI nativa x86/x86_64: $($abis -join ', '). Não instalar um WebView ARM no guest x86."
    }
}

$adbRelativePath = Join-Path $config.android.tooling.sdkRoot $config.android.tooling.adbRelativePath
$adbPath = Resolve-ConfiguredPath $adbRelativePath
if (-not (Test-Path -LiteralPath $adbPath) -and $config.android.tooling.allowEnvironmentFallback) {
    $fallbackRoot = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    $adbPath = Join-Path $fallbackRoot 'platform-tools\adb.exe'
}
if (-not (Test-NonEmptyFile $adbPath)) { throw "ADB não encontrado ou vazio em $adbPath. Nenhum componente será baixado." }
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
$guestReleaseResult = Invoke-Adb @('-s', $Serial, 'shell', 'getprop', 'ro.build.version.release')
$guestApiResult = Invoke-Adb @('-s', $Serial, 'shell', 'getprop', 'ro.build.version.sdk')
$guestRelease = $guestReleaseResult.Text
$guestApi = $guestApiResult.Text
if ($guestReleaseResult.ExitCode -ne 0 -or $guestApiResult.ExitCode -ne 0 -or $guestRelease -ne [string]$config.android.release -or $guestApi -ne [string]$config.android.apiLevel) {
    throw "O guest conectado não corresponde ao runtime configurado: release=$guestRelease (esperada $($config.android.release)); api=$guestApi (esperada $($config.android.apiLevel)); nenhum componente será instalado."
}

$baselineDefaultEngineResult = Invoke-Adb @('-s', $Serial, 'shell', 'settings', 'get', 'secure', 'tts_default_synth')
if ($baselineDefaultEngineResult.ExitCode -ne 0) {
    throw "Nao foi possivel capturar a engine TTS atual antes do provisionamento: $($baselineDefaultEngineResult.Text)"
}
$baselineDefaultEngine = $baselineDefaultEngineResult.Text.Trim()

$components = New-Object System.Collections.Generic.List[object]
if ($InstallNativeBridge) { $components.Add((Install-Component 'Native Bridge' (Resolve-ConfiguredPath $config.android.provisioning.nativeBridgePackagePath) $NativeBridgeOrigin)) }
if ($InstallWebView) {
    $webViewPath = Resolve-ConfiguredPath $config.android.provisioning.webViewPackagePath
    Assert-NativeWebViewAbi $webViewPath
    $components.Add((Install-Component 'WebView' $webViewPath $WebViewOrigin))
}
if ($InstallTts) { $components.Add((Install-Component 'RHVoice' (Resolve-ConfiguredPath $config.android.provisioning.ttsPackagePath) $TtsOrigin)) }

$packagesResult = Invoke-Adb @('-s', $Serial, 'shell', 'pm', 'list', 'packages')
$webViewDumpResult = Invoke-Adb @('-s', $Serial, 'shell', 'dumpsys', 'webviewupdate')
$webViewPackageDumpResult = Invoke-Adb @('-s', $Serial, 'shell', 'dumpsys', 'package', [string]$config.webView.provider)
$packages = $packagesResult.Text
$webViewDump = $webViewPackageDumpResult.Text
$webViewUpdateDump = $webViewDumpResult.Text
$webViewVersionMatch = [regex]::Match($webViewDump, 'versionName=([^\s]+)')
$webViewPackagePresent = $packagesResult.ExitCode -eq 0 -and $packages -match [regex]::Escape("package:$([string]$config.webView.provider)")
$webViewProviderActive = $webViewDumpResult.ExitCode -eq 0 -and @($webViewUpdateDump -split "`r?`n" | Where-Object { $_ -match '(?i)Current WebView package' -and $_ -match [regex]::Escape([string]$config.webView.provider) }).Count -gt 0
$webViewVersionMatches = $webViewPackageDumpResult.ExitCode -eq 0 -and $webViewVersionMatch.Success -and $webViewVersionMatch.Groups[1].Value -eq [string]$config.webView.homologatedVersion
if ($InstallWebView -and (-not $webViewPackagePresent -or -not $webViewProviderActive -or -not $webViewVersionMatches)) {
    throw "O WebView instalado não corresponde ao provider/versão homologados: packagePresent=$webViewPackagePresent; providerActive=$webViewProviderActive; version=$($webViewVersionMatch.Groups[1].Value); expected=$($config.webView.homologatedVersion)."
}
$rhvoicePackages = @($packages -split "`r?`n" | Where-Object { $_ -match '(?i)rhvoice' } | ForEach-Object { $_ -replace '^package:', '' })
if ($packagesResult.ExitCode -ne 0) { throw "Nao foi possivel confirmar os packages apos o provisionamento: $($packagesResult.Text)" }
$defaultEngineResult = Invoke-Adb @('-s', $Serial, 'shell', 'settings', 'get', 'secure', 'tts_default_synth')
if ($defaultEngineResult.ExitCode -ne 0) { throw "Nao foi possivel confirmar a engine TTS apos o provisionamento: $($defaultEngineResult.Text)" }
$defaultEngine = $defaultEngineResult.Text.Trim()
$defaultChanged = $false
if ($SetRhVoiceDefault) {
    if ($rhvoicePackages.Count -eq 0) { throw 'Nenhum pacote RHVoice foi encontrado para selecionar como engine padrão.' }
    if ($PSCmdlet.ShouldProcess($Serial, "selecionar $($rhvoicePackages[0]) como tts_default_synth")) {
        $setResult = Invoke-Adb @('-s', $Serial, 'shell', 'settings', 'put', 'secure', 'tts_default_synth', $rhvoicePackages[0])
        if ($setResult.ExitCode -ne 0) { throw "Não foi possível selecionar RHVoice como engine padrão: $($setResult.Text)" }
        $defaultChanged = $true
        $defaultEngineResult = Invoke-Adb @('-s', $Serial, 'shell', 'settings', 'get', 'secure', 'tts_default_synth')
        if ($defaultEngineResult.ExitCode -ne 0) { throw "Nao foi possivel verificar a engine RHVoice selecionada: $($defaultEngineResult.Text)" }
        $defaultEngine = $defaultEngineResult.Text.Trim()
        if ($defaultEngine -notmatch '(?i)rhvoice') { throw "A engine TTS nao confirmou RHVoice apos a selecao explicita: $defaultEngine" }
    }
}

$defaultEnginePreserved = $defaultEngine -eq $baselineDefaultEngine
if (-not $SetRhVoiceDefault -and -not $defaultEnginePreserved) {
    $restoreResult = if ([string]::IsNullOrWhiteSpace($baselineDefaultEngine) -or $baselineDefaultEngine -eq 'null') {
        Invoke-Adb @('-s', $Serial, 'shell', 'settings', 'delete', 'secure', 'tts_default_synth')
    } else {
        Invoke-Adb @('-s', $Serial, 'shell', 'settings', 'put', 'secure', 'tts_default_synth', $baselineDefaultEngine)
    }
    if ($restoreResult.ExitCode -ne 0) { throw "A engine TTS mudou durante o provisionamento e nao pode ser restaurada: $($restoreResult.Text)" }
    $verifyRestore = Invoke-Adb @('-s', $Serial, 'shell', 'settings', 'get', 'secure', 'tts_default_synth')
    if ($verifyRestore.ExitCode -ne 0 -or $verifyRestore.Text.Trim() -ne $baselineDefaultEngine) {
        throw "A engine TTS nao foi preservada: antes='$baselineDefaultEngine'; depois='$($verifyRestore.Text.Trim())'"
    }
    $defaultEngine = $verifyRestore.Text.Trim()
    $defaultEnginePreserved = $true
}

$stateDirectory = Split-Path -Parent $statePath
if (-not (Test-Path -LiteralPath $stateDirectory)) { New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null }
$reportFullPath = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $repositoryRoot $ReportPath }
$reportDirectory = Split-Path -Parent $reportFullPath
if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }

$provenance = [ordered]@{}
if ($existingState -and $existingState.provenance) {
    foreach ($entry in $existingState.provenance.PSObject.Properties) {
        $provenance[$entry.Name] = $entry.Value
    }
}
foreach ($component in $components) {
    $provenance[$component.name] = [ordered]@{
        path = $component.path
        sha256 = $component.sha256
        origin = $component.origin
        status = if ($component.succeeded) { 'installed' } else { 'not-installed' }
    }
}
$existingFiles = if ($existingState -and $existingState.files) { @($existingState.files) } else { @() }
$imageHash = ''
if ($existingState -and $existingState.PSObject.Properties.Name -contains 'imageHash') {
    $imageHash = [string]$existingState.imageHash
}
$diskFingerprint = ''
if ($existingState -and $existingState.PSObject.Properties.Name -contains 'diskFingerprint') {
    $diskFingerprint = [string]$existingState.diskFingerprint
}
$files = @()
if ($existingState -and $existingState.PSObject.Properties.Name -contains 'files') {
    $files = @($existingState.files)
}
foreach ($component in $components) {
    $files += $component
}
$state = [ordered]@{
    schema = 1
    androidImageVersion = $config.android.release
    nativeBridgeStatus = if (-not $InstallNativeBridge) { 'unchanged' } elseif ([string]::IsNullOrWhiteSpace($NativeBridgeOrigin)) { 'installed-local-origin-missing-pending-runtime-test' } else { 'installed-local-origin-recorded-pending-runtime-test' }
    webViewVersion = if ($webViewVersionMatch.Success) { $webViewVersionMatch.Groups[1].Value } else { '' }
    webViewProvider = [ordered]@{ packagePresent = $webViewPackagePresent; providerActive = $webViewProviderActive; versionMatches = $webViewVersionMatches; packageDumpExitCode = $webViewPackageDumpResult.ExitCode; webViewUpdateExitCode = $webViewDumpResult.ExitCode }
    ttsStatus = if ($rhvoicePackages.Count -gt 0 -and $defaultEngine -match '(?i)rhvoice') { 'selected-local-pending-synthesis-test' } elseif ($rhvoicePackages.Count -gt 0) { 'installed-local-not-selected' } else { 'missing' }
    ttsEngineBefore = $baselineDefaultEngine
    ttsEngineAfter = $defaultEngine
    ttsEnginePreserved = $defaultEnginePreserved
    neoNewsVersion = "$($config.neonews.versionName) ($($config.neonews.versionCode))"
    lastValidation = (Get-Date).ToUniversalTime().ToString('o')
    imageHash = $imageHash
    diskFingerprint = $diskFingerprint
    files = $files
    provenance = $provenance
    guest = [ordered]@{ serial = $Serial; release = $guestRelease; apiLevel = $guestApi; identityMatches = $true; webViewProvider = $config.webView.provider; webViewVersion = if ($webViewVersionMatch.Success) { $webViewVersionMatch.Groups[1].Value } else { $null }; webViewPackagePresent = $webViewPackagePresent; webViewProviderActive = $webViewProviderActive; webViewVersionMatches = $webViewVersionMatches; rhvoicePackages = $rhvoicePackages; defaultTtsEngineBefore = $baselineDefaultEngine; defaultTtsEngine = $defaultEngine; defaultEnginePreserved = $defaultEnginePreserved; defaultChanged = $defaultChanged }
}
$stateJson = $state | ConvertTo-Json -Depth 10
$temporaryStatePath = "$statePath.tmp"
Set-Content -LiteralPath $temporaryStatePath -Value $stateJson -Encoding utf8
Move-Item -LiteralPath $temporaryStatePath -Destination $statePath -Force
Set-Content -LiteralPath $reportFullPath -Value $stateJson -Encoding utf8
$stateJson
