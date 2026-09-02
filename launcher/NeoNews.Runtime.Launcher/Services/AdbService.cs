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
        if (!result.Succeeded)
        {
            SetState(AdbRuntimeState.Disconnected);
            throw new RuntimeOperationException("Não foi possível iniciar o ADB.", $"ADB: {AdbPath}\n{result.StandardError}\n{result.StandardOutput}");
        }
    }

    public async Task<bool> ConnectAsync(CancellationToken cancellationToken = default)
    {
        if (!Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase)) return true;

        SetState(AdbRuntimeState.Connecting);
        var result = await ExecuteHostAsync(["connect", Serial], TimeSpan.FromSeconds(10), cancellationToken);
        var connected = result.Succeeded &&
                       !result.StandardOutput.Contains("unable", StringComparison.OrdinalIgnoreCase) &&
                       !result.StandardOutput.Contains("failed", StringComparison.OrdinalIgnoreCase) &&
                       !result.StandardError.Contains("unable", StringComparison.OrdinalIgnoreCase);
        if (!connected) SetState(AdbRuntimeState.Disconnected);
        return connected;
    }

    public async Task DisconnectAsync(CancellationToken cancellationToken = default)
    {
        if (Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase))
            _ = await ExecuteHostAsync(["disconnect", Serial], TimeSpan.FromSeconds(10), cancellationToken);
        SetState(AdbRuntimeState.Disconnected);
    }

    public async Task<string> GetStateAsync(CancellationToken cancellationToken = default)
    {
        var result = await ExecuteAsync(["get-state"], TimeSpan.FromSeconds(8), cancellationToken, logOutput: false);
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
                    SetState(AdbRuntimeState.Ready);
                    progress?.Report(new RuntimeProgress("Android pronto", "sys.boot_completed=1", 70));
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
        return dump.Contains($"{packageName}/{activityName}", StringComparison.Ordinal) ||
               dump.Contains($"{packageName}/.{activityName}", StringComparison.Ordinal);
    }

    public async Task StartActivityAsync(string packageName, string activityName, CancellationToken cancellationToken = default)
    {
        var result = await ExecuteAsync(["shell", "am", "start", "-W", "-n", $"{packageName}/{activityName}"], TimeSpan.FromSeconds(Math.Max(10, _context.Config.Timeouts.NeoNewsStartSeconds)), cancellationToken);
        if (!result.Succeeded)
        {
            throw new RuntimeOperationException(
                "Não foi possível abrir o NeoNews.",
                $"Comando: adb -s {Serial} shell am start -W -n {packageName}/{activityName}\nExit code: {result.ExitCode}\nstderr: {result.StandardError}");
        }

        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(Math.Max(10, _context.Config.Timeouts.NeoNewsStartSeconds));
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (await IsActivityRunningAsync(packageName, activityName, cancellationToken)) return;
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
        }

        throw new RuntimeOperationException("O NeoNews não confirmou a atividade em execução.", $"Activity esperada: {packageName}/{activityName}");
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
                _logs.Warning("launcher", $"ABI preferencial {preferred} não está no APK; a instalação usará uma ABI compatível disponível.");
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
}

public sealed record AndroidGuestValidationResult(
    string Release,
    string ApiLevel,
    string BootCompleted,
    bool Ready,
    string Detail);
