namespace NeoNews.Runtime.Launcher.Services;

public sealed class ScriptExecutionService
{
    private readonly RuntimeContext _context;
    private readonly ProcessRunnerService _runner;

    public ScriptExecutionService(RuntimeContext context, ProcessRunnerService runner)
    {
        _context = context;
        _runner = runner;
    }

    public Task<ProcessResult> ExecuteAsync(
        string configuredScript,
        IEnumerable<string> arguments,
        string category = "script",
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        var scriptPath = _context.ResolvePath(configuredScript);
        if (!File.Exists(scriptPath)) throw new FileNotFoundException("Script legado não encontrado.", scriptPath);

        var powershell = FindPowerShell();
        var commandArguments = new List<string>
        {
            "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", scriptPath
        };
        commandArguments.AddRange(arguments);
        return _runner.RunAsync(
            powershell,
            commandArguments,
            _context.RootDirectory,
            category,
            timeout ?? TimeSpan.FromMinutes(10),
            cancellationToken);
    }

    private static string FindPowerShell()
    {
        var pwsh = Environment.GetEnvironmentVariable("PATH")?
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(path => Path.Combine(path, "pwsh.exe"))
            .FirstOrDefault(File.Exists);
        if (pwsh is not null) return pwsh;

        var powershell = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        return File.Exists(powershell) ? powershell : "powershell.exe";
    }
}
