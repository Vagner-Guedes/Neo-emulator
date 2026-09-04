[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$BootReportPath = 'reports/boot-diagnostics.json',
    [string]$WhpxReportPath = 'reports/whpx-diagnostics.json',
    [string]$ProvisioningPath = 'runtime/state/provisioning.json',
    [string]$ConfigPath = 'config/runtime.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepositoryPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $RepositoryRoot ($Path -replace '/', [System.IO.Path]::DirectorySeparatorChar))
}

function Read-JsonFile {
    param([string]$Path)
    $fullPath = Resolve-RepositoryPath $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $fullPath -Raw -Encoding utf8 | ConvertFrom-Json)
}

function Get-FileRecord {
    param(
        [string]$RelativePath,
        [string]$Role,
        [string]$Component,
        [string]$Origin,
        [string]$ExpectedSha256,
        [Nullable[long]]$ExpectedSize,
        [string]$State = 'required'
    )

    $fullPath = Resolve-RepositoryPath $RelativePath
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    $length = $null
    $sha256 = $null
    if ($exists) {
        $file = Get-Item -LiteralPath $fullPath
        $length = [long]$file.Length
        $sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToUpperInvariant()
    }

    $originRecorded = -not [string]::IsNullOrWhiteSpace($Origin) -and $Origin -notmatch '(?i)not[- ]recorded|unknown'
    $hashMatches = $null
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $exists) {
        $hashMatches = $sha256 -eq $ExpectedSha256.ToUpperInvariant()
    }
    $sizeMatches = $null
    if ($null -ne $ExpectedSize -and $exists) {
        $sizeMatches = $length -eq [long]$ExpectedSize
    }

    $status = if (-not $exists) {
        'MISSING'
    } elseif ($hashMatches -eq $false -or $sizeMatches -eq $false) {
        'PRESENT_IDENTITY_MISMATCH'
    } elseif (-not $originRecorded) {
        'PRESENT_ORIGIN_NOT_RECORDED'
    } elseif ($null -eq $hashMatches -and $null -eq $sizeMatches) {
        'PRESENT_NOT_PINNED'
    } else {
        'PRESENT_PINNED'
    }

    [ordered]@{
        path = $RelativePath.Replace('\', '/')
        role = $Role
        component = $Component
        state = $State
        exists = $exists
        sizeBytes = $length
        sha256 = $sha256
        expectedSizeBytes = $ExpectedSize
        expectedSha256 = if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { $null } else { $ExpectedSha256.ToUpperInvariant() }
        hashMatches = $hashMatches
        sizeMatches = $sizeMatches
        origin = if ([string]::IsNullOrWhiteSpace($Origin)) { 'not-recorded' } else { $Origin }
        originRecorded = $originRecorded
        status = $status
    }
}

