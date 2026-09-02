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

public enum AndroidGuestState
{
    Offline,
    Booting,
    Online,
    Error
}

public enum AdbRuntimeState
{
    Disconnected,
    Connecting,
    Device,
    Offline,
    Unauthorized,
    Booting,
    Ready
}

public enum NativeBridgeState
{
    Unknown,
    Unavailable,
    Ready,
    Error
}

public enum NeoNewsRuntimeState
{
    NotInstalled,
    Installed,
    Running,
    Error
}

public enum WebViewRuntimeState
{
    Unknown,
    Mismatch,
    Ready
}

public enum TtsRuntimeState
{
    Unknown,
    Missing,
    Ready
}

public enum WatchdogRuntimeState
{
    Inactive,
    Active
}

public enum StartupRuntimeState
{
    Inactive,
    Active
}

public enum InternetRuntimeState
{
    Unknown,
    Offline,
    Online
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
    bool NeoNewsRunning)
{
    // The existing string labels remain part of the launcher contract. These
    // typed states let services make decisions without parsing UI text.
    public AndroidGuestState AndroidState { get; init; } = AndroidGuestState.Offline;
    public AdbRuntimeState AdbState { get; init; } = AdbRuntimeState.Disconnected;
    public NativeBridgeState NativeBridge { get; init; } = NativeBridgeState.Unknown;
    public NeoNewsRuntimeState NeoNewsState { get; init; } = NeoNewsRuntimeState.NotInstalled;
    public WebViewRuntimeState WebViewState { get; init; } = WebViewRuntimeState.Unknown;
    public TtsRuntimeState TtsState { get; init; } = TtsRuntimeState.Unknown;
    public WatchdogRuntimeState WatchdogState { get; init; } = WatchdogRuntimeState.Inactive;
    public StartupRuntimeState StartupState { get; init; } = StartupRuntimeState.Inactive;
    public InternetRuntimeState InternetState { get; init; } = InternetRuntimeState.Unknown;
    public bool KioskActive { get; init; }
}

public sealed class RuntimeOperationException : Exception
{
    public RuntimeOperationException(string userMessage, string technicalDetails, Exception? innerException = null)
        : base(userMessage, innerException)
    {
        TechnicalDetails = technicalDetails;
    }

    public string TechnicalDetails { get; }
}
