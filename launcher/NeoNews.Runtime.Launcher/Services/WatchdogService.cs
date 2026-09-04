namespace NeoNews.Runtime.Launcher.Services;

public sealed class WatchdogService : IAsyncDisposable
{
    private readonly RuntimeSupervisorService _supervisor;

    public WatchdogService(
        RuntimeContext context,
        NeoNewsService neoNews,
        AdbService adb,
        IAndroidRuntimeBackend backend,
        NativeBridgeValidationService nativeBridge,
        KioskService kiosk,
        LogService logs)
    {
        _supervisor = new RuntimeSupervisorService(context, neoNews, adb, backend, nativeBridge, kiosk, logs);
    }

    public bool IsActive => _supervisor.IsActive;
    public bool HasNativeBridgeStructuralError => _supervisor.HasNativeBridgeStructuralError;
    public DateTimeOffset? LastHeartbeat => _supervisor.LastHeartbeat;
    public Task StartAsync() => _supervisor.StartAsync();
    public Task StopAsync() => _supervisor.StopAsync();
    public ValueTask DisposeAsync() => _supervisor.DisposeAsync();
}
