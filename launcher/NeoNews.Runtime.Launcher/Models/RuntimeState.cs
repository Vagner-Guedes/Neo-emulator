namespace NeoNews.Runtime.Launcher.Models;

public enum RuntimeState
{
    Stopped,
    Starting,
    WaitingForAdb,
    BootingAndroid,
    Preparing,
    StartingNeoNews,
    EnteringKiosk,
    Running,
    Recovering,
    Stopping,
    Error
}

public sealed record RuntimeProgress(string Phase, string Detail, double? Percent = null);

public sealed record RuntimeSnapshot(
    RuntimeState State,
    string Android,
    string NeoNews,
    string WebView,
    string Voice,
    string Watchdog,
    string Startup,
    string Adb,
    bool EmulatorRunning,
    bool PackageInstalled,
    bool NeoNewsRunning);

public sealed class RuntimeOperationException : Exception
{
    public RuntimeOperationException(string userMessage, string technicalDetails, Exception? innerException = null)
        : base(userMessage, innerException)
    {
        TechnicalDetails = technicalDetails;
    }

    public string TechnicalDetails { get; }
}
