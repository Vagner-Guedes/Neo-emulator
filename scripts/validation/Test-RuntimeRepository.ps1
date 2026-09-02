[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$scriptErrors = @()
$scriptFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'scripts') -Filter '*.ps1' -Recurse)
foreach ($scriptFile in $scriptFiles) {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        foreach ($parseError in $parseErrors) {
            $scriptErrors += [pscustomobject]@{
                file = $scriptFile.FullName.Substring($RepositoryRoot.Length + 1)
                message = $parseError.Message
                line = $parseError.Extent.StartLineNumber
            }
        }
    }
}

$configPath = Join-Path $RepositoryRoot 'config\runtime.json'
$configValid = $true
$configError = $null
try {
    $configObject = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($configObject.schemaVersion -ne 2) { throw "runtime.json precisa usar schemaVersion=2." }
    if ($configObject.android.backend -ne 'qemu-android-x86') { throw "backend padrão precisa ser qemu-android-x86." }
    if ($configObject.android.adb.transport -ne 'tcp') { throw "ADB do backend QEMU precisa usar transporte tcp." }
} catch {
    $configValid = $false
    $configError = $_.Exception.Message
}

$requiredPaths = @(
    'config/runtime.json',
    'docs/AUDIT-ETAPA-1.md',
    'docs/ABI-ETAPA-3.md',
    'docs/WEBVIEW-ETAPA-4.md',
    'docs/TTS-ETAPA-5.md',
    'docs/NEONEWS-ETAPA-6.md',
    'docs/QEMU-API25-RUNTIME.md',
    'docs/QEMU-BENCHMARK.md',
    'docs/GUEST-NETWORK-MEDIA.md',
    'docs/QEMU-PERSISTENCE.md',
    'scripts/benchmark/Measure-QemuAndroidRuntime.ps1',
    'scripts/benchmark/Run-QemuNeoNewsBenchmark.ps1',
    'scripts/benchmark/QemuBenchmark.Common.ps1',
    'docs/WEBVIEW-CONTENT-PROBE.md',
    'docs/FINAL-REPORT.md',
    'scripts/provision/Provision-QemuAndroidRuntime.ps1',
    'scripts/provision/Install-GuestComponents.ps1',
    'scripts/validation/Test-NativeBridge.ps1',
    'scripts/validation/ValidationEvidence.Common.ps1',
    'scripts/validation/Test-RuntimeStability.ps1',
    'scripts/validation/Test-TtsSynthesis.ps1',
    'scripts/validation/Test-WebViewContent.ps1',
    'tools/tts-probe/AndroidManifest.xml',
    'tools/tts-probe/MainActivity.java',
    'tools/webview-probe/AndroidManifest.xml',
    'tools/webview-probe/MainActivity.java',
    'scripts/validation/Test-GuestNetworkMedia.ps1',
    'scripts/validation/Test-QemuPersistence.ps1',
    'scripts/validation/Test-LauncherSmoke.ps1',
    'scripts/validation/Test-HomologationChecklist.ps1',
    'scripts/startup/Register-NeoNewsStartup.ps1',
    'scripts/runtime/Start-NeoNews.ps1',
    'scripts/runtime/Ensure-NeoNewsRuntime.ps1',
    'scripts/runtime/Watch-NeoNews.ps1',
    'scripts/runtime/Apply-KioskSettings.ps1',
    'scripts/diagnostics/Collect-Diagnostics.ps1',
    'tools/media-probe/AndroidManifest.xml',
    'tools/media-probe/MainActivity.java',
    'launcher/NeoNews.Runtime.Launcher/Services/AndroidRuntimeParsing.cs',
    'launcher/NeoNews.Runtime.Launcher/Services/ApkManifestService.cs',
    'launcher/NeoNews.Runtime.Launcher/NeoNews.Runtime.Launcher.csproj'
)
$missingPaths = @($requiredPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_)) })
$contractErrors = @()
$qemuSourcePath = Join-Path $RepositoryRoot 'launcher\NeoNews.Runtime.Launcher\Services\QemuAndroidRuntimeBackend.cs'
$qemuSource = if (Test-Path -LiteralPath $qemuSourcePath) { Get-Content -LiteralPath $qemuSourcePath -Raw -Encoding utf8 } else { '' }
$runtimeControllerPath = Join-Path $RepositoryRoot 'launcher\NeoNews.Runtime.Launcher\Services\RuntimeController.cs'
$runtimeControllerSource = if (Test-Path -LiteralPath $runtimeControllerPath) { Get-Content -LiteralPath $runtimeControllerPath -Raw -Encoding utf8 } else { '' }
$publishScriptPath = Join-Path $RepositoryRoot 'scripts\build\Publish-NeoNewsRuntime.ps1'
$publishSource = if (Test-Path -LiteralPath $publishScriptPath) { Get-Content -LiteralPath $publishScriptPath -Raw -Encoding utf8 } else { '' }
$componentProvisioningPath = Join-Path $RepositoryRoot 'scripts\provision\Install-GuestComponents.ps1'
$componentProvisioningSource = if (Test-Path -LiteralPath $componentProvisioningPath) { Get-Content -LiteralPath $componentProvisioningPath -Raw -Encoding utf8 } else { '' }
$baseProvisioningPath = Join-Path $RepositoryRoot 'scripts\provision\Provision-QemuAndroidRuntime.ps1'
$baseProvisioningSource = if (Test-Path -LiteralPath $baseProvisioningPath) { Get-Content -LiteralPath $baseProvisioningPath -Raw -Encoding utf8 } else { '' }
$qemuBenchmarkCommonPath = Join-Path $RepositoryRoot 'scripts\benchmark\QemuBenchmark.Common.ps1'
$qemuBenchmarkCommonSource = if (Test-Path -LiteralPath $qemuBenchmarkCommonPath) { Get-Content -LiteralPath $qemuBenchmarkCommonPath -Raw -Encoding utf8 } else { '' }
$persistencePath = Join-Path $RepositoryRoot 'scripts\validation\Test-QemuPersistence.ps1'
$persistenceSource = if (Test-Path -LiteralPath $persistencePath) { Get-Content -LiteralPath $persistencePath -Raw -Encoding utf8 } else { '' }
$benchmarkPath = Join-Path $RepositoryRoot 'scripts\benchmark\Run-QemuNeoNewsBenchmark.ps1'
$benchmarkSource = if (Test-Path -LiteralPath $benchmarkPath) { Get-Content -LiteralPath $benchmarkPath -Raw -Encoding utf8 } else { '' }
$measurePath = Join-Path $RepositoryRoot 'scripts\benchmark\Measure-QemuAndroidRuntime.ps1'
$measureSource = if (Test-Path -LiteralPath $measurePath) { Get-Content -LiteralPath $measurePath -Raw -Encoding utf8 } else { '' }
$networkMediaPath = Join-Path $RepositoryRoot 'scripts\validation\Test-GuestNetworkMedia.ps1'
$networkMediaSource = if (Test-Path -LiteralPath $networkMediaPath) { Get-Content -LiteralPath $networkMediaPath -Raw -Encoding utf8 } else { '' }
$nativeBridgeValidationPath = Join-Path $RepositoryRoot 'scripts\validation\Test-NativeBridge.ps1'
$nativeBridgeValidationSource = if (Test-Path -LiteralPath $nativeBridgeValidationPath) { Get-Content -LiteralPath $nativeBridgeValidationPath -Raw -Encoding utf8 } else { '' }
$integratedStabilityPath = Join-Path $RepositoryRoot 'scripts\validation\Test-RuntimeStability.ps1'
$integratedStabilitySource = if (Test-Path -LiteralPath $integratedStabilityPath) { Get-Content -LiteralPath $integratedStabilityPath -Raw -Encoding utf8 } else { '' }
$webViewProviderPath = Join-Path $RepositoryRoot 'scripts\validation\Test-WebViewProvider.ps1'
$webViewProviderSource = if (Test-Path -LiteralPath $webViewProviderPath) { Get-Content -LiteralPath $webViewProviderPath -Raw -Encoding utf8 } else { '' }
$webViewContentPath = Join-Path $RepositoryRoot 'scripts\validation\Test-WebViewContent.ps1'
$webViewContentSource = if (Test-Path -LiteralPath $webViewContentPath) { Get-Content -LiteralPath $webViewContentPath -Raw -Encoding utf8 } else { '' }
$ttsProviderPath = Join-Path $RepositoryRoot 'scripts\validation\Test-TtsProvider.ps1'
$ttsProviderSource = if (Test-Path -LiteralPath $ttsProviderPath) { Get-Content -LiteralPath $ttsProviderPath -Raw -Encoding utf8 } else { '' }
$ttsSynthesisPath = Join-Path $RepositoryRoot 'scripts\validation\Test-TtsSynthesis.ps1'
$ttsSynthesisSource = if (Test-Path -LiteralPath $ttsSynthesisPath) { Get-Content -LiteralPath $ttsSynthesisPath -Raw -Encoding utf8 } else { '' }
$checklistPath = Join-Path $RepositoryRoot 'scripts\validation\Test-HomologationChecklist.ps1'
$checklistSource = if (Test-Path -LiteralPath $checklistPath) { Get-Content -LiteralPath $checklistPath -Raw -Encoding utf8 } else { '' }
$diagnosticsScriptPath = Join-Path $RepositoryRoot 'scripts\diagnostics\Collect-Diagnostics.ps1'
$diagnosticsScriptSource = if (Test-Path -LiteralPath $diagnosticsScriptPath) { Get-Content -LiteralPath $diagnosticsScriptPath -Raw -Encoding utf8 } else { '' }
$validationEvidenceCommonPath = Join-Path $RepositoryRoot 'scripts\validation\ValidationEvidence.Common.ps1'
$validationEvidenceCommonSource = if (Test-Path -LiteralPath $validationEvidenceCommonPath) { Get-Content -LiteralPath $validationEvidenceCommonPath -Raw -Encoding utf8 } else { '' }
$launcherSmokePath = Join-Path $RepositoryRoot 'scripts\validation\Test-LauncherSmoke.ps1'
$launcherSmokeSource = if (Test-Path -LiteralPath $launcherSmokePath) { Get-Content -LiteralPath $launcherSmokePath -Raw -Encoding utf8 } else { '' }
$startupScriptPath = Join-Path $RepositoryRoot 'scripts\startup\Register-NeoNewsStartup.ps1'
$startupScriptSource = if (Test-Path -LiteralPath $startupScriptPath) { Get-Content -LiteralPath $startupScriptPath -Raw -Encoding utf8 } else { '' }
$startNeoNewsPath = Join-Path $RepositoryRoot 'scripts\runtime\Start-NeoNews.ps1'
$startNeoNewsSource = if (Test-Path -LiteralPath $startNeoNewsPath) { Get-Content -LiteralPath $startNeoNewsPath -Raw -Encoding utf8 } else { '' }
$ensureNeoNewsPath = Join-Path $RepositoryRoot 'scripts\runtime\Ensure-NeoNewsRuntime.ps1'
$ensureNeoNewsSource = if (Test-Path -LiteralPath $ensureNeoNewsPath) { Get-Content -LiteralPath $ensureNeoNewsPath -Raw -Encoding utf8 } else { '' }
$watchNeoNewsPath = Join-Path $RepositoryRoot 'scripts\runtime\Watch-NeoNews.ps1'
$watchNeoNewsSource = if (Test-Path -LiteralPath $watchNeoNewsPath) { Get-Content -LiteralPath $watchNeoNewsPath -Raw -Encoding utf8 } else { '' }
$kioskScriptPath = Join-Path $RepositoryRoot 'scripts\runtime\Apply-KioskSettings.ps1'
$kioskScriptSource = if (Test-Path -LiteralPath $kioskScriptPath) { Get-Content -LiteralPath $kioskScriptPath -Raw -Encoding utf8 } else { '' }
$launcherSources = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'launcher\NeoNews.Runtime.Launcher') -Filter '*.cs' -Recurse -ErrorAction SilentlyContinue)
$launcherSourceText = (($launcherSources | Get-Content -Raw -Encoding utf8) -join "`n")
$contractChecks = [ordered]@{
    qemuBackend = $qemuSource -match 'class QemuAndroidRuntimeBackend'
    whpxRequired = $qemuSource -match 'CheckWhpx' -and $qemuSource -match '"-accel"'
    qmpShutdown = $qemuSource -match 'RequestQmpShutdownAsync' -and $qemuSource -match 'qmp_capabilities' -and $qemuSource -match 'ReadQmpResponseAsync' -and $qemuSource -match 'IsQmpSuccess' -and $qemuSource -match '"quit"'
    persistentQcow2 = [string]$configObject.android.qemu.disk -match '(?i)\.qcow2$' -and $qemuSource -match 'format=qcow2'
    qemuRequiresProvisionedAndroidImage = $qemuSource -match 'ResolveAndroidImagePath' -and $qemuSource -match 'androidImage' -and $qemuSource -match 'Imagem Android-x86'
    whpxProbesHypervisorCapability = $qemuSource -match 'WHvGetCapability' -and $qemuSource -match 'WhvCapabilityCodeHypervisorPresent' -and $qemuSource -match 'HypervisorPresent'
    noSilentTcg = -not [bool]$configObject.android.qemu.allowTcgForDiagnostics -and $qemuSource -match 'AllowTcgForDiagnostics'
    noQemuEmuKill = $launcherSourceText -notmatch '(?i)adb\s+emu\s+kill'
    noAutomaticDestructiveGuestOperation = $launcherSourceText -notmatch '(?i)(pm\s+clear|adb\s+uninstall|factory\s+reset|format\s+userdata)' -and $webViewContentSource -notmatch '(?i)if\s*\(\s*-not\s+\$KeepProbe\s*\).*uninstall' -and $ttsSynthesisSource -notmatch '(?i)if\s*\(\s*-not\s+\$KeepProbe\s*\).*uninstall' -and $networkMediaSource -notmatch '(?i)if\s*\(\s*-not\s+\$KeepProbe\s*\).*uninstall'
    portableRuntimePaths = [string]$configObject.android.qemu.executable -match '(?i)^runtime[\\/]' -and [string]$configObject.android.qemu.disk -match '(?i)^runtime[\\/]'
    qemuEnvironmentFallbackDisabled = -not [bool]$configObject.android.tooling.allowEnvironmentFallback
    installEvidenceTracksAdbSuccess = $launcherSourceText -match 'LastInstallSucceeded' -and $launcherSourceText -match 'InstallApkAsync'
    noConfiguredAbiEvidenceFallback = $runtimeControllerSource -notmatch 'return\s+_context\.Config\.NeoNews\.SupportedApkAbis'
    existingInstallCanReachStabilityGate = $launcherSourceText -match 'guest\.Ready\s+&&\s+selected\s+is\s+not\s+null\s+&&\s+launched'
    existingInstalledPackageCanStartOffline = $launcherSourceText -match 'var installationRequired = !status\.Installed \|\| versionMismatch' -and $launcherSourceText -match 'if \(installationRequired\)' -and $launcherSourceText -match 'ValidateAuthorizedApk\(apkPath\)'
    offlineInstalledApkUsesPackageAbiEvidence = $launcherSourceText -match 'apkAbis\.Count == 0' -and $launcherSourceText -match 'package-manager evidence is enough'
    activityGateRequiresForegroundState = $launcherSourceText -match 'mResumedActivity' -and $launcherSourceText -match 'mFocusedActivity' -and $launcherSourceText -match 'IsActivityRunningAsync'
    diagnosticsIncludesNeoNewsActivity = $launcherSourceText -match 'packageName = _neoNews\.PackageName' -and $launcherSourceText -match 'activity = _neoNews\.ActivityName' -and $launcherSourceText -match 'versionCode = neoNewsVersionCode' -and $launcherSourceText -match 'primaryCpuAbi'
    diagnosticsIncludesApkIdentity = $launcherSourceText -match 'apkMetadata\?\.PackageName' -and $launcherSourceText -match 'apkMetadata\?\.VersionName' -and $launcherSourceText -match 'apkMetadata\?\.VersionCode'
    apkPreinstallIdentityValidation = $launcherSourceText -match 'ApkManifestService\.Read\(apkPath\)' -and $launcherSourceText -match 'metadata\.PackageName\.Equals\(PackageName' -and $launcherSourceText -match 'metadata\.VersionCode'
    apkPreinstallAbiValidation = $launcherSourceText -match 'ReadApkAbis\(apkPath\)' -and $launcherSourceText -match 'apkAbis\.Contains\(preferredAbi' -and $launcherSourceText -match 'containsGuestAbi'
    nativeBridgeProbePreflightManifest = $nativeBridgeValidationSource -match 'Read-ApkManifestIdentity' -and $nativeBridgeValidationSource -match '\$apkIdentity\.PackageName' -and $nativeBridgeValidationSource -match '\$apkIdentity\.VersionCode' -and $nativeBridgeValidationSource -match 'Nenhuma'
    nativeBridgeProbePreflightSignature = $nativeBridgeValidationSource -match 'Read-ApkCertificateSha256' -and $nativeBridgeValidationSource -match '\$expectedCertificateSha256' -and $nativeBridgeValidationSource -match 'apkSignatureMatches'
    nativeBridgeProbeDefinesPreferredAbi = $nativeBridgeValidationSource.Contains('$preferredApkAbi')
    nativeBridgeProbeRejectsMissingPreferredAbi = $nativeBridgeValidationSource.Contains('Nenhuma')
    nativeBridgeProbeRejectsGuestAbi = $nativeBridgeValidationSource.Contains("'x86', 'x86_64'")
    nativeBridgeProbePreflightAbi = $nativeBridgeValidationSource.Contains('$preferredApkAbi') -and $nativeBridgeValidationSource.Contains('Nenhuma') -and $nativeBridgeValidationSource.Contains("'x86', 'x86_64'")
    diagnosticsIncludesProvisioningState = $launcherSourceText -match 'SafeProvisioningStateAsync' -and $launcherSourceText -match 'imageHash = provisioningState\.ImageHash' -and $launcherSourceText -match 'diskFingerprint = provisioningState\.DiskFingerprint'
    diagnosticsCliExitsAfterCollection = $launcherSourceText -match 'exitAfterDiagnostics' -and $launcherSourceText -match 'RequestExit\(\)'
    diagnosticsScriptUsesCanonicalLauncher = $diagnosticsScriptSource -match "ArgumentList '--diagnostics'" -and $diagnosticsScriptSource -match 'schema.*identidade'
    diagnosticsSupportsExplicitExecutable = $diagnosticsScriptSource -match '\[string\]\$ExecutablePath' -and $diagnosticsScriptSource -match 'GetFullPath\(\$ExecutablePath\)'
    prolongedStabilityEvidence = $nativeBridgeValidationSource -match 'stabilitySeconds = \$StabilitySeconds' -and $checklistSource -match 'MinimumStabilitySeconds' -and $checklistSource -match 'stabilitySeconds'
    integratedStabilityEvidence = $integratedStabilitySource -match 'DurationSeconds = 600' -and $integratedStabilitySource -match 'watchdog\.active' -and $integratedStabilitySource -match 'Test-KioskState' -and $integratedStabilitySource -match 'webView\.status' -and $integratedStabilitySource -match 'voice\.localeReady' -and $checklistSource -match 'runtime-stability.json'
    integratedStabilityRequiresNeoNewsContent = $integratedStabilitySource -match 'LauncherSmokeEvidencePath' -and $integratedStabilitySource -match 'neoNewsContentObserved' -and $integratedStabilitySource -match 'neoNewsPlaybackObserved' -and $integratedStabilitySource -match 'Test-NeoNewsContentEvidence'
    checklistRequiresApkManifestIdentity = $checklistSource -match "apk\.packageName" -and $checklistSource -match "apk\.versionName" -and $checklistSource -match "apk\.versionCode"
    configurableAdbPorts = $checklistSource -match 'hostPort\s*-gt 0' -and $checklistSource -match 'guestPort\s*-gt 0' -and $checklistSource -match 'adbRequirement'
    nativeBridgeCommandsRequireExitCode = $nativeBridgeValidationSource -match 'Invoke-AdbResult' -and $nativeBridgeValidationSource -match 'propertyExitCodes' -and $nativeBridgeValidationSource -match 'packageDumpExitCode' -and $nativeBridgeValidationSource -match 'activityDumpExitCode' -and $nativeBridgeValidationSource -match 'logcatExitCode' -and $nativeBridgeValidationSource -match 'installExitCode -eq 0' -and $nativeBridgeValidationSource -match 'launchExitCode -eq 0'
    nativeBridgeGateRequiresRuntimeEvidence = $checklistSource -match 'native-bridge-property' -and $checklistSource -match 'abiCompatibility\.runtimeStable' -and $checklistSource -match 'Has-PropertyValue \$native ''runtimeStable'' \$true'
    backendGateRequiresLiveProcess = $checklistSource -match 'backend-qemu-whpx' -and $checklistSource -match 'tools\.backendProcess'' \$true'
    adbGateRequiresOnlineGuest = $checklistSource -match 'adb-tcp' -and $checklistSource -match 'android\.adb\.online'' \$true'
    webViewProviderQueriesRequireExitCode = $webViewProviderSource -match 'Invoke-AdbResult' -and $webViewProviderSource -match 'webViewDumpResult\.ExitCode' -and $webViewProviderSource -match 'packageDumpResult\.ExitCode'
    webViewContentQueriesRequireExitCode = $webViewContentSource -match 'webViewDumpResult\.ExitCode' -and $webViewContentSource -match 'packageDumpResult\.ExitCode' -and $webViewContentSource -match 'guestApiResult\.ExitCode'
    ttsProviderQueriesRequireExitCode = $ttsProviderSource -match 'Invoke-AdbResult' -and $ttsProviderSource -match 'allPackagesResult\.ExitCode' -and $ttsProviderSource -match 'defaultEngineResult\.ExitCode'
    probeCleanupRequiresExplicitSwitch = $webViewContentSource -match '\[switch\]\$CleanupProbe' -and $webViewContentSource -match '\$CleanupProbe\s+-and\s+-not\s+\$KeepProbe' -and $ttsSynthesisSource -match '\[switch\]\$CleanupProbe' -and $ttsSynthesisSource -match '\$CleanupProbe\s+-and\s+-not\s+\$KeepProbe' -and $networkMediaSource -match '\[switch\]\$CleanupProbe' -and $networkMediaSource -match '\$CleanupProbe\s+-and\s+-not\s+\$KeepProbe'
    arm32NativeBridgeAbiIsRequired = $launcherSourceText -match 'PreferredAbi' -and $launcherSourceText -match 'primary\.Equals\(preferredAbi'
    uiNativeBridgeStateRequiresRuntimeEvidence = $runtimeControllerSource -match '_lastAbiCompatibility\?\.RuntimeStable == true' -and $runtimeControllerSource -match 'NativeBridgeState\.Unknown'
    watchdogStopsOnStructuralRuntimeFailure = $launcherSourceText -match 'ContainsStructuralRuntimeFailure' -and $launcherSourceText -match 'GetLogcatAsync\(160' -and $launcherSourceText -match '_nativeBridgeStructuralError = true'
    kioskRestoresGuestStateOnFailedEntry = $launcherSourceText -match 'capturedHere' -and $launcherSourceText -match 'RestoreGuestStateAsync'
    kioskValidatesWindowGeometry = $launcherSourceText -match 'IsKioskWindowApplied' -and $launcherSourceText -match 'GetWindowRect'
    kioskRetriesBackendWindowDiscovery = $launcherSourceText -match 'CaptureAndMaximizeEmulatorWindowAsync' -and $launcherSourceText -match 'const int attempts = 12' -and $launcherSourceText -match 'backend PID/title pair'
    kioskPreservesOriginalWindowState = $launcherSourceText -match '_windowCaptured.*IsWindow\(_windowHandle\)' -and $launcherSourceText -match '_originalStyle = originalStyle' -and $launcherSourceText -match 'RestoreEmulatorWindow'
    normalBootRequiresProvisioningState = $launcherSourceText -match 'Provisionamento local ainda' -and $launcherSourceText -match 'DiskFingerprint'
    provisioningPreservesStrongDiskHash = $launcherSourceText -match 'Keep it intact' -and $launcherSourceText -match 'ImageHash'
    mutableQcow2FingerprintDoesNotBlockBoot = $launcherSourceText -match 'valid guest write into a' -and $launcherSourceText -match 'state\.DiskFingerprint = fingerprint'
    provisioningRejectsWeakOrMissingHash = $launcherSourceText -match 'IsSha256' -and $launcherSourceText -match 'SHA-256 forte'
    provisioningRequiresExactImageRelease = $launcherSourceText -match 'string\.IsNullOrWhiteSpace\(state\.AndroidImageVersion\)' -and $qemuBenchmarkCommonSource -match 'IsNullOrWhiteSpace\(\[string\]\$state\.androidImageVersion\)' -and $componentProvisioningSource -match 'existingState\.androidImageVersion'
    provisioningRevalidatesBaseBinaryHashes = $launcherSourceText -match 'foreach \(var componentName' -and $launcherSourceText -match 'ComputeSha256Async\(qemu' -and $launcherSourceText -match 'ComputeSha256Async\(adb'
    provisioningRevalidatesAndroidImageHash = $launcherSourceText -match 'ComputeSha256Async\(image' -and $launcherSourceText -match 'Provenance\["installerImage"\]' -and $launcherSourceText -match 'registeredImageHash'
    provisioningRejectsEmptyBaseFiles = $launcherSourceText -match 'HasContent\(qemu\)' -and $qemuSource -match 'HasContent\(executable\)' -and $baseProvisioningSource -match 'Test-NonEmptyFile' -and $componentProvisioningSource -match 'Test-NonEmptyFile'
    qemuEvidenceRequiresProvisionedRuntime = $qemuBenchmarkCommonSource -match 'Assert-QemuBenchmarkProvisionedRuntime' -and $qemuBenchmarkCommonSource -match 'provenance\.\$name' -and $qemuBenchmarkCommonSource -match 'installerImage' -and $persistenceSource -match 'Assert-QemuBenchmarkProvisionedRuntime' -and $benchmarkSource -match 'Assert-QemuBenchmarkProvisionedRuntime' -and $measureSource -match 'Assert-QemuBenchmarkProvisionedRuntime'
    validationReportsInvalidateBeforeProbe = $validationEvidenceCommonSource -match "evidenceState = 'invalidated'" -and $validationEvidenceCommonSource -match "status = 'not-validated'" -and $nativeBridgeValidationSource -match 'Initialize-ValidationReport' -and $webViewProviderSource -match 'Initialize-ValidationReport' -and $webViewContentSource -match 'Initialize-ValidationReport' -and $ttsProviderSource -match 'Initialize-ValidationReport' -and $ttsSynthesisSource -match 'Initialize-ValidationReport' -and $networkMediaSource -match 'Initialize-ValidationReport' -and $launcherSmokeSource -match 'Initialize-ValidationReport' -and $persistenceSource -match 'Initialize-ValidationReport' -and $benchmarkSource -match 'Initialize-ValidationReport' -and $measureSource -match 'Initialize-ValidationReport' -and $integratedStabilitySource -match 'Initialize-ValidationReport' -and $diagnosticsScriptSource -match 'Initialize-ValidationReport'
    componentProvisioningMergesState = $componentProvisioningSource -match 'existingState\.provenance' -and $componentProvisioningSource -match 'existingState\.imageHash'
    componentProvisioningRequiresStrongState = $componentProvisioningSource -match 'Estado base de provisionamento' -and $componentProvisioningSource -match 'existingImageHash' -and $componentProvisioningSource -match '\^\[0-9a-fA-F\]\{64\}\$'
    componentProvisioningValidatesBaseHashes = $componentProvisioningSource -match 'basePaths' -and $componentProvisioningSource -match 'installerImage' -and $componentProvisioningSource -match 'Get-FileHash' -and $componentProvisioningSource -match "baseName -ne 'disk'"
    componentProvisioningRequiresOrigin = $componentProvisioningSource -match 'requestedOrigins' -and $componentProvisioningSource -match 'requestedComponent.*Origin' -and $componentProvisioningSource -match 'InstallNativeBridge'
    componentProvisioningRequiresBaseOrigins = $componentProvisioningSource -match 'record\.origin' -and $componentProvisioningSource -match 'provenance do componente-base'
    componentProvisioningVerifiesWebViewAfterInstall = $componentProvisioningSource -match 'webViewPackagePresent' -and $componentProvisioningSource -match 'webViewProviderActive' -and $componentProvisioningSource -match 'webViewVersionMatches' -and $componentProvisioningSource -match 'if \(\$InstallWebView'
    componentProvisioningVerifiesGuestIdentity = $componentProvisioningSource -match 'ro\.build\.version\.release' -and $componentProvisioningSource -match 'ro\.build\.version\.sdk' -and $componentProvisioningSource -match '\$guestRelease' -and $componentProvisioningSource -match '\$guestApi'
    baseProvisioningRequiresOrigin = $baseProvisioningSource -match 'requiredOriginNames' -and $baseProvisioningSource -match 'origins\[\$requiredOriginName\]' -and $launcherSourceText -match 'string\.IsNullOrWhiteSpace\(component\.Origin\)'
    noProprietaryBinaryPublication = $publishSource -notmatch '(?i)\$sourceApk|Copy-Item[^\r\n]*(app\.apk|neonews\.apk|webview\.apk|rhvoice\.apk|nativebridge\.)'
    publishPreservesPersistentDisk = $publishSource -match 'persistentDiskTargetPath' -and $publishSource -match 'Preservando disco persistente existente' -and $publishSource -match 'OrdinalIgnoreCase'
    guestNetworkQmpNegotiatesCapabilities = $networkMediaSource -match 'qmp_capabilities' -and $networkMediaSource -match 'set_link' -and $networkMediaSource -match 'Test-QemuQmpSuccess' -and $networkMediaSource -match 'qmpLinkDownConfirmed' -and $networkMediaSource -match 'qmpLinkRestoreConfirmed'
    qmpReadersSkipAsyncEvents = $qemuBenchmarkCommonSource -match 'function Read-QemuQmpResponse' -and $qemuBenchmarkCommonSource -match 'QMP events' -and $qemuBenchmarkCommonSource -match 'Read-QemuQmpResponse \$reader' -and $networkMediaSource -match 'Read-QemuQmpResponse \$reader'
    qmpShutdownRequiresPositiveEvidence = $qemuBenchmarkCommonSource -match 'QmpCapabilitiesSucceeded' -and $qemuBenchmarkCommonSource -match 'QmpQuitResponseSucceeded' -and $qemuBenchmarkCommonSource -match 'QmpShutdownSucceeded' -and $qemuBenchmarkCommonSource -match 'ForcedKill' -and $benchmarkSource -match 'qmpCapabilitiesSucceeded' -and $benchmarkSource -match 'qmpQuitSent' -and $benchmarkSource -match 'qmpQuitResponseSucceeded' -and $benchmarkSource -match 'qmpShutdownSucceeded' -and $persistenceSource -match 'firstQmpCapabilitiesSucceeded' -and $persistenceSource -match 'firstQmpQuitSent' -and $persistenceSource -match 'firstQmpQuitResponseSucceeded' -and $persistenceSource -match 'firstQmpShutdownSucceeded' -and $checklistSource -match 'qmp-shutdown.*qmpQuitResponseSucceeded'
    staleEvidenceCannotApprove = $checklistSource -match 'EvidenceMaxAgeHours' -and $checklistSource -match 'Test-ReportFresh' -and $checklistSource -match 'reportFreshness' -and $checklistSource -match "evidenceState.*invalidated"
    reportIdentityGate = $checklistSource -match 'function Test-ReportTransport' -and $checklistSource -match 'function Test-DiagnosticsIdentity' -and $checklistSource -match 'Test-QemuReportIdentity'
    persistenceReportIncludesTransportIdentity = (Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts\validation\Test-QemuPersistence.ps1') -Raw -Encoding utf8) -match 'transport\s*=\s*\$config\.android\.adb\.transport' -and (Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts\validation\Test-QemuPersistence.ps1') -Raw -Encoding utf8) -match 'serial\s*=\s*\$serial'
    benchmarkReportIncludesTransportIdentity = (Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts\benchmark\Run-QemuNeoNewsBenchmark.ps1') -Raw -Encoding utf8) -match 'transport\s*=\s*\$config\.android\.adb\.transport' -and (Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts\benchmark\Run-QemuNeoNewsBenchmark.ps1') -Raw -Encoding utf8) -match 'serial\s*=\s*\$serial'
    baseProvisioningRequiresConfiguredImage = $baseProvisioningSource -match '\$android\.qemu\.androidImage' -and $baseProvisioningSource -match "\$required \+= 'installerImage'"
    watchdogKeepsBackendRecoveryWhenActivityRestartDisabled = $launcherSourceText -match 'RestartOnActivityLoss && status\.Installed && !status\.Running'
    watchdogTogglePersistsConfiguration = $runtimeControllerSource -match 'Config\.Supervisor\.RestartOnActivityLoss = enabled'
    runtimeOnlyStartsWatchdogWhenEnabled = $runtimeControllerSource -match 'StartSupervisorIfEnabledAsync' -and $runtimeControllerSource -match 'RestartOnActivityLoss \? _supervisor\.StartAsync'
    uiUsesGuestNetworkState = $launcherSourceText -match 'InternetRuntimeState\.Online' -and $launcherSourceText -notmatch 'NetworkInterface\.GetIsNetworkAvailable'
    uiDoesNotShowUnverifiedWebViewVersion = $launcherSourceText -match 'WebViewRuntimeState\.Ready' -and $launcherSourceText -notmatch 'Config\.WebView\.InstalledVersion'
    uiRefreshesPersistedRuntimeToggles = $launcherSourceText -match 'nameof\(StartWithWindows\)' -and $launcherSourceText -match 'nameof\(WatchdogEnabled\)'
    kioskEvidenceIncludesScreensaverOff = $launcherSourceText -match 'screensaverEnabled\s*=\s*guest\.ScreensaverEnabled' -and $integratedStabilitySource -match 'kiosk\.screensaverEnabled' -and $checklistSource -match 'android\.kiosk\.screensaverEnabled'
    uiUsesSelectedBackendGpu = $launcherSourceText -match 'Backend\.Equals\("qemu-android-x86"' -and $launcherSourceText -match 'Config\.Android\.Qemu\.Gpu'
    checklistStatusCoversAllDeclaredGates = $checklistSource -match '\$items\.Count -gt 0' -and $checklistSource -match '\$failed\.Count -eq 0' -and $checklistSource -match '\$pending\.Count -eq 0'
}
$contractChecks['watchdogLogsWithCooldown'] = $launcherSourceText -match 'ShouldLog\(ref _lastAdbOfflineLog\)' -and $launcherSourceText -match 'cooldownSeconds = Math\.Max\(15'
$contractChecks['stabilityRunnerStopsOnStartFailure'] = $integratedStabilitySource -match 'startCommandExitCode -ne 0' -and $integratedStabilitySource -match 'comando --start falhou'
$contractChecks['checklistReportInvalidatesAtStart'] = $checklistSource -match 'Initialize-ValidationReport' -and $checklistSource -match 'Test-ReportFresh'
$contractChecks['checklistBindsPublishedEvidence'] = $checklistSource -match 'function Get-ReportPublicationDirectory' -and $checklistSource -match 'function Test-ReportPublicationIdentity' -and $checklistSource -match 'publicationIdentityMatches'
$contractChecks['autostartHonorsKioskWhenNeoNewsDisabled'] = $launcherSourceText -match 'StartAutostartAsync' -and $launcherSourceText -match 'Startup\.StartNeoNews' -and $launcherSourceText -match 'Startup\.AutoKiosk' -and $launcherSourceText -match 'StartSupervisorIfEnabledAsync'
$contractChecks['launcherSmokeDefaultsToItsPublishedRuntime'] = $launcherSmokeSource -match '\[string\]\$ReportPath' -and $launcherSmokeSource.Contains("Join-Path `$workingDirectory 'reports\launcher-smoke.json'")
$contractChecks['webViewProviderHasChecklistReportDefault'] = $webViewProviderSource.Contains("[string]`$ReportPath = 'reports/webview-provider.json'") -and $checklistSource.Contains("Read-Report 'webview-provider.json'")
$contractChecks['ttsProviderHasChecklistReportDefault'] = $ttsProviderSource.Contains("[string]`$ReportPath = 'reports/tts-provider.json'") -and $checklistSource.Contains("Read-Report 'tts-provider.json'")
$contractChecks['qemuBaselineHasReportDefault'] = $measureSource.Contains("[string]`$ReportPath") -and $measureSource.Contains("qemu-baseline.json")
$contractChecks['qemuBaselineDefaultsToPublishedRuntime'] = $measureSource.Contains("Join-Path `$repositoryRoot 'reports\qemu-baseline.json'")
$contractChecks['startupDefaultsToPublishedRuntime'] = $startupScriptSource -match '\$runtimeRoot' -and $startupScriptSource -match 'Join-Path \$runtimeRoot .*NeoNewsRuntime\.exe' -and $startupScriptSource -match '\$Unregister'
$contractChecks['operationalScriptsUsePublishedRuntimeRoot'] =
    $startNeoNewsSource -match '\$configPathFull' -and $startNeoNewsSource -match 'Join-Path \$runtimeRoot' -and
    $ensureNeoNewsSource -match '\$configPathFull' -and $ensureNeoNewsSource -match 'Join-Path \$runtimeRoot' -and
    $watchNeoNewsSource -match '\$configPathFull' -and $watchNeoNewsSource -match 'Join-Path \$runtimeRoot' -and
    $kioskScriptSource -match '\$configPathFull' -and $kioskScriptSource -match 'Join-Path \$runtimeRoot'
