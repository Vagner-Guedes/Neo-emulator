using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class DiagnosticsService
{
    private readonly RuntimeContext _context;
    private readonly AdbService _adb;
    private readonly EmulatorService _emulator;
    private readonly NeoNewsService _neoNews;
    private readonly RuntimeSupervisorService _supervisor;
    private readonly StartupService _startup;
    private readonly LogService _logs;

    public DiagnosticsService(
        RuntimeContext context,
        AdbService adb,
        EmulatorService emulator,
        NeoNewsService neoNews,
        RuntimeSupervisorService supervisor,
        StartupService startup,
        LogService logs)
    {
        _context = context;
        _adb = adb;
        _emulator = emulator;
        _neoNews = neoNews;
        _supervisor = supervisor;
        _startup = startup;
        _logs = logs;
    }

    public async Task<string> CollectAsync(CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(_context.ReportsDirectory);
        var drive = new DriveInfo(Path.GetPathRoot(_context.RootDirectory) ?? "C:\\");
        var adbOnline = await _adb.IsDeviceOnlineAsync(cancellationToken);
        var neoNews = adbOnline ? await _neoNews.GetStatusAsync(cancellationToken) : null;
        var webViewVersion = adbOnline ? await GetWebViewVersionAsync(cancellationToken) : null;
        var packages = adbOnline ? await SafeAsync(() => _adb.GetPackagesAsync(cancellationToken), cancellationToken) : string.Empty;
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
                emulator = _context.ResolveEmulatorPath(),
                emulatorProcess = await _emulator.IsRunningAsync(cancellationToken)
            },
            android = new
            {
                state = adbOnline ? "Online" : "Offline",
                release = adbOnline ? await SafeAsync(() => _adb.GetPropertyAsync("ro.build.version.release", cancellationToken), cancellationToken) : null,
                apiLevel = adbOnline ? await SafeAsync(() => _adb.GetPropertyAsync("ro.build.version.sdk", cancellationToken), cancellationToken) : null,
                abi = adbOnline ? await SafeAsync(() => _adb.GetPropertyAsync("ro.product.cpu.abi", cancellationToken), cancellationToken) : null,
                bootCompleted = adbOnline ? await SafeAsync(() => _adb.GetPropertyAsync("sys.boot_completed", cancellationToken), cancellationToken) : null,
                displaySize = adbOnline ? await SafeAsync(() => _adb.ShellAsync(["wm", "size"], cancellationToken: cancellationToken), cancellationToken) : null,
                displayDensity = adbOnline ? await SafeAsync(() => _adb.ShellAsync(["wm", "density"], cancellationToken: cancellationToken), cancellationToken) : null
            },
            neoNews = neoNews,
            webView = new
            {
                expected = _context.Config.WebView.HomologatedVersion,
                installed = webViewVersion,
                status = webViewVersion == _context.Config.WebView.HomologatedVersion ? "validated" : "version-mismatch"
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

    private static string[] LimitLines(string text, int maxLines) =>
        text.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries).Take(maxLines).ToArray();
}
