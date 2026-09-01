using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class StartupService
{
    private readonly RuntimeContext _context;
    private readonly ProcessRunnerService _runner;

    public StartupService(RuntimeContext context, ProcessRunnerService runner)
    {
        _context = context;
        _runner = runner;
    }

    private string TaskName => _context.Config.Startup.TaskName;
    private string SchtasksPath => Path.Combine(Environment.SystemDirectory, "schtasks.exe");

    public async Task<bool> IsRegisteredAsync(CancellationToken cancellationToken = default)
    {
        var result = await _runner.RunAsync(
            SchtasksPath,
            ["/Query", "/TN", TaskName, "/FO", "CSV", "/NH"],
            _context.RootDirectory,
            "startup",
            TimeSpan.FromSeconds(15),
            cancellationToken,
            logOutput: false);
        return result.Succeeded;
    }

    public async Task RegisterAsync(string executablePath, CancellationToken cancellationToken = default)
    {
        var delay = TimeSpan.FromSeconds(Math.Max(0, _context.Config.Startup.LogonDelaySeconds));
        var delayText = $"{(int)delay.TotalHours:00}:{delay.Minutes:00}:{delay.Seconds:00}";
        var arguments = new[]
        {
            "/Create", "/TN", TaskName,
            "/TR", $"\"{executablePath}\" --autostart",
            "/SC", "ONLOGON", "/DELAY", delayText, "/F"
        };
        var result = await _runner.RunAsync(
            SchtasksPath,
            arguments,
            _context.RootDirectory,
            "startup",
            TimeSpan.FromSeconds(30),
            cancellationToken);
        if (!result.Succeeded)
        {
            throw CreateError("Não foi possível ativar o início com o Windows.", result);
        }
    }

    public async Task UnregisterAsync(CancellationToken cancellationToken = default)
    {
        var result = await _runner.RunAsync(
            SchtasksPath,
            ["/Delete", "/TN", TaskName, "/F"],
            _context.RootDirectory,
            "startup",
            TimeSpan.FromSeconds(30),
            cancellationToken);
        if (!result.Succeeded && !IsMissingTask(result))
        {
            throw CreateError("Não foi possível remover o início com o Windows.", result);
        }
    }

    private static RuntimeOperationException CreateError(string message, ProcessResult result) =>
        new(message, $"Exit code: {result.ExitCode}{Environment.NewLine}{result.StandardError}{Environment.NewLine}{result.StandardOutput}");

    private static bool IsMissingTask(ProcessResult result) =>
        result.StandardError.Contains("does not exist", StringComparison.OrdinalIgnoreCase) ||
        result.StandardError.Contains("cannot find", StringComparison.OrdinalIgnoreCase) ||
        result.StandardOutput.Contains("does not exist", StringComparison.OrdinalIgnoreCase) ||
        result.StandardOutput.Contains("cannot find", StringComparison.OrdinalIgnoreCase);
}
