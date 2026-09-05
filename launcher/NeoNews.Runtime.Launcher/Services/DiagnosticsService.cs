using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class DiagnosticsService
{
    private readonly RuntimeContext _context;
    private readonly AdbService _adb;
    private readonly IAndroidRuntimeBackend _backend;
    private readonly ProcessRunnerService _runner;
    private readonly NeoNewsService _neoNews;
    private readonly WatchdogService _supervisor;
    private readonly StartupService _startup;
    private readonly LogService _logs;
    private readonly Func<AbiCompatibilityResult?>? _getAbiCompatibility;

    public DiagnosticsService(
        RuntimeContext context,
        AdbService adb,
        IAndroidRuntimeBackend backend,
        ProcessRunnerService runner,
        NeoNewsService neoNews,
        WatchdogService supervisor,
        StartupService startup,
        LogService logs,
        Func<AbiCompatibilityResult?>? getAbiCompatibility = null)
    {
        _context = context;
        _adb = adb;
        _backend = backend;
        _runner = runner;
        _neoNews = neoNews;
        _supervisor = supervisor;
        _startup = startup;
        _logs = logs;
        _getAbiCompatibility = getAbiCompatibility;
    }

    public async Task<string> CollectAsync(CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(_context.ReportsDirectory);
        var drive = new DriveInfo(Path.GetPathRoot(_context.RootDirectory) ?? "C:\\");
        var whpx = QemuAndroidRuntimeBackend.CheckWhpx();
        var backendRunning = await SafeBoolAsync(() => _backend.IsRunningAsync(cancellationToken), cancellationToken);
        var adbOnline = await SafeBoolAsync(() => _adb.IsDeviceOnlineAsync(cancellationToken), cancellationToken);
        var qemuVersion = await GetQemuVersionAsync(cancellationToken);
        var integrity = await GetRequiredFileIntegrityAsync(cancellationToken);
        var provisioningState = await SafeProvisioningStateAsync(cancellationToken);
        var neoNews = adbOnline ? await SafeNeoNewsAsync(cancellationToken) : null;
        var neoNewsVersionCode = adbOnline ? await SafeNullableIntAsync(() => _adb.GetPackageVersionCodeAsync(_neoNews.PackageName, cancellationToken), cancellationToken) : null;
        var primaryCpuAbi = adbOnline ? await SafeNullableAsync(() => _adb.GetPrimaryCpuAbiAsync(_neoNews.PackageName, cancellationToken), cancellationToken) ?? string.Empty : string.Empty;
        object? neoNewsReport = neoNews is null
            ? null
            : new
            {
                packageName = _neoNews.PackageName,
                activity = _neoNews.ActivityName,
                installed = neoNews.Installed,
                running = neoNews.Running,
                version = neoNews.Version,
                versionCode = neoNewsVersionCode,
                primaryCpuAbi,
                expectedVersion = _context.Config.NeoNews.VersionName,
                expectedVersionCode = _context.Config.NeoNews.VersionCode,
                detail = neoNews.Detail
            };
        var webViewDump = adbOnline ? await SafeAsync(() => _adb.GetWebViewDumpAsync(cancellationToken), cancellationToken) : string.Empty;
        var webViewVersion = adbOnline ? await GetWebViewVersionAsync(cancellationToken) : null;
        var packages = adbOnline ? await SafeAsync(() => _adb.GetPackagesAsync(cancellationToken), cancellationToken) : string.Empty;
        var ttsLocaleCheck = adbOnline ? await SafeAsync(() => _adb.CheckTtsDataAsync("por", "BRA", cancellationToken), cancellationToken) : string.Empty;
        var ttsVoiceData = adbOnline ? await SafeTtsVoiceDataAsync(cancellationToken) : (false, "ADB offline");
        var nativeBridge = adbOnline ? await SafeNativeBridgeAsync(cancellationToken) : null;
        var apkAbis = ReadApkAbis();
        var apkMetadata = ReadApkMetadata();
        var apkSignature = ReadApkSignature();
        var webViewPrimaryCpuAbi = adbOnline ? await SafeNullableAsync(() => _adb.GetPrimaryCpuAbiAsync(_context.Config.WebView.Provider, cancellationToken), cancellationToken) : null;
        var validatedAbi = _getAbiCompatibility?.Invoke();
        // Never infer the selected APK ABI from configuration. It is evidence
        // only when package-manager output (or the full Native Bridge check)
        // observed a primaryCpuAbi in the APK's actual ABI set.
        var preferredApkAbi = string.IsNullOrWhiteSpace(_context.Config.Android.NativeBridge.PreferredAbi)
            ? _context.Config.Android.PreferredApkAbi
            : _context.Config.Android.NativeBridge.PreferredAbi;
        var selectedApkAbi = validatedAbi?.SelectedApkAbi ?? (!string.IsNullOrWhiteSpace(primaryCpuAbi) && apkAbis.Contains(primaryCpuAbi, StringComparer.OrdinalIgnoreCase) &&
            (string.IsNullOrWhiteSpace(preferredApkAbi) || primaryCpuAbi.Equals(preferredApkAbi, StringComparison.OrdinalIgnoreCase))
            ? primaryCpuAbi
            : null);
        var guest = adbOnline ? await GetGuestDiagnosticsAsync(cancellationToken) : GuestDiagnostics.Empty;
        var locale = adbOnline ? await SafeLocaleAsync(cancellationToken) : new LocaleValidationResult("pt-BR", string.Empty, false, string.Empty, string.Empty, string.Empty, string.Empty);
        var memory = adbOnline ? LimitLines(await SafeAsync(() => _adb.GetMemoryDumpAsync(cancellationToken), cancellationToken), 80) : [];
        var graphics = adbOnline ? LimitLines(await SafeAsync(() => _adb.GetGraphicsDumpAsync(cancellationToken), cancellationToken), 80) : [];
        var rawLogcat = adbOnline ? await SafeAsync(() => _adb.GetLogcatAsync(240, cancellationToken), cancellationToken) : string.Empty;
        var relevantLogcat = FilterRelevantLogcat(rawLogcat);
        var setupDeviceProvisioned = adbOnline ? await SafeAsync(() => _adb.GetSettingAsync("global", "device_provisioned", cancellationToken), cancellationToken) : string.Empty;
        var setupUserComplete = adbOnline ? await SafeAsync(() => _adb.GetSettingAsync("secure", "user_setup_complete", cancellationToken), cancellationToken) : string.Empty;
        var activityDump = adbOnline ? await SafeAsync(() => _adb.ShellAsync(["dumpsys", "activity", "activities"], TimeSpan.FromSeconds(20), cancellationToken), cancellationToken) : string.Empty;
        var windowDump = adbOnline ? await SafeAsync(() => _adb.ShellAsync(["dumpsys", "window", "windows"], TimeSpan.FromSeconds(20), cancellationToken), cancellationToken) : string.Empty;
        var setupFlagsReady = setupDeviceProvisioned.Trim() == "1" && setupUserComplete.Trim() == "1";
        var setupWizardActive = Regex.IsMatch(windowDump, @"(?im)^\s*Window #\d+.*com\.google\.android\.setupwizard/|mCurrentFocus=.*com\.google\.android\.setupwizard/", RegexOptions.CultureInvariant);
        var crashDialogVisible = Regex.IsMatch(windowDump, @"(?i)Application Error|parou|n\u00e3o est\u00e1 respondendo|fechar aplicativo|abrir app novamente", RegexOptions.CultureInvariant);
        var startupRegistered = await SafeBoolAsync(() => _startup.IsRegisteredAsync(cancellationToken), cancellationToken);
        var startupValid = startupRegistered && await SafeBoolAsync(() => _startup.ValidateAsync(Environment.ProcessPath ?? string.Empty, cancellationToken), cancellationToken);

        var report = new
        {
            timestamp = DateTimeOffset.UtcNow,
            runtime = _context.Config.Runtime,
            release = _context.Config.Release,
            host = new
            {
                computerName = Environment.MachineName,
                os = Environment.OSVersion.VersionString,
                architecture = RuntimeInformation.OSArchitecture.ToString(),
                processArchitecture = RuntimeInformation.ProcessArchitecture.ToString(),
                is64BitProcess = Environment.Is64BitProcess,
                processor = Environment.GetEnvironmentVariable("PROCESSOR_IDENTIFIER") ?? string.Empty,
                processorCount = Environment.ProcessorCount,
                availableMemoryBytes = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes,
                freeSpaceBytes = drive.AvailableFreeSpace,
                virtualization = new { whpx.Available, whpx.Details }
            },
            tools = new
            {
                adb = _adb.AdbPath,
                transport = _adb.Transport,
                serial = _adb.Serial,
                adbServer = _adb.ServerEndpoint,
                backend = _backend.Name,
                backendProcessId = _backend.ProcessId,
                backendProcess = backendRunning,
                backendWindowHandle = _backend.WindowHandle.ToInt64(),
                qemu = _context.ResolveQemuPath(),
                qemuVersion,
                qemuNetwork = new
                {
                    id = _context.Config.Android.Qemu.NetworkId,
                    cidr = _context.Config.Android.Qemu.NetworkCidr,
                    guestAddress = _context.Config.Android.Qemu.GuestAddress,
                    nicModel = _context.Config.Android.Qemu.NicModel,
                    hostAddress = _context.Config.Android.Adb.Host,
                    hostPort = _context.Config.Android.Adb.HostPort,
                    guestPort = _context.Config.Android.Adb.GuestPort,
                    qmpAddress = "127.0.0.1",
                    qmpPort = _context.Config.Android.Qemu.QmpPort
                },
                androidDisk = _context.ResolveAndroidDiskPath(),
                runtimeDirectory = _context.RootDirectory,
                hostProcessState = _context.HostProcessStatePath,
                adbServerState = _context.AdbServerStatePath,
                hostIsolation = _context.Config.HostIsolation,
                requiredFiles = integrity,
                whpx
            },
            provisioning = provisioningState is null
                ? null
                : new
                {
                    schema = provisioningState.Schema,
                    stage = provisioningState.Stage,
                    completed = provisioningState.Completed,
                    packageManagerReady = provisioningState.PackageManagerReady,
                    settingsProviderReady = provisioningState.SettingsProviderReady,
                    localeValidated = provisioningState.LocaleValidated,
                    rebootPerformed = provisioningState.RebootPerformed,
                    neoNewsInstalled = provisioningState.NeoNewsInstalled,
                    neoNewsRunning = provisioningState.NeoNewsRunning,
                    kioskActive = provisioningState.KioskActive,
                    watchdogActive = provisioningState.WatchdogActive,
                    lastAttempt = provisioningState.LastAttempt,
                    lastError = provisioningState.LastError,
                    attempt = provisioningState.Attempt,
                    lastSuccessfulStage = provisioningState.LastSuccessfulStage,
                    bootStartedAt = provisioningState.BootStartedAt,
                    adbLastOnline = provisioningState.AdbLastOnline,
                    rebootRequired = provisioningState.RebootRequired,
                    resumeAllowed = provisioningState.ResumeAllowed,
                    androidImageVersion = provisioningState.AndroidImageVersion,
                    nativeBridgeStatus = provisioningState.NativeBridgeStatus,
                    guestConfigurationStatus = provisioningState.GuestConfigurationStatus,
                    androidSetupStatus = provisioningState.AndroidSetupStatus,
                    guestNetworkStatus = provisioningState.GuestNetworkStatus,
                    neoNewsSuperuserStatus = provisioningState.NeoNewsSuperuserStatus,
                    guestUiStatus = provisioningState.GuestUiStatus,
                    guestInitScriptSha256 = provisioningState.GuestInitScriptSha256,
                    webViewVersion = provisioningState.WebViewVersion,
                    ttsStatus = provisioningState.TtsStatus,
                    neoNewsVersion = provisioningState.NeoNewsVersion,
                    lastValidation = provisioningState.LastValidation,
                    imageHash = provisioningState.ImageHash,
                    baselineSha256 = provisioningState.BaselineSha256,
                    diskFingerprint = provisioningState.DiskFingerprint,
                    diskMutationStatus = provisioningState.DiskMutationStatus,
                    activeDiskMetadata = provisioningState.ActiveDiskMetadata,
                    provenance = provisioningState.Provenance?.Keys.ToArray() ?? []
                },
            android = new
            {
                state = guest.BootCompleted == "1" ? "Online" : backendRunning ? "Booting" : "Offline",
                adb = new
                {
                    online = adbOnline,
                    state = _adb.State.ToString(),
                    serial = _adb.Serial,
                    lastExitCode = _adb.LastTransportExitCode,
                    lastTransportDetail = _adb.LastTransportDetail,
                    lastDeviceSeenAt = _adb.LastDeviceSeenAt
                },
                release = guest.Release,
                apiLevel = guest.ApiLevel,
                expectedRelease = _context.Config.Android.Release,
                expectedApiLevel = _context.Config.Android.ApiLevel,
                identityMatches = guest.BootCompleted == "1" &&
                                   guest.Release.Equals(_context.Config.Android.Release, StringComparison.OrdinalIgnoreCase) &&
                                   guest.ApiLevel.Equals(_context.Config.Android.ApiLevel.ToString(), StringComparison.OrdinalIgnoreCase),
                abi = guest.Abi,
                abiList = guest.AbiList,
                abi2 = guest.Abi2,
                nativeBridge = guest.NativeBridge,
                bootCompleted = guest.BootCompleted,
                locale = new
                {
                    requested = locale.Requested,
                    effective = locale.Effective,
                    validated = locale.IsPtBr,
                    persistedLocale = locale.PersistedLocale,
                    persistedLanguage = locale.PersistedLanguage,
                    persistedCountry = locale.PersistedCountry,
                    systemLocales = locale.SystemLocales,
                    rebootRequired = locale.RebootRequired
                },
                ip = guest.Ip,
                dns = guest.Dns,
                route = guest.Route,
                internet = guest.Route.Contains("default", StringComparison.OrdinalIgnoreCase) ? "Online" : "Offline",
                storage = guest.Storage,
                displaySize = guest.DisplaySize,
                displayDensity = guest.DisplayDensity,
                kiosk = new
                {
                    policyControl = guest.PolicyControl,
                    screenOffTimeout = guest.ScreenOffTimeout,
                    stayAwake = guest.StayAwake,
                    screensaverEnabled = guest.ScreensaverEnabled,
                    rotation = guest.UserRotation
                }
            },
            neoNews = neoNewsReport,
            apk = new
            {
                path = _context.ResolveApkPath(),
                packageName = apkMetadata?.PackageName,
                versionName = apkMetadata?.VersionName,
                versionCode = apkMetadata?.VersionCode,
                abis = apkAbis,
                signature = apkSignature
            },
            abiCompatibility = new
            {
                guestAbi = validatedAbi?.GuestAbi ?? nativeBridge?.GuestAbi,
                guestAbiList = validatedAbi?.GuestAbiList ?? nativeBridge?.GuestAbiList,
                nativeBridgeProperty = validatedAbi?.NativeBridgeProperty ?? nativeBridge?.Property,
                nativeBridgeState = validatedAbi?.NativeBridgeState.ToString() ?? nativeBridge?.State.ToString(),
                persistNativeBridge = nativeBridge?.PersistNativeBridge,
                nativeBridgeFiles = nativeBridge?.Files,
                nativeBridgeReady = validatedAbi?.NativeBridgeReady ?? nativeBridge?.Ready ?? false,
                apkAbis,
                signature = apkSignature,
                selectedApkAbi,
                // Package presence is not proof that this diagnostic run
                // performed or validated adb install -r.
                installSucceeded = validatedAbi?.InstallSucceeded ?? false,
                primaryCpuAbi = validatedAbi?.PrimaryCpuAbi ?? primaryCpuAbi,
                launchSucceeded = validatedAbi?.LaunchSucceeded ?? false,
                runtimeStable = validatedAbi?.RuntimeStable ?? false
            },
            webView = new
            {
                expected = _context.Config.WebView.HomologatedVersion,
                installed = webViewVersion,
                provider = _context.Config.WebView.Provider,
                primaryCpuAbi = webViewPrimaryCpuAbi,
                providerActive = AndroidRuntimeParsing.IsActiveWebViewProvider(webViewDump, _context.Config.WebView.Provider),
                nativeGuestAbi = AndroidRuntimeParsing.IsX86Abi(webViewPrimaryCpuAbi),
                status = webViewVersion == _context.Config.WebView.HomologatedVersion &&
                         AndroidRuntimeParsing.IsActiveWebViewProvider(webViewDump, _context.Config.WebView.Provider) &&
                         (!_context.Config.WebView.RequireNativeGuestAbi || AndroidRuntimeParsing.IsX86Abi(webViewPrimaryCpuAbi))
                    ? "validated"
                    : "version-mismatch"
            },
            voice = new
            {
                expectedEngine = _context.Config.Tts.Engine,
                locale = _context.Config.Tts.Locale,
                defaultEngine = adbOnline ? await SafeAsync(() => _adb.GetTtsDefaultAsync(cancellationToken), cancellationToken) : null,
                localeCheck = ttsLocaleCheck,
                voiceDataReady = ttsVoiceData.Item1,
                voiceDataDetail = ttsVoiceData.Item2,
                localeReady = ttsLocaleCheck.Contains("result=1", StringComparison.OrdinalIgnoreCase) || ttsLocaleCheck.Contains("CHECK_TTS_DATA_PASS", StringComparison.OrdinalIgnoreCase) || ttsLocaleCheck.Contains("CHECK_VOICE_DATA_PASS", StringComparison.OrdinalIgnoreCase) || (ttsVoiceData.Item1 && locale.IsPtBr),
                matchingPackages = packages.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries)
                    .Where(line => line.Contains("rhvoice", StringComparison.OrdinalIgnoreCase) || line.Contains("tts", StringComparison.OrdinalIgnoreCase))
                    .ToArray()
            },
            androidSetup = new
            {
                gate = "ANDROID_SETUP_COMPLETE_PASS",
                deviceProvisioned = setupDeviceProvisioned,
                userSetupComplete = setupUserComplete,
                flagsReady = setupFlagsReady,
                setupWizardActive,
                crashDialogVisible,
                setupWizardGate = !setupWizardActive ? "SETUP_WIZARD_SUPPRESSED_PASS" : "SETUP_WIZARD_VISIBLE_FAIL",
                crashDialogGate = !crashDialogVisible ? "NO_ANDROID_CRASH_DIALOG_PASS" : "NO_ANDROID_CRASH_DIALOG_FAIL",
                activityObserved = activityDump.Contains(_neoNews.ActivityName, StringComparison.OrdinalIgnoreCase)
            },
            watchdog = new
            {
                active = _supervisor.IsActive,
                lastHeartbeat = _supervisor.LastHeartbeat,
                nativeBridgeStructuralError = _supervisor.HasNativeBridgeStructuralError,
                recoverySuppressed = _supervisor.RecoverySuppressed,
                intent = _supervisor.Intent.Intent.ToString(),
                intentReason = _supervisor.Intent.Reason,
                intentUpdatedAtUtc = _supervisor.Intent.UpdatedAtUtc
            },
            startup = new { registered = startupRegistered, valid = startupValid, executable = Environment.ProcessPath },
            memory,
            graphics,
            logcat = relevantLogcat
        };

        var path = _context.ResolvePath(_context.Config.Diagnostics.DefaultReport);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await File.WriteAllTextAsync(path, JsonSerializer.Serialize(report, RuntimeContext.JsonOptions), cancellationToken);
        _logs.Info("launcher", $"Diagnóstico salvo em {path}");
        return path;
    }

    private async Task<GuestDiagnostics> GetGuestDiagnosticsAsync(CancellationToken cancellationToken)
    {
        return new GuestDiagnostics(
            await SafeAsync(() => _adb.GetPropertyAsync("ro.build.version.release", cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetPropertyAsync("ro.build.version.sdk", cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetPropertyAsync("ro.product.cpu.abi", cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetPropertyAsync("ro.product.cpu.abilist", cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetPropertyAsync("ro.product.cpu.abi2", cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetPropertyAsync(_context.Config.Android.NativeBridge.Property, cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetPropertyAsync("sys.boot_completed", cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.ShellAsync(["ip", "addr", "show", "eth0"], cancellationToken: cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.ShellAsync(["ip", "route"], cancellationToken: cancellationToken), cancellationToken),
            string.Join(", ", new[]
            {
                await SafeAsync(() => _adb.GetPropertyAsync("net.dns1", cancellationToken), cancellationToken),
                await SafeAsync(() => _adb.GetPropertyAsync("net.dns2", cancellationToken), cancellationToken)
            }.Where(value => !string.IsNullOrWhiteSpace(value))),
            await SafeAsync(() => _adb.ShellAsync(["df", "/data"], cancellationToken: cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetDisplaySizeAsync(cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetDisplayDensityAsync(cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetSettingAsync("global", "policy_control", cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetSettingAsync("system", "screen_off_timeout", cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetSettingAsync("global", "stay_on_while_plugged_in", cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetSettingAsync("secure", "screensaver_enabled", cancellationToken), cancellationToken),
            await SafeAsync(() => _adb.GetSettingAsync("system", "user_rotation", cancellationToken), cancellationToken));
    }

    private async Task<(bool Ready, string Detail)> SafeTtsVoiceDataAsync(CancellationToken cancellationToken)
    {
        try
        {
            var providerPackage = string.IsNullOrWhiteSpace(_context.Config.Tts.ProviderPackage)
                ? "com.github.olga_yakovleva.rhvoice.android"
                : _context.Config.Tts.ProviderPackage;
            var dataRoot = $"/data/user/0/{providerPackage}/app_data";
            var result = await _adb.ShellAsync(["find", dataRoot, "-maxdepth", "2", "-type", "d"], TimeSpan.FromSeconds(20), cancellationToken);
            var languagePackage = _context.Config.Tts.LanguagePackage;
            var voicePackage = _context.Config.Tts.VoicePackage;
            var languageReady = !string.IsNullOrWhiteSpace(languagePackage) && result.Contains(languagePackage, StringComparison.OrdinalIgnoreCase);
            var voiceReady = !string.IsNullOrWhiteSpace(voicePackage) && result.Contains(voicePackage, StringComparison.OrdinalIgnoreCase);
            return (languageReady && voiceReady, $"root={dataRoot}; language={languagePackage}; languageReady={languageReady}; voice={voicePackage}; voiceReady={voiceReady}; listing={result}");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception)
        {
            _logs.Warning("launcher", $"Dados de voz RHVoice não puderam ser consultados: {exception.Message}");
            return (false, exception.Message);
        }
    }

    private async Task<string> GetQemuVersionAsync(CancellationToken cancellationToken)
    {
        var path = _context.ResolveQemuPath();
        if (!File.Exists(path)) return "not-found";
        try
        {
            var result = await _runner.RunAsync(path, ["--version"], _context.RootDirectory, "diagnostics", TimeSpan.FromSeconds(15), cancellationToken, logOutput: false);
            return string.IsNullOrWhiteSpace(result.StandardOutput) ? result.StandardError.Trim() : result.StandardOutput.Trim();
        }
        catch (Exception exception) { return $"unavailable: {exception.Message}"; }
    }

    private async Task<object> GetRequiredFileIntegrityAsync(CancellationToken cancellationToken)
    {
        var paths = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["qemu"] = _context.ResolveQemuPath(),
            ["adb"] = _context.ResolveAdbPath(),
            ["androidDisk"] = _context.ResolveAndroidDiskPath(),
            ["androidImage"] = _context.ResolveAndroidImagePath(),
            ["neoNewsApk"] = _context.ResolveApkPath(),
            ["webViewPackage"] = _context.ResolveProvisioningPackagePath(_context.Config.Android.Provisioning.WebViewPackagePath),
            ["ttsPackage"] = _context.ResolveProvisioningPackagePath(_context.Config.Android.Provisioning.TtsPackagePath),
            ["nativeBridgePackage"] = _context.ResolveProvisioningPackagePath(_context.Config.Android.Provisioning.NativeBridgePackagePath)
        };
        var result = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in paths)
        {
            result[pair.Key] = await GetFileIntegrityAsync(pair.Value, cancellationToken);
        }
        return result;
    }

    private static async Task<object> GetFileIntegrityAsync(string path, CancellationToken cancellationToken)
    {
        if (!File.Exists(path))
            return new { path, exists = false, length = 0L, lastWriteUtc = (DateTime?)null, sha256 = (string?)null, locked = false, error = (string?)null };
        var info = new FileInfo(path);
        try
        {
            await using var stream = File.OpenRead(path);
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellationToken));
            return new { path, exists = true, length = info.Length, lastWriteUtc = info.LastWriteTimeUtc, sha256 = hash, locked = false, error = (string?)null };
        }
        catch (IOException exception)
        {
            // QEMU intentionally keeps the live qcow2 open exclusively. A
            // runtime diagnostic must still be produced; the offline
            // integrity check remains responsible for the SHA-256.
            return new { path, exists = true, length = info.Length, lastWriteUtc = info.LastWriteTimeUtc, sha256 = (string?)null, locked = true, error = exception.Message };
        }
    }

    private async Task<string?> GetWebViewVersionAsync(CancellationToken cancellationToken)
    {
        var dump = await SafeAsync(() => _adb.GetPackageDumpAsync(_context.Config.WebView.Provider, cancellationToken), cancellationToken);
        return AndroidRuntimeParsing.ReadVersionName(dump);
    }

    private async Task<NativeBridgeValidationResult?> SafeNativeBridgeAsync(CancellationToken cancellationToken)
    {
        try { return await new NativeBridgeValidationService(_context, _adb).ValidateGuestAsync(cancellationToken); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) { _logs.Warning("launcher", $"Diagnóstico parcial de Native Bridge: {exception.Message}"); return null; }
    }

    private async Task<LocaleValidationResult> SafeLocaleAsync(CancellationToken cancellationToken)
    {
        try { return await _adb.ReadLocaleAsync(cancellationToken); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception)
        {
            _logs.Warning("launcher", $"Diagnóstico parcial do locale: {exception.Message}");
            return new LocaleValidationResult("pt-BR", string.Empty, false, string.Empty, string.Empty, string.Empty, string.Empty);
        }
    }

    private async Task<ProvisioningState?> SafeProvisioningStateAsync(CancellationToken cancellationToken)
    {
        try { return await new AndroidProvisioningService(_context, _runner, _logs).LoadAsync(cancellationToken); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) { _logs.Warning("launcher", $"Diagnóstico parcial do provisionamento: {exception.Message}"); return null; }
    }

    private async Task<NeoNewsStatus?> SafeNeoNewsAsync(CancellationToken cancellationToken)
    {
        try { return await _neoNews.GetStatusAsync(cancellationToken); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) { _logs.Warning("launcher", $"Diagnóstico parcial do NeoNews: {exception.Message}"); return null; }
    }

    private IReadOnlyList<string> ReadApkAbis()
    {
        var path = _context.ResolveApkPath();
        if (!File.Exists(path)) return [];
        try { return NativeBridgeValidationService.ReadApkAbis(path); }
        catch (Exception exception) { _logs.Warning("launcher", $"Diagnóstico parcial de ABIs do APK: {exception.Message}"); return []; }
    }

    private ApkManifestMetadata? ReadApkMetadata()
    {
        var path = _context.ResolveApkPath();
        if (!File.Exists(path)) return null;
        try { return ApkManifestService.Read(path); }
        catch (Exception exception) { _logs.Warning("launcher", $"Diagnóstico parcial da identidade do APK: {exception.Message}"); return null; }
    }

    private ApkSignatureValidationResult? ReadApkSignature()
    {
        var path = _context.ResolveApkPath();
        if (!File.Exists(path) || string.IsNullOrWhiteSpace(_context.Config.NeoNews.SigningCertificateSha256)) return null;
        try { return ApkSignatureService.Validate(path, _context.Config.NeoNews.SigningCertificateSha256); }
        catch (Exception exception) { _logs.Warning("launcher", $"Diagnóstico parcial da assinatura do APK: {exception.Message}"); return null; }
    }

    private static string[] FilterRelevantLogcat(string text) => text
        .Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries)
        .Where(line => line.Contains("com.in9midia.neonews.player", StringComparison.OrdinalIgnoreCase) ||
                       Regex.IsMatch(line, "AndroidRuntime|linker|native bridge|SIGSEGV|FATAL EXCEPTION|am_crash|Application Error|SetupWizard|setupwizard|provision|dex2oat|chromium|WebView", RegexOptions.IgnoreCase))
        .Take(160)
        .ToArray();

    private static string[] LimitLines(string text, int maxLines) => text
        .Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries)
        .Take(maxLines)
        .ToArray();

    private async Task<string> SafeAsync(Func<Task<string>> operation, CancellationToken cancellationToken)
    {
        try { return await operation(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) { _logs.Warning("launcher", $"Diagnóstico parcial: {exception.Message}"); return string.Empty; }
    }

    private async Task<string?> SafeNullableAsync(Func<Task<string?>> operation, CancellationToken cancellationToken)
    {
        try { return await operation(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) { _logs.Warning("launcher", $"Diagnóstico parcial: {exception.Message}"); return null; }
    }

    private async Task<int?> SafeNullableIntAsync(Func<Task<int?>> operation, CancellationToken cancellationToken)
    {
        try { return await operation(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) { _logs.Warning("launcher", $"Diagnóstico parcial: {exception.Message}"); return null; }
    }

    private async Task<bool> SafeBoolAsync(Func<Task<bool>> operation, CancellationToken cancellationToken)
    {
        try { return await operation(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) { _logs.Warning("launcher", $"Diagnóstico parcial: {exception.Message}"); return false; }
    }

    private sealed record GuestDiagnostics(
        string Release,
        string ApiLevel,
        string Abi,
        string AbiList,
        string Abi2,
        string NativeBridge,
        string BootCompleted,
        string Ip,
        string Route,
        string Dns,
        string Storage,
        string DisplaySize,
        string DisplayDensity,
        string PolicyControl,
        string ScreenOffTimeout,
        string StayAwake,
        string ScreensaverEnabled,
        string UserRotation)
    {
        public static GuestDiagnostics Empty { get; } = new("", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "");
    }
}