$contractChecks['legacyEnsureEmulatorIsGuardedForQemu'] =
    $ensureNeoNewsSource -match '\$StartEmulator' -and
    $ensureNeoNewsSource -match '\$config\.android\.backend' -and
    $ensureNeoNewsSource -match 'qemu-android-x86' -and
    $ensureNeoNewsSource -match 'NeoNewsRuntime\.exe --start'
foreach ($check in $contractChecks.GetEnumerator()) {
    if (-not [bool]$check.Value) { $contractErrors += [string]$check.Key }
}
$appIgnored = $false
$trackedProprietary = @()
Push-Location $RepositoryRoot
try {
    $ignoreResults = foreach ($candidate in @(
        'app.apk',
        'NeoNews.apk',
        'packages/neonews/neonews.apk',
        'packages/webview/webview.apk',
        'packages/tts/rhvoice.apk',
        'packages/nativebridge/nativebridge.apk',
        'packages/nativebridge/nativebridge.zip'
    )) {
        git check-ignore --quiet -- $candidate
        $LASTEXITCODE -eq 0
    }
    $appIgnored = $ignoreResults -notcontains $false
    $trackedProprietary = @(git ls-files -- @('app.apk', 'NeoNews.apk', 'packages/neonews/neonews.apk', 'packages/webview/webview.apk', 'packages/tts/rhvoice.apk', 'packages/nativebridge/nativebridge.apk'))
} finally {
    Pop-Location
}

$result = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    scriptCount = $scriptFiles.Count
    scriptParseErrors = @($scriptErrors)
    configValid = $configValid
    configError = $configError
    missingRequiredPaths = $missingPaths
    contractChecks = $contractChecks
    contractErrors = $contractErrors
    proprietaryApkIgnored = $appIgnored
    proprietaryArtifactsTracked = $trackedProprietary
    status = if ($scriptErrors.Count -eq 0 -and $configValid -and $missingPaths.Count -eq 0 -and $contractErrors.Count -eq 0 -and $appIgnored -and $trackedProprietary.Count -eq 0) { 'passed' } else { 'failed' }
}

$json = $result | ConvertTo-Json -Depth 8
if ($ReportPath) {
    $reportDirectory = Split-Path -Parent $ReportPath
    if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
    Set-Content -LiteralPath $ReportPath -Value $json -Encoding utf8
}
$json
