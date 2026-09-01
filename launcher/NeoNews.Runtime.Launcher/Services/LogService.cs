using System.Text;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class LogService
{
    private readonly RuntimeContext _context;
    private readonly object _sync = new();

    public LogService(RuntimeContext context)
    {
        _context = context;
        Directory.CreateDirectory(_context.LogsDirectory);
    }

    public string LauncherLogPath => Path.Combine(_context.LogsDirectory, "launcher.log");

    public void Info(string category, string message) => Write(category, "INFO", message, null);
    public void Warning(string category, string message) => Write(category, "WARN", message, null);
    public void Error(string category, string message, Exception? exception = null) => Write(category, "ERROR", message, exception);

    public async Task<string> ReadTailAsync(string fileName = "launcher.log", int maxLines = 200, CancellationToken cancellationToken = default)
    {
        var path = Path.Combine(_context.LogsDirectory, fileName);
        if (!File.Exists(path)) return string.Empty;

        var bytesToRead = 128 * 1024;
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096, FileOptions.Asynchronous | FileOptions.SequentialScan);
        if (stream.Length > bytesToRead) stream.Seek(-bytesToRead, SeekOrigin.End);
        using var reader = new StreamReader(stream, Encoding.UTF8, true);
        var text = await reader.ReadToEndAsync(cancellationToken);
        var lines = text.Split(["\r\n", "\n"], StringSplitOptions.None);
        return string.Join(Environment.NewLine, lines.TakeLast(maxLines));
    }

    private void Write(string category, string level, string message, Exception? exception)
    {
        var path = Path.Combine(_context.LogsDirectory, $"{category}.log");
        var line = $"{DateTimeOffset.Now:O} [{level}] {message}";
        if (exception is not null) line += Environment.NewLine + exception;
        lock (_sync)
        {
            Directory.CreateDirectory(_context.LogsDirectory);
            File.AppendAllText(path, line + Environment.NewLine, Encoding.UTF8);
            if (!string.Equals(category, "launcher", StringComparison.OrdinalIgnoreCase))
            {
                File.AppendAllText(LauncherLogPath, line + Environment.NewLine, Encoding.UTF8);
            }
        }
    }
}
