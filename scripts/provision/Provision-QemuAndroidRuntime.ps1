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

function Test-NonEmptyFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try { return (Get-Item -LiteralPath $path).Length -gt 0 } catch { return $false }
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
$qemuImgPath = Join-Path (Split-Path -Parent $paths.qemu) 'qemu-img.exe'

$required = @('qemu', 'adb', 'disk')
# The configured Android-x86 image is part of the approved base runtime. Keep
# -RequireInstallerImage for callers that already pass it, but do not allow a
# provisioning state that omits the image while runtime.json references one.
if ($RequireInstallerImage -or -not [string]::IsNullOrWhiteSpace([string]$android.qemu.androidImage)) { $required += 'installerImage' }
if ($RequireNativeBridge) { $required += 'nativeBridge' }
if ($RequireWebView) { $required += 'webView' }
if ($RequireTts) { $required += 'tts' }

$missing = @($required | Where-Object { -not (Test-NonEmptyFile $paths[$_]) })
if ($missing.Count -gt 0) {
    throw "Provisionamento incompleto. Arquivos ausentes ou vazios: $($missing -join ', '). O script não baixa binários; forneça componentes locais aprovados e repita."
}
if (-not (Test-NonEmptyFile $qemuImgPath)) {
    throw "Provisionamento incompleto. qemu-img.exe ausente ou vazio: $qemuImgPath. A distribuição precisa manter o validador junto do QEMU."
}

$statePath = Resolve-ConfiguredPath $android.provisioning.statePath
$stateDirectory = Split-Path -Parent $statePath
if (-not (Test-Path -LiteralPath $stateDirectory)) { New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null }

$existingState = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $existingState = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { throw "O estado de provisionamento existente não pôde ser lido: $statePath. $($_.Exception.Message)" }
}

function Invoke-QemuImgJson {
    param(
        [string]$Command,
        [string]$ImagePath
    )
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $qemuImgPath $Command '--output=json' $ImagePath 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) {
        throw "qemu-img $Command falhou para $ImagePath; exit=$exitCode; output=$(($raw | Out-String).Trim())"
    }
    try { return (($raw | Out-String).Trim() | ConvertFrom-Json) }
    catch { throw "qemu-img $Command retornou JSON inválido para $ImagePath. $($_.Exception.Message)" }
}

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
$requiredOriginNames = @('qemu', 'adb', 'disk')
if ($RequireInstallerImage -or -not [string]::IsNullOrWhiteSpace([string]$android.qemu.androidImage)) { $requiredOriginNames += 'installerImage' }
if ($RequireNativeBridge) { $requiredOriginNames += 'nativeBridge' }
if ($RequireWebView) { $requiredOriginNames += 'webView' }
if ($RequireTts) { $requiredOriginNames += 'tts' }
foreach ($requiredOriginName in $requiredOriginNames) {
    if ([string]::IsNullOrWhiteSpace([string]$origins[$requiredOriginName])) {
        throw "Informe -$requiredOriginName`Origin para registrar a origem/licença do componente provisionado."
    }
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

$qemuInfo = Invoke-QemuImgJson -Command 'info' -ImagePath $paths.disk
$qemuCheck = Invoke-QemuImgJson -Command 'check' -ImagePath $paths.disk
$formatSpecificData = if ($qemuInfo.'format-specific'.data) { $qemuInfo.'format-specific'.data } else { $null }
$backingFile = [string]$qemuInfo.'backing-filename'
if ([string]::IsNullOrWhiteSpace($backingFile)) { $backingFile = [string]$qemuInfo.'full-backing-filename' }
$previousActive = if ($existingState -and $existingState.activeDiskMetadata) { $existingState.activeDiskMetadata } else { $null }
$baselineSha256 = if ($existingState -and [string]$existingState.baselineSha256 -match '^[0-9a-fA-F]{64}$') {
    [string]$existingState.baselineSha256
} elseif ($existingState -and [string]$existingState.imageHash -match '^[0-9a-fA-F]{64}$') {
    [string]$existingState.imageHash
} else {
    [string]$fileRecords['disk'].sha256
}
$diskFile = Get-Item -LiteralPath $paths.disk
$diskFingerprint = "{0:x}-{1:x}" -f $diskFile.Length, $diskFile.LastWriteTimeUtc.Ticks
$structuralFailure = [string]$qemuInfo.format -ne 'qcow2' -or
    [int]$qemuCheck.'check-errors' -ne 0 -or
    [bool]$formatSpecificData.corrupt -or
    [bool]$qemuInfo.'dirty-flag' -or
    -not [string]::IsNullOrWhiteSpace($backingFile) -or
    ($previousActive -and [long]$previousActive.virtualSizeBytes -gt 0 -and [long]$qemuInfo.'virtual-size' -ne [long]$previousActive.virtualSizeBytes)
if ($structuralFailure) {
    throw "UNEXPECTED_IMAGE_MUTATION: o qcow2 não passou na validação estrutural; format=$($qemuInfo.format); virtual-size=$($qemuInfo.'virtual-size'); backing=$backingFile; corrupt=$($formatSpecificData.corrupt); dirty=$($qemuInfo.'dirty-flag'); check-errors=$($qemuCheck.'check-errors')."
}
$activeDiskMetadata = [ordered]@{
    role = 'persistent-guest-disk'
    path = [string]$android.qemu.disk
    format = [string]$qemuInfo.format
    virtualSizeBytes = [long]$qemuInfo.'virtual-size'
    actualSizeBytes = [long]$qemuInfo.'actual-size'
    fileLengthBytes = [long]$diskFile.Length
    backingFile = $backingFile
    corrupt = [bool]$formatSpecificData.corrupt
    dirtyFlag = [bool]$qemuInfo.'dirty-flag'
    checkErrors = [int]$qemuCheck.'check-errors'
    allocatedClusters = [long]$qemuCheck.'allocated-clusters'
    fragmentedClusters = [long]$qemuCheck.'fragmented-clusters'
    currentSha256 = [string]$fileRecords['disk'].sha256
    status = if ([string]$fileRecords['disk'].sha256 -eq $baselineSha256) { 'BASELINE_UNCHANGED' } else { 'EXPECTED_PERSISTENT_MUTATION' }
    observedAt = (Get-Date).ToUniversalTime().ToString('o')
}

$state = [ordered]@{
    schema = 1
    androidImageVersion = $android.release
    nativeBridgeStatus = if (-not $fileRecords.Contains('nativeBridge')) { 'not-provisioned' } elseif ([string]::IsNullOrWhiteSpace($NativeBridgeOrigin)) { 'provisioned-local-origin-missing' } else { 'provisioned-local-origin-recorded' }
    webViewVersion = $config.webView.homologatedVersion
    ttsStatus = if (-not $fileRecords.Contains('tts')) { 'not-provisioned' } elseif ([string]::IsNullOrWhiteSpace($TtsOrigin)) { 'provisioned-local-origin-missing' } else { 'provisioned-local-origin-recorded' }
    neoNewsVersion = "$($config.neonews.versionName) ($($config.neonews.versionCode))"
    lastValidation = (Get-Date).ToUniversalTime().ToString('o')
    # imageHash remains the legacy name for the immutable approved baseline.
    imageHash = $baselineSha256
    baselineSha256 = $baselineSha256
    diskFingerprint = $diskFingerprint
    diskMutationStatus = $activeDiskMetadata.status
    activeDiskMetadata = $activeDiskMetadata
    files = $fileRecords
    provenance = $provenance
}
$state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding utf8
Write-Output ($state | ConvertTo-Json -Depth 8)
