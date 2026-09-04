namespace NeoNews.Runtime.Launcher.Models;

public enum RuntimeIntentKind
{
    None,
    UserStoppedRuntime
}

public sealed record RuntimeIntentRecord(
    RuntimeIntentKind Intent,
    string Reason,
    DateTimeOffset UpdatedAtUtc,
    int ProcessId);
