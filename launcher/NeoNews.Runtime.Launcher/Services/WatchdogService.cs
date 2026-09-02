namespace NeoNews.Runtime.Launcher.Services;

public sealed class WatchdogService : IAsyncDisposable
{
    private readonly RuntimeSupervisorService _supervisor;

    public WatchdogService(RuntimeContext context, NeoNewsService neoNews, AdbService adb, IAndroidRuntimeBackend backend, LogService logs)
    {
        _supervisor = new RuntimeSupervisorService(context, neoNews, adb, backend, logs);
    }

    public bool IsActive => _supervisor.IsActive;
    public Task StartAsync() => _supervisor.StartAsync();
    public Task StopAsync() => _supervisor.StopAsync();
    public ValueTask DisposeAsync() => _supervisor.DisposeAsync();
}
