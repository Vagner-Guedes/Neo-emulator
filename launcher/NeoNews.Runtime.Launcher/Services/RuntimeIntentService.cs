using System.Text.Json;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

/// <summary>
/// Persists the operator's explicit runtime intent separately from the guest
/// state. The watchdog consults this marker before attempting recovery, so a
/// deliberate stop survives launcher restarts and Windows logon.
/// </summary>
public sealed class RuntimeIntentService
{
    private readonly object _sync = new();
    private readonly string _path;
    private RuntimeIntentRecord _current;

    public RuntimeIntentService(RuntimeContext context)
    {
        _path = context.Paths.RuntimeIntentStatePath;
        _current = Load();
    }

    public RuntimeIntentRecord Current
    {
        get { lock (_sync) return _current; }
    }

    public bool IsRecoverySuppressed => Current.Intent == RuntimeIntentKind.UserStoppedRuntime;

    public void MarkUserStopped(string reason = "user-stop") =>
        Set(RuntimeIntentKind.UserStoppedRuntime, reason);

    public void ClearUserStop(string reason = "operator-start")
    {
        lock (_sync)
        {
            if (_current.Intent != RuntimeIntentKind.UserStoppedRuntime) return;
        }

        Set(RuntimeIntentKind.None, reason);
    }

    private void Set(RuntimeIntentKind intent, string reason)
    {
        var record = new RuntimeIntentRecord(intent, reason, DateTimeOffset.UtcNow, Environment.ProcessId);
        var json = JsonSerializer.Serialize(record, RuntimeContext.JsonOptions);
        var directory = Path.GetDirectoryName(_path)!;
        Directory.CreateDirectory(directory);
        var temporaryPath = _path + ".tmp";
        File.WriteAllText(temporaryPath, json, new System.Text.UTF8Encoding(false));
        File.Move(temporaryPath, _path, true);
        lock (_sync) _current = record;
    }

    private RuntimeIntentRecord Load()
    {
        try
        {
            if (!File.Exists(_path))
                return new RuntimeIntentRecord(RuntimeIntentKind.None, "initial", DateTimeOffset.UtcNow, 0);

            var json = File.ReadAllText(_path);
            return JsonSerializer.Deserialize<RuntimeIntentRecord>(json, RuntimeContext.JsonOptions)
                ?? new RuntimeIntentRecord(RuntimeIntentKind.None, "invalid-empty", DateTimeOffset.UtcNow, 0);
        }
        catch
        {
            // A malformed marker must never prevent the launcher from opening;
            // the safe default is no suppression, with the next explicit stop
            // replacing it atomically.
            return new RuntimeIntentRecord(RuntimeIntentKind.None, "invalid-marker", DateTimeOffset.UtcNow, 0);
        }
    }
}
