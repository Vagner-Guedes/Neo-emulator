[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [switch]$RequireInstallerImage,
    [switch]$RequireNativeBridge,
    [switch]$RequireWebView,
    [switch]$RequireTts,
    [string]$QemuOrigin,
    [string]$AdbOrigin,
    [string]$AndroidImageOrigin,
    [string]$NativeBridgeOrigin,
    [string]$WebViewOrigin,
    [string]$TtsOrigin
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

$configPath = Join-Path $RepositoryRoot 'config\runtime.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
$android = $config.android
$runtimeRoot = $RepositoryRoot

function Resolve-ConfiguredPath([string]$configuredPath) {
    if ([System.IO.Path]::IsPathRooted($configuredPath)) { return $configuredPath }
    return [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot ($configuredPath -replace '/', '\')))
}

$paths = [ordered]@{
    qemu = Resolve-ConfiguredPath $android.qemu.executable
    adb = Resolve-ConfiguredPath (Join-Path $android.tooling.sdkRoot $android.tooling.adbRelativePath)
    disk = Resolve-ConfiguredPath $android.qemu.disk
    installerImage = Resolve-ConfiguredPath $android.qemu.androidImage
    nativeBridge = Resolve-ConfiguredPath $android.provisioning.nativeBridgePackagePath
    webView = Resolve-ConfiguredPath $android.provisioning.webViewPackagePath
    tts = Resolve-ConfiguredPath $android.provisioning.ttsPackagePath
}

$required = @('qemu', 'adb', 'disk')
if ($RequireInstallerImage) { $required += 'installerImage' }
if ($RequireNativeBridge) { $required += 'nativeBridge' }
if ($RequireWebView) { $required += 'webView' }
if ($RequireTts) { $required += 'tts' }

$missing = @($required | Where-Object { -not (Test-Path -LiteralPath $paths[$_]) })
if ($missing.Count -gt 0) {
    throw "Provisionamento incompleto. Arquivos ausentes: $($missing -join ', '). O script não baixa binários; forneça componentes locais aprovados e repita."
}

$statePath = Resolve-ConfiguredPath $android.provisioning.statePath
$stateDirectory = Split-Path -Parent $statePath
if (-not (Test-Path -LiteralPath $stateDirectory)) { New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null }

$fileRecords = [ordered]@{}
foreach ($name in $paths.Keys) {
    if (Test-Path -LiteralPath $paths[$name]) {
        $file = Get-Item -LiteralPath $paths[$name]
        $fileRecords[$name] = [ordered]@{
            path = $paths[$name]
            length = $file.Length
            sha256 = (Get-FileHash -LiteralPath $paths[$name] -Algorithm SHA256).Hash
        }
    }
}
$origins = [ordered]@{
    qemu = $QemuOrigin
    adb = $AdbOrigin
    disk = 'local-persistent-guest-disk'
    installerImage = $AndroidImageOrigin
    nativeBridge = $NativeBridgeOrigin
    webView = $WebViewOrigin
    tts = $TtsOrigin
}
$provenance = [ordered]@{}
foreach ($name in $paths.Keys) {
    $hasFile = $fileRecords.Contains($name)
    $origin = [string]$origins[$name]
    $provenance[$name] = [ordered]@{
        path = $paths[$name]
        sha256 = if ($hasFile) { $fileRecords[$name].sha256 } else { $null }
        origin = if ([string]::IsNullOrWhiteSpace($origin)) { 'not-recorded' } else { $origin }
        status = if (-not $hasFile) { 'not-present' } elseif ([string]::IsNullOrWhiteSpace($origin) -and $name -notin @('disk')) { 'present-origin-missing' } else { 'present' }
    }
}

$state = [ordered]@{
    schema = 1
    androidImageVersion = $android.release
    nativeBridgeStatus = if (-not $fileRecords.Contains('nativeBridge')) { 'not-provisioned' } elseif ([string]::IsNullOrWhiteSpace($NativeBridgeOrigin)) { 'provisioned-local-origin-missing' } else { 'provisioned-local-origin-recorded' }
    webViewVersion = $config.webView.homologatedVersion
    ttsStatus = if (-not $fileRecords.Contains('tts')) { 'not-provisioned' } elseif ([string]::IsNullOrWhiteSpace($TtsOrigin)) { 'provisioned-local-origin-missing' } else { 'provisioned-local-origin-recorded' }
    neoNewsVersion = "$($config.neonews.versionName) ($($config.neonews.versionCode))"
    lastValidation = (Get-Date).ToUniversalTime().ToString('o')
    imageHash = $fileRecords['disk'].sha256
    files = $fileRecords
    provenance = $provenance
}
$state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding utf8
Write-Output ($state | ConvertTo-Json -Depth 8)
