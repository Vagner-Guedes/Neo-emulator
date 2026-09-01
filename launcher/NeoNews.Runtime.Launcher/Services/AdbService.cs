using System.Text.RegularExpressions;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class AdbService
{
    private readonly RuntimeContext _context;
    private readonly ProcessRunnerService _runner;
    private readonly LogService _logs;

    public AdbService(RuntimeContext context, ProcessRunnerService runner, LogService logs)
    {
        _context = context;
        _runner = runner;
        _logs = logs;
    }

    public string Serial => $"emulator-{_context.Config.Android.Emulator.ValidationPort}";
    public string AdbPath => _context.ResolveAdbPath();

    public Task<ProcessResult> ExecuteAsync(IEnumerable<string> arguments, TimeSpan? timeout = null, CancellationToken cancellationToken = default, bool logOutput = true)
    {
        var fullArguments = new[] { "-s", Serial }.Concat(arguments);
        return _runner.RunAsync(AdbPath, fullArguments, _context.RootDirectory, "adb", timeout ?? TimeSpan.FromSeconds(30), cancellationToken, logOutput);
    }

    public async Task<string> GetStateAsync(CancellationToken cancellationToken = default)
    {
        var result = await ExecuteAsync(["get-state"], TimeSpan.FromSeconds(8), cancellationToken, logOutput: false);
        return result.Succeeded ? result.StandardOutput.Trim() : string.Empty;
    }

    public async Task<bool> IsDeviceOnlineAsync(CancellationToken cancellationToken = default) =>
        string.Equals(await GetStateAsync(cancellationToken), "device", StringComparison.OrdinalIgnoreCase);

    public async Task<string> ShellAsync(IEnumerable<string> arguments, TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        var result = await ExecuteAsync(new[] { "shell" }.Concat(arguments), timeout, cancellationToken, logOutput: false);
        return result.StandardOutput.Trim();
    }

    public async Task<string> GetPropertyAsync(string property, CancellationToken cancellationToken = default) =>
        await ShellAsync(["getprop", property], TimeSpan.FromSeconds(10), cancellationToken);

    public async Task WaitForBootAsync(IProgress<RuntimeProgress>? progress, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var state = await GetStateAsync(cancellationToken);
            if (state == "device")
            {
                progress?.Report(new RuntimeProgress("Aguardando inicialização", "ADB respondeu; verificando Android...", 55));
                var boot = await GetPropertyAsync("sys.boot_completed", cancellationToken);
                if (boot == "1")
                {
                    progress?.Report(new RuntimeProgress("Android pronto", "sys.boot_completed=1", 70));
                    return;
                }
            }
            else
            {
                progress?.Report(new RuntimeProgress("Aguardando ADB", "Conectando ao dispositivo Android...", null));
            }
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
        }

        throw new RuntimeOperationException(
            "Não foi possível conectar ao Android.",
            $"ADB não confirmou o boot do serial {Serial} em {timeout.TotalSeconds:0} segundos.");
    }

    public async Task<bool> IsPackageInstalledAsync(string packageName, CancellationToken cancellationToken = default)
    {
        var path = await ShellAsync(["pm", "path", packageName], TimeSpan.FromSeconds(15), cancellationToken);
        return path.StartsWith("package:", StringComparison.Ordinal);
    }

    public Task<bool> WaitForDeviceAsync(TimeSpan timeout, CancellationToken cancellationToken = default) =>
        WaitForStateAsync("device", timeout, cancellationToken);

    public Task ForceStopAsync(string packageName, CancellationToken cancellationToken = default) =>
        StopPackageAsync(packageName, cancellationToken);

    private async Task<bool> WaitForStateAsync(string expectedState, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (string.Equals(await GetStateAsync(cancellationToken), expectedState, StringComparison.OrdinalIgnoreCase)) return true;
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
        }
        return false;
    }

    public async Task<string> GetPackageDumpAsync(string packageName, CancellationToken cancellationToken = default) =>
        await ShellAsync(["dumpsys", "package", packageName], TimeSpan.FromSeconds(30), cancellationToken);

    public async Task<string?> GetPackageVersionAsync(string packageName, CancellationToken cancellationToken = default)
    {
        var dump = await GetPackageDumpAsync(packageName, cancellationToken);
        var match = Regex.Match(dump, @"versionName=([^\s]+)");
        return match.Success ? match.Groups[1].Value : null;
    }

    public async Task<string> GetActivityDumpAsync(CancellationToken cancellationToken = default) =>
        await ShellAsync(["dumpsys", "activity", "activities"], TimeSpan.FromSeconds(20), cancellationToken);

    public async Task<bool> IsActivityRunningAsync(string packageName, string activityName, CancellationToken cancellationToken = default)
    {
        var dump = await GetActivityDumpAsync(cancellationToken);
        return dump.Contains($"{packageName}/{activityName}", StringComparison.Ordinal);
    }

    public async Task StartActivityAsync(string packageName, string activityName, CancellationToken cancellationToken = default)
    {
        var result = await ExecuteAsync(["shell", "am", "start", "-W", "-n", $"{packageName}/{activityName}"], TimeSpan.FromMinutes(2), cancellationToken);
        if (!result.Succeeded)
        {
            throw new RuntimeOperationException(
                "Não foi possível abrir o NeoNews.",
                $"Comando: adb -s {Serial} shell am start -W -n {packageName}/{activityName}\nExit code: {result.ExitCode}\nstderr: {result.StandardError}");
        }
    }

    public async Task StopPackageAsync(string packageName, CancellationToken cancellationToken = default) =>
        _ = await ExecuteAsync(["shell", "am", "force-stop", packageName], TimeSpan.FromSeconds(30), cancellationToken);

    public async Task InstallApkAsync(string apkPath, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(apkPath))
        {
            throw new RuntimeOperationException("NeoNews.apk não encontrado.", $"Caminho esperado: {apkPath}");
        }

        _logs.Info("launcher", $"Instalação autorizada do APK: {apkPath}");
        var result = await ExecuteAsync(["install", "-r", apkPath], TimeSpan.FromMinutes(10), cancellationToken);
        if (!result.Succeeded)
        {
            throw new RuntimeOperationException(
                "Não foi possível instalar o NeoNews.",
                $"Exit code: {result.ExitCode}\n{result.StandardError}\n{result.StandardOutput}");
        }
    }

    public async Task PutSettingAsync(string scope, string name, string value, CancellationToken cancellationToken = default) =>
        _ = await ExecuteAsync(["shell", "settings", "put", scope, name, value], TimeSpan.FromSeconds(20), cancellationToken);

    public async Task DeleteSettingAsync(string scope, string name, CancellationToken cancellationToken = default) =>
        _ = await ExecuteAsync(["shell", "settings", "delete", scope, name], TimeSpan.FromSeconds(20), cancellationToken);

    public async Task SetDisplayAsync(string size, int density, CancellationToken cancellationToken = default)
    {
        _ = await ExecuteAsync(["shell", "wm", "size", size], TimeSpan.FromSeconds(20), cancellationToken);
        _ = await ExecuteAsync(["shell", "wm", "density", density.ToString()], TimeSpan.FromSeconds(20), cancellationToken);
    }

    public async Task<string> GetWebViewDumpAsync(CancellationToken cancellationToken = default) =>
        await ShellAsync(["dumpsys", "webviewupdate"], TimeSpan.FromSeconds(20), cancellationToken);

    public async Task<string> GetTtsDefaultAsync(CancellationToken cancellationToken = default) =>
        await ShellAsync(["settings", "get", "secure", "tts_default_synth"], TimeSpan.FromSeconds(15), cancellationToken);

    public async Task<string> GetPackagesAsync(CancellationToken cancellationToken = default) =>
        await ShellAsync(["pm", "list", "packages"], TimeSpan.FromSeconds(30), cancellationToken);

    public async Task<string> GetMemoryDumpAsync(CancellationToken cancellationToken = default) =>
        await ShellAsync(["dumpsys", "meminfo"], TimeSpan.FromSeconds(30), cancellationToken);

    public async Task<string> GetGraphicsDumpAsync(CancellationToken cancellationToken = default) =>
        await ShellAsync(["dumpsys", "gfxinfo"], TimeSpan.FromSeconds(30), cancellationToken);

    public async Task<string> GetLogcatAsync(int lines, CancellationToken cancellationToken = default) =>
        await ShellAsync(["logcat", "-d", "-b", "all", "-t", lines.ToString()], TimeSpan.FromMinutes(2), cancellationToken);

    public async Task SendEmulatorCommandAsync(string command, CancellationToken cancellationToken = default) =>
        _ = await ExecuteAsync(["emu", command], TimeSpan.FromSeconds(30), cancellationToken);
}
