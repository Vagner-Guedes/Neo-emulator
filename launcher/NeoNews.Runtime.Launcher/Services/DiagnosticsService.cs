using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class DiagnosticsService
{
    private readonly RuntimeContext _context;
    private readonly AdbService _adb;
    private readonly IAndroidRuntimeBackend _backend;
    private readonly NeoNewsService _neoNews;
    private readonly WatchdogService _supervisor;
    private readonly StartupService _startup;
    private readonly LogService _logs;
    private readonly Func<AbiCompatibilityResult?>? _getAbiCompatibility;

    public DiagnosticsService(
        RuntimeContext context,
        AdbService adb,
        IAndroidRuntimeBackend backend,
        NeoNewsService neoNews,
        WatchdogService supervisor,
        StartupService startup,
        LogService logs,
        Func<AbiCompatibilityResult?>? getAbiCompatibility = null)
    {
        _context = context;
        _adb = adb;
        _backend = backend;
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
        var adbOnline = await SafeBoolAsync(() => _adb.IsDeviceOnlineAsync(cancellationToken), cancellationToken);
        var neoNews = adbOnline ? await _neoNews.GetStatusAsync(cancellationToken) : null;
        var webViewVersion = adbOnline ? await GetWebViewVersionAsync(cancellationToken) : null;
        var webViewDump = adbOnline ? await SafeAsync(() => _adb.GetWebViewDumpAsync(cancellationToken), cancellationToken) : string.Empty;
        var packages = adbOnline ? await SafeAsync(() => _adb.GetPackagesAsync(cancellationToken), cancellationToken) : string.Empty;
        var nativeBridge = adbOnline ? await SafeNativeBridgeAsync(cancellationToken) : null;
        var apkAbis = ReadApkAbis();
        var primaryCpuAbi = adbOnline ? await SafeNullableAsync(() => _adb.GetPrimaryCpuAbiAsync(_neoNews.PackageName, cancellationToken), cancellationToken) ?? string.Empty : string.Empty;
        var validatedAbi = _getAbiCompatibility?.Invoke();
        var selectedApkAbi = validatedAbi?.SelectedApkAbi ?? (!string.IsNullOrWhiteSpace(primaryCpuAbi) && apkAbis.Contains(primaryCpuAbi, StringComparer.OrdinalIgnoreCase)
            ? primaryCpuAbi
            : apkAbis.FirstOrDefault(abi => abi.Equals(_context.Config.Android.NativeBridge.PreferredAbi, StringComparison.OrdinalIgnoreCase)));
        var report = new
        {
            timestamp = DateTimeOffset.UtcNow,
            runtime = _context.Config.Runtime,
            release = _context.Config.Release,
            host = new
            {
                computerName = Environment.MachineName,
                os = Environment.OSVersion.VersionString,
                processorCount = Environment.ProcessorCount,
                availableMemoryBytes = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes,
                freeSpaceBytes = drive.AvailableFreeSpace
            },
            tools = new
            {
                adb = _adb.AdbPath,
                transport = _adb.Transport,
                serial = _adb.Serial,
                backend = _backend.Name,
                qemu = _context.ResolveQemuPath(),
                androidDisk = _context.ResolveAndroidDiskPath(),
                whpx = QemuAndroidRuntimeBackend.CheckWhpx(),
                backendProcess = await _backend.IsRunningAsync(cancellationToken)
            },
            android = new
            {
                state = adbOnline ? "Online" : "Offline",
                release = adbOnline ? await SafeAsync(() => _adb.GetPropertyAsync("ro.build.version.release", cancellationToken), cancellationToken) : null,
                apiLevel = adbOnline ? await SafeAsync(() => _adb.GetPropertyAsync("ro.build.version.sdk", cancellationToken), cancellationToken) : null,
                abi = adbOnline ? await SafeAsync(() => _adb.GetPropertyAsync("ro.product.cpu.abi", cancellationToken), cancellationToken) : null,
                abiList = adbOnline ? await SafeAsync(() => _adb.GetPropertyAsync("ro.product.cpu.abilist", cancellationToken), cancellationToken) : null,
                abi2 = adbOnline ? await SafeAsync(() => _adb.GetPropertyAsync("ro.product.cpu.abi2", cancellationToken), cancellationToken) : null,
                nativeBridge = adbOnline ? await SafeAsync(() => _adb.GetPropertyAsync(_context.Config.Android.NativeBridge.Property, cancellationToken), cancellationToken) : null,
                bootCompleted = adbOnline ? await SafeAsync(() => _adb.GetPropertyAsync("sys.boot_completed", cancellationToken), cancellationToken) : null,
                displaySize = adbOnline ? await SafeAsync(() => _adb.ShellAsync(["wm", "size"], cancellationToken: cancellationToken), cancellationToken) : null,
                displayDensity = adbOnline ? await SafeAsync(() => _adb.ShellAsync(["wm", "density"], cancellationToken: cancellationToken), cancellationToken) : null
            },
            neoNews = neoNews,
            webView = new
            {
                expected = _context.Config.WebView.HomologatedVersion,
                installed = webViewVersion,
                provider = _context.Config.WebView.Provider,
                providerActive = webViewDump.Contains(_context.Config.WebView.Provider, StringComparison.OrdinalIgnoreCase),
                status = webViewVersion == _context.Config.WebView.HomologatedVersion && webViewDump.Contains(_context.Config.WebView.Provider, StringComparison.OrdinalIgnoreCase) ? "validated" : "version-mismatch"
            },
            abiCompatibility = new
            {
                guestAbi = nativeBridge?.GuestAbi,
                guestAbiList = nativeBridge?.GuestAbiList,
                nativeBridgeProperty = nativeBridge?.Property,
                nativeBridgeReady = validatedAbi?.NativeBridgeReady ?? nativeBridge?.Ready ?? false,
                apkAbis,
                selectedApkAbi,
                installSucceeded = validatedAbi?.InstallSucceeded ?? (neoNews?.Installed ?? false),
                primaryCpuAbi = validatedAbi?.PrimaryCpuAbi ?? primaryCpuAbi,
                launchSucceeded = validatedAbi?.LaunchSucceeded ?? (neoNews?.Running ?? false),
                // A diagnostic snapshot never claims long-term stability. That
                // field is set only by the full StartSystem validation flow.
                runtimeStable = validatedAbi?.RuntimeStable ?? false
            },
            voice = new
            {
                expectedEngine = _context.Config.Tts.Engine,
                locale = _context.Config.Tts.Locale,
                defaultEngine = adbOnline ? await SafeAsync(() => _adb.GetTtsDefaultAsync(cancellationToken), cancellationToken) : null,
                matchingPackages = packages.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries)
                    .Where(line => line.Contains("rhvoice", StringComparison.OrdinalIgnoreCase) || line.Contains("tts", StringComparison.OrdinalIgnoreCase))
                    .ToArray()
            },
            watchdog = new { active = _supervisor.IsActive },
            startup = new { registered = await _startup.IsRegisteredAsync(cancellationToken) },
            memory = adbOnline ? LimitLines(await SafeAsync(() => _adb.GetMemoryDumpAsync(cancellationToken), cancellationToken), 80) : [],
            graphics = adbOnline ? LimitLines(await SafeAsync(() => _adb.GetGraphicsDumpAsync(cancellationToken), cancellationToken), 80) : [],
            logcat = adbOnline ? LimitLines(await SafeAsync(() => _adb.GetLogcatAsync(120, cancellationToken), cancellationToken), 120) : []
        };

        var path = _context.ResolvePath(_context.Config.Diagnostics.DefaultReport);
        await File.WriteAllTextAsync(path, JsonSerializer.Serialize(report, RuntimeContext.JsonOptions), cancellationToken);
        _logs.Info("launcher", $"Diagnóstico salvo em {path}");
        return path;
    }

    private async Task<string?> GetWebViewVersionAsync(CancellationToken cancellationToken)
    {
        var dump = await SafeAsync(() => _adb.GetPackageDumpAsync(_context.Config.WebView.Provider, cancellationToken), cancellationToken);
        var match = Regex.Match(dump, @"versionName=([^\s]+)");
        return match.Success ? match.Groups[1].Value : null;
    }

    private async Task<NativeBridgeValidationResult?> SafeNativeBridgeAsync(CancellationToken cancellationToken)
    {
        try
        {
            return await new NativeBridgeValidationService(_context, _adb).ValidateGuestAsync(cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception)
        {
            _logs.Warning("launcher", $"Diagnóstico parcial de Native Bridge: {exception.Message}");
            return null;
        }
    }

    private IReadOnlyList<string> ReadApkAbis()
    {
        var path = _context.ResolveApkPath();
        if (!File.Exists(path)) return _context.Config.NeoNews.SupportedApkAbis;
        try { return NativeBridgeValidationService.ReadApkAbis(path); }
        catch (Exception exception)
        {
            _logs.Warning("launcher", $"Diagnóstico parcial de ABIs do APK: {exception.Message}");
            return _context.Config.NeoNews.SupportedApkAbis;
        }
    }

    private async Task<string> SafeAsync(Func<Task<string>> operation, CancellationToken cancellationToken)
    {
        try { return await operation(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception)
        {
            _logs.Warning("launcher", $"Diagnóstico parcial: {exception.Message}");
            return string.Empty;
        }
    }

    private async Task<string?> SafeNullableAsync(Func<Task<string?>> operation, CancellationToken cancellationToken)
    {
        try { return await operation(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception)
        {
            _logs.Warning("launcher", $"Diagnóstico parcial: {exception.Message}");
            return null;
        }
    }

    private async Task<bool> SafeBoolAsync(Func<Task<bool>> operation, CancellationToken cancellationToken)
    {
        try { return await operation(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception)
        {
            _logs.Warning("launcher", $"Diagnóstico parcial: {exception.Message}");
            return false;
        }
    }

    private static string[] LimitLines(string text, int maxLines) =>
        text.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries).Take(maxLines).ToArray();
}