function Invoke-ToolCapture {
    param([string]$Executable, [string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        return [ordered]@{ exitCode = $null; text = ''; error = "Executável ausente: $Executable" }
    }
    $lines = @(& $Executable @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = [int]$LASTEXITCODE
    [ordered]@{ exitCode = $exitCode; text = ($lines -join "`n"); error = '' }
}

function Convert-CapturedJson {
    param([object]$Captured)
    if ([string]::IsNullOrWhiteSpace([string]$Captured.text)) { return $null }
    try { return ([string]$Captured.text | ConvertFrom-Json) } catch { return $null }
}

function Get-JsonPropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

$config = Read-JsonFile $ConfigPath
$provisioning = Read-JsonFile $ProvisioningPath
$boot = Read-JsonFile $BootReportPath
$whpx = Read-JsonFile $WhpxReportPath
$reportsDirectory = Join-Path $RepositoryRoot 'reports'
New-Item -ItemType Directory -Force -Path $reportsDirectory | Out-Null

$rootRelativePath = [string]$config.android.qemu.disk
$rootPath = Resolve-RepositoryPath $rootRelativePath
$qemuPath = Resolve-RepositoryPath ([string]$config.android.qemu.executable)
$qemuImgPath = Join-Path (Split-Path -Parent $qemuPath) 'qemu-img.exe'
$rootHash = $null
if (Test-Path -LiteralPath $rootPath -PathType Leaf) {
    $rootHash = (Get-FileHash -LiteralPath $rootPath -Algorithm SHA256).Hash.ToUpperInvariant()
}
$infoCapture = Invoke-ToolCapture -Executable $qemuImgPath -Arguments @('info', '--output=json', $rootPath)
$checkCapture = Invoke-ToolCapture -Executable $qemuImgPath -Arguments @('check', '--output=json', $rootPath)
$rootInfo = Convert-CapturedJson $infoCapture
$rootCheck = Convert-CapturedJson $checkCapture
$activeMetadata = $provisioning.activeDiskMetadata
$expectedBaseline = [string]$provisioning.baselineSha256
$virtualSizeValue = Get-JsonPropertyValue -Object $rootInfo -Name 'virtual-size'
$checkErrorsValue = Get-JsonPropertyValue -Object $rootCheck -Name 'check-errors'
$dirtyFlagValue = Get-JsonPropertyValue -Object $rootInfo -Name 'dirty-flag'
$corruptValue = Get-JsonPropertyValue -Object $rootInfo -Name 'corrupt'
$backingFileValue = Get-JsonPropertyValue -Object $rootInfo -Name 'backing-filename'
$virtualSize = if ($null -ne $virtualSizeValue) { [long]$virtualSizeValue } else { $null }
$checkErrors = if ($null -ne $checkErrorsValue) { [int]$checkErrorsValue } else { $null }
$backingFile = if ($null -ne $backingFileValue) { [string]$backingFileValue } else { '' }
$structuralPass = (Test-Path -LiteralPath $rootPath -PathType Leaf) -and
    ($infoCapture.exitCode -eq 0) -and ($checkCapture.exitCode -eq 0) -and
    ($null -ne $rootInfo) -and ($null -ne $rootCheck) -and
    ([string]$rootInfo.format -eq 'qcow2') -and [string]::IsNullOrWhiteSpace($backingFile) -and
    ($false -eq [bool]$dirtyFlagValue) -and ($false -eq [bool]$corruptValue) -and
    ($checkErrors -eq 0) -and ($virtualSize -eq [long]$activeMetadata.virtualSizeBytes)
$baselinePass = (-not [string]::IsNullOrWhiteSpace($expectedBaseline)) -and ($rootHash -eq $expectedBaseline.ToUpperInvariant())

$imageReport = [ordered]@{
    schema = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    status = if ($structuralPass -and $baselinePass) { 'IMAGE_INTEGRITY_MODEL_PASS' } elseif ($structuralPass) { 'IMAGE_INTEGRITY_STRUCTURAL_PASS_BASELINE_MUTATION' } else { 'IMAGE_INTEGRITY_BLOCKED' }
    root = [ordered]@{
        path = $rootRelativePath.Replace('\', '/')
        exists = Test-Path -LiteralPath $rootPath -PathType Leaf
        baselineSha256 = $expectedBaseline.ToUpperInvariant()
        currentSha256 = $rootHash
        baselineUnchanged = $baselinePass
        qemuImgInfo = [ordered]@{ exitCode = $infoCapture.exitCode; data = $rootInfo; raw = $infoCapture.text }
        qemuImgCheck = [ordered]@{ exitCode = $checkCapture.exitCode; data = $rootCheck; raw = $checkCapture.text }
        activeDiskMetadata = $activeMetadata
    }
    policy = [ordered]@{
        approvedRootIsNeverWrittenByDisposableBoot = $true
        disposableBootsUseSparseOverlays = $true
        sha256ChangeWithValidQcow2IsPersistentMutation = $true
        noAutomaticResetWipeOrReplacement = $true
    }
}
$imageReport | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $reportsDirectory 'image-integrity.json') -Encoding utf8

$packageFiles = New-Object System.Collections.Generic.List[object]
$packageRoot = Join-Path $RepositoryRoot 'packages'
$nativeBridgeConfig = $config.android.nativeBridge.officialProvisioning
$packageMap = @{
    'packages/neonews/neonews.apk' = [ordered]@{ component = 'NeoNews ARM APK'; expectedSha256 = ''; expectedSize = $null; origin = 'not-recorded'; state = 'repair-artifact' }
    'packages/webview/webview.apk' = [ordered]@{ component = 'WebView 119 APK'; expectedSha256 = [string]$provisioning.files.webView.sha256; expectedSize = [long]$provisioning.files.webView.length; origin = 'not-recorded'; state = 'repair-artifact' }
    'packages/webview/.staging/webview-119-apkmirror.apk' = [ordered]@{ component = 'WebView 119 staging copy'; expectedSha256 = ''; expectedSize = $null; origin = 'not-recorded'; state = 'staging-copy' }
    'packages/webview/.staging/webview-119-googleplay.apk' = [ordered]@{ component = 'WebView 119 staging copy'; expectedSha256 = ''; expectedSize = $null; origin = 'not-recorded'; state = 'staging-copy' }
    'packages/tts/rhvoice.apk' = [ordered]@{ component = 'RHVoice engine APK'; expectedSha256 = ''; expectedSize = $null; origin = 'not-recorded'; state = 'repair-artifact' }
    'packages/tts/RHVoice-F123-Brazilian-Portuguese-language-v1.24.zip' = [ordered]@{ component = 'RHVoice pt-BR language'; expectedSha256 = ''; expectedSize = $null; origin = 'not-recorded'; state = 'repair-artifact' }
    'packages/tts/Leticia-F123-v4.6.zip' = [ordered]@{ component = 'RHVoice Letícia-F123 voice'; expectedSha256 = ''; expectedSize = $null; origin = 'not-recorded'; state = 'repair-artifact' }
    'packages/nativebridge/houdini7_y.sfs' = [ordered]@{ component = 'Houdini ARM32 7_y'; expectedSha256 = [string]$nativeBridgeConfig.arm32.sha256; expectedSize = [long]$nativeBridgeConfig.arm32.expectedSize; origin = [string]$nativeBridgeConfig.arm32.officialUrl; state = 'repair-artifact' }
    'packages/nativebridge/houdini7_z.sfs' = [ordered]@{ component = 'Houdini ARM64 7_z'; expectedSha256 = [string]$nativeBridgeConfig.arm64.sha256; expectedSize = [long]$nativeBridgeConfig.arm64.expectedSize; origin = [string]$nativeBridgeConfig.arm64.officialUrl; state = 'repair-artifact' }
}

if (Test-Path -LiteralPath $packageRoot -PathType Container) {
    Get-ChildItem -LiteralPath $packageRoot -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($RepositoryRoot.Length + 1).Replace('\', '/')
        if ($packageMap.ContainsKey($relative)) {
            $definition = $packageMap[$relative]
        } else {
            $definition = [ordered]@{ component = 'Package metadata'; expectedSha256 = ''; expectedSize = $null; origin = 'not-recorded'; state = 'unclassified' }
        }
        $packageFiles.Add((Get-FileRecord -RelativePath $relative -Role 'required-for-repair' -Component $definition.component -Origin $definition.origin -ExpectedSha256 $definition.expectedSha256 -ExpectedSize $definition.expectedSize -State $definition.state))
    }
}

$runtimeFiles = @(
    (Get-FileRecord -RelativePath ([string]$config.android.qemu.executable) -Role 'runtime-transport' -Component 'QEMU WHPX' -Origin ([string]$provisioning.provenance.qemu.origin) -ExpectedSha256 ([string]$provisioning.provenance.qemu.sha256) -ExpectedSize $null -State 'runtime-required'),
    (Get-FileRecord -RelativePath ('runtime/' + [string]$config.android.tooling.adbRelativePath) -Role 'runtime-transport' -Component 'ADB private transport' -Origin ([string]$provisioning.provenance.adb.origin) -ExpectedSha256 ([string]$provisioning.provenance.adb.sha256) -ExpectedSize $null -State 'runtime-required'),
    (Get-FileRecord -RelativePath ([string]$config.android.qemu.androidImage) -Role 'installer-input' -Component 'Android-x86 7.1-r5 ISO' -Origin ([string]$provisioning.provenance.installerImage.origin) -ExpectedSha256 ([string]$provisioning.provenance.installerImage.sha256) -ExpectedSize $null -State 'repair-input')
)

$runs = @()
if ($null -ne $boot -and $null -ne $boot.runs) {
    $runs = @($boot.runs | Sort-Object iteration)
}
$runEvidence = @($runs | ForEach-Object {
    [ordered]@{
        iteration = $_.iteration
        classification = $_.classification
        androidReady = [bool]$_.boot.bootCompleted
        deviceProbes = $_.boot.consecutiveDeviceProbes
        adbRoot = [bool]$_.guest.root.ready
        clockValidated = [bool]$_.guest.clock.validated
        clockSkewSeconds = $_.guest.clock.skewSeconds
        neoNewsPackage = [bool]$_.guest.neoNews.packagePresent
        webViewPackage = [bool]$_.guest.packages.webView
        rhvoicePackage = [bool]$_.guest.packages.rhvoice
        nativeBridgeProperty = [string]$_.guest.nativeBridgeProperty
        locale = [string]$_.guest.locale
        primaryCpuAbi = [string]$_.guest.neoNews.primaryCpuAbi
        launchSucceeded = [bool]$_.guest.neoNews.launch.succeeded
        stable60s = [bool]$_.guest.neoNews.stable60s.stable
        stabilitySamples = @($_.guest.neoNews.stable60s.samples).Count
        overlayCheckErrors = $_.overlay.check.'check-errors'
        qmpQuitResponseSucceeded = [bool]$_.qemu.stop.qmp.QmpQuitResponseSucceeded
    }
})
$allBootPass = $null -ne $boot -and [string]$boot.summary.diagnosis -eq 'BOOT_RELIABILITY_PASS'
$allPackageEvidence = $allBootPass -and $runEvidence.Count -gt 0 -and (@($runEvidence | Where-Object { -not $_.neoNewsPackage -or -not $_.webViewPackage -or -not $_.rhvoicePackage -or $_.primaryCpuAbi -ne 'armeabi-v7a' -or -not $_.stable60s }).Count -eq 0)
$nativeBridgeEvidenceGaps = @($runEvidence | Where-Object { $_.nativeBridgeProperty -ne 'libnb.so' })
$nativeBridgeEvidencePass = $allPackageEvidence -and $nativeBridgeEvidenceGaps.Count -eq 0
$repairOriginGaps = @($packageFiles | Where-Object { $_.state -eq 'repair-artifact' -and -not $_.originRecorded })
$packageStatus = if ($allPackageEvidence -and $repairOriginGaps.Count -eq 0) { 'PACKAGE_ARCHITECTURE_PASS' } elseif ($allPackageEvidence) { 'PACKAGE_ARCHITECTURE_EVIDENCE_ONLY_ORIGIN_GAP' } else { 'PACKAGE_ARCHITECTURE_BLOCKED' }
$imageEvidenceStatus = if ($allPackageEvidence) { 'CONFIRMED_IN_APPROVED_IMAGE' } else { 'NOT_CONFIRMED' }
$nativeBridgeStatus = if ($nativeBridgeEvidencePass) { 'CONFIRMED_IN_APPROVED_IMAGE' } else { 'NOT_CONFIRMED' }
$bakedInImage = @()
$bakedInImage += [ordered]@{ component = 'NeoNews'; package = 'com.in9midia.neonews.player'; status = $imageEvidenceStatus; evidence = $runEvidence }
$bakedInImage += [ordered]@{ component = 'WebView 119'; package = 'com.google.android.webview'; version = [string]$config.webView.homologatedVersion; status = $imageEvidenceStatus; evidence = $runEvidence }
$bakedInImage += [ordered]@{ component = 'RHVoice'; package = [string]$config.tts.providerPackage; locale = [string]$config.tts.locale; status = $imageEvidenceStatus; evidence = $runEvidence }
$bakedInImage += [ordered]@{ component = 'Native Bridge Houdini'; property = [string]$config.android.nativeBridge.property; expectedValue = 'libnb.so'; status = $nativeBridgeStatus; evidence = $runEvidence }

$packageReport = [ordered]@{
    schema = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    status = $packageStatus
    policy = [ordered]@{
        bakedInImageIsAuthoritative = $true
        repairUsesOnlyRecordedLocalOrOfficialArtifacts = $true
        noSilentDownload = $true
        noRandomMirror = $true
        noRhvoiceWebViewOrDebloatMutationInBootStage = $true
    }
    bakedInImage = $bakedInImage
    requiredForRepair = $packageFiles.ToArray()
    runtimeTransport = $runtimeFiles
    requiredForFirstRun = [ordered]@{
        items = @()
        status = 'NONE_FOR_APPROVED_PROVISIONED_IMAGE'
        rule = 'Se faltar um artefato, parar e solicitar artefato local/oficial com origem e SHA-256; não baixar silenciosamente.'
    }
    originGaps = @($repairOriginGaps | ForEach-Object { [string]$_.path })
}
$packageReport | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $reportsDirectory 'package-architecture.json') -Encoding utf8

[ordered]@{
    imageReport = (Join-Path $reportsDirectory 'image-integrity.json')
    packageReport = (Join-Path $reportsDirectory 'package-architecture.json')
    imageStatus = $imageReport.status
    packageStatus = $packageReport.status
} | ConvertTo-Json -Depth 5
