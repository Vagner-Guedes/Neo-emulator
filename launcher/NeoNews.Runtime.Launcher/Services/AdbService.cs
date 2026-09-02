using System.IO.Compression;
using System.Text.RegularExpressions;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class AdbService
{
    private readonly RuntimeContext _context;
    private readonly ProcessRunnerService _runner;
    private readonly LogService _logs;
    private AdbRuntimeState _state = AdbRuntimeState.Disconnected;
    private AdbRuntimeState _lastLoggedState = AdbRuntimeState.Disconnected;
    private string _lastTransportDetail = "ADB ainda não foi executado.";
    private int? _lastTransportExitCode;

    public AdbService(RuntimeContext context, ProcessRunnerService runner, LogService logs)
    {
        _context = context;
        _runner = runner;
        _logs = logs;
    }

    public string Transport => _context.Config.Android.Adb.Transport;

    public string Serial
    {
        get
        {
            if (Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase))
                return $"{_context.Config.Android.Adb.Host}:{_context.Config.Android.Adb.HostPort}";

            if (!string.IsNullOrWhiteSpace(_context.Config.Android.Adb.EmulatorSerial))
                return _context.Config.Android.Adb.EmulatorSerial;

            return $"emulator-{_context.Config.Android.Emulator.ValidationPort}";
        }
    }

    public string AdbPath => _context.ResolveAdbPath();
    public AdbRuntimeState State => _state;
    public string LastTransportDetail => _lastTransportDetail;
    public int? LastTransportExitCode => _lastTransportExitCode;

    public Task<ProcessResult> ExecuteAsync(
        IEnumerable<string> arguments,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default,
        bool logOutput = true)
    {
        var fullArguments = new[] { "-s", Serial }.Concat(arguments);
        return _runner.RunAsync(
            AdbPath,
            fullArguments,
            _context.RootDirectory,
            "adb",
            timeout ?? TimeSpan.FromSeconds(Math.Max(5, _context.Config.Timeouts.AdbSeconds)),
            cancellationToken,
            logOutput);
    }

    public Task<ProcessResult> ExecuteHostAsync(
        IEnumerable<string> arguments,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default,
        bool logOutput = false) =>
        _runner.RunAsync(
            AdbPath,
            arguments,
            _context.RootDirectory,
            "adb",
            timeout ?? TimeSpan.FromSeconds(Math.Max(5, _context.Config.Timeouts.AdbSeconds)),
            cancellationToken,
            logOutput);

    public async Task StartServerAsync(CancellationToken cancellationToken = default)
    {
        var result = await ExecuteHostAsync(["start-server"], TimeSpan.FromSeconds(20), cancellationToken);
        RecordTransportResult("start-server", result);
        if (!result.Succeeded)
        {
            SetState(AdbRuntimeState.Disconnected);
            throw new RuntimeOperationException("Não foi possível iniciar o ADB.", $"ADB: {AdbPath}\n{result.StandardError}\n{result.StandardOutput}");
        }
    }

    public async Task<bool> ConnectAsync(CancellationToken cancellationToken = default)
    {
        if (!Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase)) return true;

        var wasOffline = _state == AdbRuntimeState.Offline;
        SetState(AdbRuntimeState.Connecting);
        if (wasOffline)
            _ = await ReconnectOfflineAsync(cancellationToken);

        var result = await ExecuteHostAsync(["connect", Serial], TimeSpan.FromSeconds(10), cancellationToken);
        RecordTransportResult($"connect {Serial}", result);
        var connected = result.Succeeded &&
                       !result.StandardOutput.Contains("unable", StringComparison.OrdinalIgnoreCase) &&
                       !result.StandardOutput.Contains("failed", StringComparison.OrdinalIgnoreCase) &&
                       !result.StandardError.Contains("unable", StringComparison.OrdinalIgnoreCase);
        if (!connected) SetState(AdbRuntimeState.Disconnected);
        return connected;
    }

    /// <summary>
    /// Recreates transports that the ADB server has retained as offline.
    /// `adb connect` alone is intentionally not enough here: when a stale
    /// endpoint is already registered it can answer "already connected"
    /// without restarting the transport. This method is only called by the
    /// bounded boot/reconnect loop, never in a tight background loop.
    /// </summary>
    public async Task<bool> ReconnectOfflineAsync(CancellationToken cancellationToken = default)
    {
        if (!Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase)) return true;

        var result = await ExecuteHostAsync(["reconnect", "offline"], TimeSpan.FromSeconds(10), cancellationToken);
        RecordTransportResult($"reconnect offline {Serial}", result);
        return result.Succeeded;
    }

    public async Task DisconnectAsync(CancellationToken cancellationToken = default)
    {
        if (Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase))
        {
            var result = await ExecuteHostAsync(["disconnect", Serial], TimeSpan.FromSeconds(10), cancellationToken);
            RecordTransportResult($"disconnect {Serial}", result);
        }
        SetState(AdbRuntimeState.Disconnected);
    }

    public async Task<string> GetStateAsync(CancellationToken cancellationToken = default)
    {
        var result = await ExecuteAsync(["get-state"], TimeSpan.FromSeconds(8), cancellationToken, logOutput: false);
        RecordTransportResult($"get-state {Serial}", result);
        var combined = $"{result.StandardOutput}\n{result.StandardError}".Trim();
        var state = combined.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? string.Empty;
        if (combined.Contains("unauthorized", StringComparison.OrdinalIgnoreCase)) state = "unauthorized";
        else if (combined.Contains("offline", StringComparison.OrdinalIgnoreCase)) state = "offline";
        SetState(state.ToLowerInvariant() switch
        {
            "device" => AdbRuntimeState.Device,
            "offline" => AdbRuntimeState.Offline,
            "unauthorized" => AdbRuntimeState.Unauthorized,
            _ => AdbRuntimeState.Disconnected
        });
        return state;
    }

    public async Task<bool> IsDeviceOnlineAsync(CancellationToken cancellationToken = default) =>
        string.Equals(await GetStateAsync(cancellationToken), "device", StringComparison.OrdinalIgnoreCase);

    public Task<string> ShellAsync(IEnumerable<string> arguments, TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        return ExecuteShellAsync(arguments, timeout, cancellationToken);
    }

    public Task<ProcessResult> ShellResultAsync(
        IEnumerable<string> arguments,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default,
        bool logOutput = false) =>
        ExecuteAsync(new[] { "shell" }.Concat(arguments), timeout, cancellationToken, logOutput);

    private async Task<string> ExecuteShellAsync(IEnumerable<string> arguments, TimeSpan? timeout, CancellationToken cancellationToken)
    {
        var result = await ExecuteAsync(new[] { "shell" }.Concat(arguments), timeout, cancellationToken, logOutput: false);
        return result.StandardOutput.Trim();
    }

    public Task<string> GetPropertyAsync(string property, CancellationToken cancellationToken = default) =>
        ShellAsync(["getprop", property], TimeSpan.FromSeconds(10), cancellationToken);

    public async Task<AndroidGuestValidationResult> ValidateGuestIdentityAsync(
        string expectedRelease,
        int expectedApiLevel,
        CancellationToken cancellationToken = default)
    {
        var release = await GetPropertyAsync("ro.build.version.release", cancellationToken);
        var api = await GetPropertyAsync("ro.build.version.sdk", cancellationToken);
        var bootCompleted = await GetPropertyAsync("sys.boot_completed", cancellationToken);
        var releaseMatches = string.IsNullOrWhiteSpace(expectedRelease) || release.Equals(expectedRelease, StringComparison.OrdinalIgnoreCase);
        var apiMatches = api.Equals(expectedApiLevel.ToString(), StringComparison.OrdinalIgnoreCase);
        var ready = bootCompleted == "1" && releaseMatches && apiMatches;
        var detail = ready
            ? $"Android {release} / API {api} com sys.boot_completed=1."
            : $"Guest incompatível: release={release}; esperado={expectedRelease}; api={api}; esperada={expectedApiLevel}; sys.boot_completed={bootCompleted}.";
        return new AndroidGuestValidationResult(release, api, bootCompleted, ready, detail);
    }

    public Task<string> GetSettingAsync(string scope, string name, CancellationToken cancellationToken = default) =>
        ShellAsync(["settings", "get", scope, name], TimeSpan.FromSeconds(15), cancellationToken);

    public async Task WaitForBootAsync(IProgress<RuntimeProgress>? progress, TimeSpan timeout, CancellationToken cancellationToken)
    {
        await StartServerAsync(cancellationToken);
        var deadline = DateTimeOffset.UtcNow + timeout;
        var nextConnect = DateTimeOffset.MinValue;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase) && DateTimeOffset.UtcNow >= nextConnect)
            {
                _ = await ConnectAsync(cancellationToken);
                nextConnect = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds));
            }

            var state = await GetStateAsync(cancellationToken);
            if (state.Equals("device", StringComparison.OrdinalIgnoreCase))
            {
                var boot = await GetPropertyAsync("sys.boot_completed", cancellationToken);
                if (boot == "1")
                {
                    progress?.Report(new RuntimeProgress("Aguardando Package Manager", "Validando pm list packages e pm path android...", 62));
                    await WaitForPackageManagerAsync(TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.PackageManagerSeconds)), cancellationToken);
                    progress?.Report(new RuntimeProgress("Aguardando Settings Provider", "Validando settings antes do provisionamento...", 66));
                    await WaitForSettingsProviderAsync(TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.SettingsProviderSeconds)), cancellationToken);
                    SetState(AdbRuntimeState.Ready);
                    progress?.Report(new RuntimeProgress("Android pronto", "Android, Package Manager e Settings Provider prontos.", 70));
                    return;
                }

                SetState(AdbRuntimeState.Booting);
                ReportStateProgress(progress, "Aguardando inicialização", "ADB respondeu; verificando Android...", 55);
            }
            else
            {
                ReportStateProgress(progress, "Aguardando ADB", $"Estado ADB: {DescribeState(State)}; tentando reconectar...", null);
            }

            await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds)), cancellationToken);
        }

        throw new RuntimeOperationException(
            "Não foi possível conectar ao Android.",
            $"ADB não confirmou o boot do transporte {Serial} em {timeout.TotalSeconds:0} segundos. Último estado: {State}.");
    }

    public async Task WaitForPackageManagerAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        ProcessResult? lastPackages = null;
        ProcessResult? lastAndroidPath = null;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lastPackages = await ShellResultAsync(["pm", "list", "packages"], TimeSpan.FromSeconds(20), cancellationToken);
            lastAndroidPath = await ShellResultAsync(["pm", "path", "android"], TimeSpan.FromSeconds(20), cancellationToken);
            var packagesReady = lastPackages.Succeeded && lastPackages.StandardOutput.Contains("package:", StringComparison.OrdinalIgnoreCase);
            var androidPathReady = lastAndroidPath.Succeeded && lastAndroidPath.StandardOutput.Contains("package:", StringComparison.OrdinalIgnoreCase);
            if (packagesReady && androidPathReady) return;
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds)), cancellationToken);
        }

        throw new RuntimeOperationException(
            "O Package Manager do Android não ficou pronto.",
            $"pm list packages: exit={lastPackages?.ExitCode}; {lastPackages?.StandardError}; pm path android: exit={lastAndroidPath?.ExitCode}; {lastAndroidPath?.StandardError}");
    }

    public async Task WaitForSettingsProviderAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        ProcessResult? lastGlobal = null;
        ProcessResult? lastSecure = null;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lastGlobal = await ShellResultAsync(["settings", "list", "global"], TimeSpan.FromSeconds(20), cancellationToken);
            lastSecure = await ShellResultAsync(["settings", "list", "secure"], TimeSpan.FromSeconds(20), cancellationToken);
            var globalReady = lastGlobal.Succeeded && !lastGlobal.StandardError.Contains("error", StringComparison.OrdinalIgnoreCase);
            var secureReady = lastSecure.Succeeded && !lastSecure.StandardError.Contains("error", StringComparison.OrdinalIgnoreCase);
            if (globalReady && secureReady) return;
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds)), cancellationToken);
        }

        throw new RuntimeOperationException(
            "O Settings Provider do Android não ficou pronto.",
            $"settings global: exit={lastGlobal?.ExitCode}; {lastGlobal?.StandardError}; settings secure: exit={lastSecure?.ExitCode}; {lastSecure?.StandardError}");
    }

    public async Task<LocaleValidationResult> ReadLocaleAsync(CancellationToken cancellationToken = default)
    {
        var locale = await GetPropertyAsync("persist.sys.locale", cancellationToken);
        var language = await GetPropertyAsync("persist.sys.language", cancellationToken);
        var country = await GetPropertyAsync("persist.sys.country", cancellationToken);
        var systemLocales = await GetSettingAsync("system", "system_locales", cancellationToken);
        var effective = FirstNonEmpty(locale, systemLocales, CombineLocale(language, country));
        return new LocaleValidationResult("pt-BR", effective, IsPtBr(effective), locale, language, country, systemLocales);
    }

    public async Task<LocaleValidationResult> EnsurePtBrLocaleAsync(CancellationToken cancellationToken = default)
    {
        var current = await ReadLocaleAsync(cancellationToken);
        if (current.IsPtBr) return current with { RebootRequired = false };

        var changed = false;
        var localeResult = await ShellResultAsync(["setprop", "persist.sys.locale", "pt-BR"], TimeSpan.FromSeconds(20), cancellationToken);
        if (localeResult.Succeeded) changed = true;
        var languageResult = await ShellResultAsync(["setprop", "persist.sys.language", "pt"], TimeSpan.FromSeconds(20), cancellationToken);
        var countryResult = await ShellResultAsync(["setprop", "persist.sys.country", "BR"], TimeSpan.FromSeconds(20), cancellationToken);
        changed = changed || languageResult.Succeeded || countryResult.Succeeded;
        var settingsResult = await ShellResultAsync(["settings", "put", "system", "system_locales", "pt-BR"], TimeSpan.FromSeconds(20), cancellationToken);
        changed = changed || settingsResult.Succeeded;
        if (!changed)
        {
            throw new RuntimeOperationException(
                "Não foi possível configurar o idioma do Android.",
                $"setprop locale: {localeResult.StandardError}; setprop language: {languageResult.StandardError}; setprop country: {countryResult.StandardError}; settings: {settingsResult.StandardError}");
        }

        var after = await ReadLocaleAsync(cancellationToken);
        return after with { RebootRequired = !after.IsPtBr };
    }

    public async Task RebootGuestAsync(CancellationToken cancellationToken = default)
    {
        var result = await ShellResultAsync(["reboot"], TimeSpan.FromSeconds(20), cancellationToken);
        if (!result.Succeeded && !result.StandardError.Contains("closed", StringComparison.OrdinalIgnoreCase) && !result.StandardError.Contains("offline", StringComparison.OrdinalIgnoreCase))
        {
            throw new RuntimeOperationException("Não foi possível reiniciar o Android.", $"adb shell reboot: exit={result.ExitCode}; {result.StandardError}; {result.StandardOutput}");
        }
        SetState(AdbRuntimeState.Booting);
    }

    public async Task<bool> IsPackageInstalledAsync(string packageName, CancellationToken cancellationToken = default)
    {
        var path = await ShellAsync(["pm", "path", packageName], TimeSpan.FromSeconds(15), cancellationToken);
        return path.StartsWith("package:", StringComparison.Ordinal);
    }

    public Task<bool> WaitForDeviceAsync(TimeSpan timeout, CancellationToken cancellationToken = default) =>
        WaitForStateAsync("device", timeout, cancellationToken);

    private async Task<bool> WaitForStateAsync(string expectedState, TimeSpan timeout, CancellationToken cancellationToken)
    {
        await StartServerAsync(cancellationToken);
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase)) _ = await ConnectAsync(cancellationToken);
            if (string.Equals(await GetStateAsync(cancellationToken), expectedState, StringComparison.OrdinalIgnoreCase)) return true;
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds)), cancellationToken);
        }
        return false;
    }

    public Task<string> GetPackageDumpAsync(string packageName, CancellationToken cancellationToken = default) =>
        ShellAsync(["dumpsys", "package", packageName], TimeSpan.FromSeconds(30), cancellationToken);

    public async Task<string?> GetPackageVersionAsync(string packageName, CancellationToken cancellationToken = default)
    {
        var dump = await GetPackageDumpAsync(packageName, cancellationToken);
        var match = Regex.Match(dump, @"versionName=([^\s]+)");
        return match.Success ? match.Groups[1].Value : null;
    }

    public async Task<string?> GetPrimaryCpuAbiAsync(string packageName, CancellationToken cancellationToken = default)
    {
        var dump = await GetPackageDumpAsync(packageName, cancellationToken);
        var match = Regex.Match(dump, @"primaryCpuAbi=([^\s]+)");
        return match.Success ? match.Groups[1].Value : null;
    }

    public async Task<int?> GetPackageVersionCodeAsync(string packageName, CancellationToken cancellationToken = default)
    {
        var dump = await GetPackageDumpAsync(packageName, cancellationToken);
        var match = Regex.Match(dump, @"versionCode=(\d+)");
        return match.Success && int.TryParse(match.Groups[1].Value, out var versionCode) ? versionCode : null;
    }

    public Task<string> GetActivityDumpAsync(CancellationToken cancellationToken = default) =>
        ShellAsync(["dumpsys", "activity", "activities"], TimeSpan.FromSeconds(20), cancellationToken);

    public async Task<bool> IsActivityRunningAsync(string packageName, string activityName, CancellationToken cancellationToken = default)
    {
        var dump = await GetActivityDumpAsync(cancellationToken);
        var normalizedActivity = activityName.Trim();
        if (normalizedActivity.StartsWith(packageName + ".", StringComparison.Ordinal))
            normalizedActivity = normalizedActivity[(packageName.Length + 1)..];
        if (normalizedActivity.StartsWith(".", StringComparison.Ordinal)) normalizedActivity = normalizedActivity[1..];

        var candidates = new[]
        {
            $"{packageName}/{normalizedActivity}",
            $"{packageName}/.{normalizedActivity}",
            $"{packageName}/{packageName}.{normalizedActivity}"
        };
        var foregroundMarkers = new[] { "mResumedActivity", "topResumedActivity", "ResumedActivity", "mFocusedActivity", "mCurrentFocus" };
        return dump.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries)
            .Any(line => foregroundMarkers.Any(marker => line.Contains(marker, StringComparison.OrdinalIgnoreCase)) &&
                         candidates.Any(candidate => line.Contains(candidate, StringComparison.OrdinalIgnoreCase)));
    }

    public async Task StartActivityAsync(string packageName, string activityName, CancellationToken cancellationToken = default)
    {
        var componentActivity = activityName.StartsWith(".", StringComparison.Ordinal) ||
                                activityName.StartsWith(packageName + ".", StringComparison.Ordinal)
            ? activityName
            : $".{activityName}";
        var component = $"{packageName}/{componentActivity}";
        var result = await ExecuteAsync(["shell", "am", "start", "-W", "-n", component], TimeSpan.FromSeconds(Math.Max(10, _context.Config.Timeouts.NeoNewsStartSeconds)), cancellationToken);
        if (!result.Succeeded)
        {
            throw new RuntimeOperationException(
                "Não foi possível abrir o NeoNews.",
                $"Comando: adb -s {Serial} shell am start -W -n {component}\nExit code: {result.ExitCode}\nstderr: {result.StandardError}");
        }

        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(Math.Max(10, _context.Config.Timeouts.NeoNewsStartSeconds));
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (await IsActivityRunningAsync(packageName, activityName, cancellationToken)) return;
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
        }

        throw new RuntimeOperationException("O NeoNews não confirmou a atividade em execução.", $"Activity esperada: {component}");
    }

    public Task ForceStopAsync(string packageName, CancellationToken cancellationToken = default) => StopPackageAsync(packageName, cancellationToken);

    public async Task StopPackageAsync(string packageName, CancellationToken cancellationToken = default) =>
        _ = await ExecuteAsync(["shell", "am", "force-stop", packageName], TimeSpan.FromSeconds(30), cancellationToken);

    public async Task InstallApkAsync(string apkPath, CancellationToken cancellationToken = default)
    {
        ValidateApkFile(apkPath);
        _logs.Info("launcher", $"Instalação autorizada do APK: {apkPath}");
        var result = await ExecuteAsync(["install", "-r", apkPath], TimeSpan.FromSeconds(Math.Max(30, _context.Config.Timeouts.InstallSeconds)), cancellationToken);
        if (!result.Succeeded || !result.StandardOutput.Contains("Success", StringComparison.OrdinalIgnoreCase))
        {
            throw new RuntimeOperationException(
                "Não foi possível instalar o NeoNews.",
                $"Exit code: {result.ExitCode}\n{result.StandardError}\n{result.StandardOutput}");
        }
    }

    public Task InstallAuthorizedApkAsync(string apkPath, CancellationToken cancellationToken = default) => InstallApkAsync(apkPath, cancellationToken);

    public Task PutSettingAsync(string scope, string name, string value, CancellationToken cancellationToken = default) =>
        ExecuteCheckedAsync(["shell", "settings", "put", scope, name, value], TimeSpan.FromSeconds(20), cancellationToken, $"settings put {scope}/{name}");

    public Task DeleteSettingAsync(string scope, string name, CancellationToken cancellationToken = default) =>
        ExecuteCheckedAsync(["shell", "settings", "delete", scope, name], TimeSpan.FromSeconds(20), cancellationToken, $"settings delete {scope}/{name}");

    public async Task SetDisplayAsync(string size, int density, CancellationToken cancellationToken = default)
    {
        await ExecuteCheckedAsync(["shell", "wm", "size", size], TimeSpan.FromSeconds(20), cancellationToken, "wm size");
        await ExecuteCheckedAsync(["shell", "wm", "density", density.ToString()], TimeSpan.FromSeconds(20), cancellationToken, "wm density");
    }

    public Task ResetDisplaySizeAsync(CancellationToken cancellationToken = default) =>
        ExecuteCheckedAsync(["shell", "wm", "size", "reset"], TimeSpan.FromSeconds(20), cancellationToken, "wm size reset");

    public Task ResetDisplayDensityAsync(CancellationToken cancellationToken = default) =>
        ExecuteCheckedAsync(["shell", "wm", "density", "reset"], TimeSpan.FromSeconds(20), cancellationToken, "wm density reset");

    public Task SetDisplaySizeAsync(string size, CancellationToken cancellationToken = default) =>
        ExecuteCheckedAsync(["shell", "wm", "size", size], TimeSpan.FromSeconds(20), cancellationToken, "wm size restore");

    public Task SetDisplayDensityAsync(string density, CancellationToken cancellationToken = default) =>
        ExecuteCheckedAsync(["shell", "wm", "density", density], TimeSpan.FromSeconds(20), cancellationToken, "wm density restore");

    public Task<string> GetDisplaySizeAsync(CancellationToken cancellationToken = default) => ShellAsync(["wm", "size"], TimeSpan.FromSeconds(20), cancellationToken);
    public Task<string> GetDisplayDensityAsync(CancellationToken cancellationToken = default) => ShellAsync(["wm", "density"], TimeSpan.FromSeconds(20), cancellationToken);
    public Task<string> GetWebViewDumpAsync(CancellationToken cancellationToken = default) => ShellAsync(["dumpsys", "webviewupdate"], TimeSpan.FromSeconds(20), cancellationToken);
    public Task<string> GetTtsDefaultAsync(CancellationToken cancellationToken = default) => ShellAsync(["settings", "get", "secure", "tts_default_synth"], TimeSpan.FromSeconds(15), cancellationToken);
    public Task<string> CheckTtsDataAsync(string language, string country, CancellationToken cancellationToken = default) =>
        ShellAsync(["am", "broadcast", "-a", "android.speech.tts.engine.CHECK_TTS_DATA", "--es", "language", language, "--es", "country", country, "--es", "variant", ""], TimeSpan.FromSeconds(20), cancellationToken);
    public Task<string> GetPackagesAsync(CancellationToken cancellationToken = default) => ShellAsync(["pm", "list", "packages"], TimeSpan.FromSeconds(30), cancellationToken);
    public Task<string> GetMemoryDumpAsync(CancellationToken cancellationToken = default) => ShellAsync(["dumpsys", "meminfo"], TimeSpan.FromSeconds(30), cancellationToken);
    public Task<string> GetGraphicsDumpAsync(CancellationToken cancellationToken = default) => ShellAsync(["dumpsys", "gfxinfo"], TimeSpan.FromSeconds(30), cancellationToken);
    public Task<string> GetLogcatAsync(int lines, CancellationToken cancellationToken = default) => ShellAsync(["logcat", "-d", "-b", "all", "-t", lines.ToString()], TimeSpan.FromMinutes(2), cancellationToken);

    private async Task ExecuteCheckedAsync(IEnumerable<string> arguments, TimeSpan timeout, CancellationToken cancellationToken, string operation)
    {
        var result = await ExecuteAsync(arguments, timeout, cancellationToken);
        if (!result.Succeeded)
        {
            throw new RuntimeOperationException(
                "Não foi possível aplicar a configuração do Android.",
                $"Operação: {operation}; exit code: {result.ExitCode}; stderr: {result.StandardError}; stdout: {result.StandardOutput}");
        }
    }

    private void ValidateApkFile(string apkPath)
    {
        if (!File.Exists(apkPath))
            throw new RuntimeOperationException("NeoNews.apk não encontrado.", $"Caminho esperado: {apkPath}");

        try
        {
            using var archive = ZipFile.OpenRead(apkPath);
            var abis = archive.Entries
                .Select(entry => Regex.Match(entry.FullName, @"^lib/([^/]+)/"))
                .Where(match => match.Success)
                .Select(match => match.Groups[1].Value)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            var preferred = _context.Config.Android.PreferredApkAbi;
            var supported = _context.Config.NeoNews.SupportedApkAbis;
            if (abis.Length == 0 || (supported.Count > 0 && !abis.Intersect(supported, StringComparer.OrdinalIgnoreCase).Any()))
                throw new RuntimeOperationException("O APK selecionado não é compatível com o NeoNews.", $"Nenhuma ABI esperada foi encontrada. ABIs do APK: {string.Join(", ", abis)}; esperadas: {string.Join(", ", supported)}.");
            if (!string.IsNullOrWhiteSpace(preferred) && !abis.Contains(preferred, StringComparer.OrdinalIgnoreCase))
                throw new RuntimeOperationException("O APK não contém a ABI ARM32 homologada.", $"ABI preferencial ausente: {preferred}; ABIs do APK: {string.Join(", ", abis)}.");
        }
        catch (InvalidDataException exception)
        {
            throw new RuntimeOperationException("O arquivo APK é inválido.", $"Não foi possível ler o APK como ZIP: {exception.Message}", exception);
        }
    }

    private void SetState(AdbRuntimeState state)
    {
        _state = state;
        if (state == _lastLoggedState) return;
        _lastLoggedState = state;
        _logs.Info("adb", $"Estado ADB: {DescribeState(state)} ({Serial}).");
    }

    private void RecordTransportResult(string operation, ProcessResult result)
    {
        _lastTransportExitCode = result.ExitCode;
        var output = string.Join(" | ", new[] { result.StandardOutput.Trim(), result.StandardError.Trim() }
            .Where(value => !string.IsNullOrWhiteSpace(value)));
        if (output.Length > 1200) output = output[..1200];
        _lastTransportDetail = string.IsNullOrWhiteSpace(output)
            ? $"{operation}: exit={result.ExitCode}; timeout={result.TimedOut}."
            : $"{operation}: exit={result.ExitCode}; timeout={result.TimedOut}; {output}";
    }

    private static string DescribeState(AdbRuntimeState state) => state switch
    {
        AdbRuntimeState.Device => "device",
        AdbRuntimeState.Offline => "offline",
        AdbRuntimeState.Unauthorized => "unauthorized",
        AdbRuntimeState.Booting => "booting",
        AdbRuntimeState.Ready => "ready",
        AdbRuntimeState.Connecting => "connecting",
        _ => "disconnected"
    };

    private static void ReportStateProgress(IProgress<RuntimeProgress>? progress, string phase, string detail, double? percent) =>
        progress?.Report(new RuntimeProgress(phase, detail, percent));

    private static string FirstNonEmpty(params string[] values) => values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim() ?? string.Empty;

    private static string CombineLocale(string language, string country) =>
        string.IsNullOrWhiteSpace(language) ? string.Empty : string.IsNullOrWhiteSpace(country) ? language : $"{language}-{country}";

    private static bool IsPtBr(string value) =>
        Regex.IsMatch(value ?? string.Empty, @"^(pt[-_]?(BR|rBR)|pt_BR)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}

public sealed record AndroidGuestValidationResult(
    string Release,
    string ApiLevel,
    string BootCompleted,
    bool Ready,
    string Detail);

public sealed record LocaleValidationResult(
    string Requested,
    string Effective,
    bool IsPtBr,
    string PersistedLocale,
    string PersistedLanguage,
    string PersistedCountry,
    string SystemLocales,
    bool RebootRequired = false);
