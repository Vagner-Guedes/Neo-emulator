namespace NeoNews.Runtime.Launcher.Services;

public sealed class RuntimeSupervisorService : IAsyncDisposable
{
    private readonly RuntimeContext _context;
    private readonly NeoNewsService _neoNews;
    private readonly AdbService _adb;
    private readonly EmulatorService _emulator;
    private readonly LogService _logs;
    private CancellationTokenSource? _shutdown;
    private Task? _loop;
    private int _started;

    public RuntimeSupervisorService(RuntimeContext context, NeoNewsService neoNews, AdbService adb, EmulatorService emulator, LogService logs)
    {
        _context = context;
        _neoNews = neoNews;
        _adb = adb;
        _emulator = emulator;
        _logs = logs;
    }

    public bool IsActive => Volatile.Read(ref _started) == 1;

    public Task StartAsync()
    {
        if (Interlocked.Exchange(ref _started, 1) == 0)
        {
            _shutdown = new CancellationTokenSource();
            _loop = Task.Run(() => MonitorAsync(_shutdown.Token));
            _logs.Info("watchdog", "Watchdog iniciado.");
        }
        return Task.CompletedTask;
    }

    public async Task StopAsync()
    {
        if (Interlocked.Exchange(ref _started, 0) == 1)
        {
            _shutdown?.Cancel();
            if (_loop is not null)
            {
                try { await _loop.ConfigureAwait(false); }
                catch (OperationCanceledException) { }
            }
            _loop = null;
            _logs.Info("watchdog", "Watchdog parado.");
        }
    }

    private async Task MonitorAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(Math.Max(5, _context.Config.Supervisor.PollSeconds)));
        while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
        {
            try
            {
                if (!_context.Config.Supervisor.RestartOnActivityLoss) continue;
                if (!await _emulator.IsRunningAsync(cancellationToken).ConfigureAwait(false))
                {
                    _logs.Warning("watchdog", "Emulator não está em execução.");
                    continue;
                }
                if (!await _adb.IsDeviceOnlineAsync(cancellationToken).ConfigureAwait(false))
                {
                    _logs.Warning("watchdog", "ADB está offline.");
                    continue;
                }
                if (await _adb.GetPropertyAsync("sys.boot_completed", cancellationToken).ConfigureAwait(false) != "1")
                {
                    _logs.Warning("watchdog", "Android ainda não confirmou boot completo.");
                    continue;
                }
                var status = await _neoNews.GetStatusAsync(cancellationToken).ConfigureAwait(false);
                if (status.Installed && !status.Running)
                {
                    _logs.Warning("watchdog", "NeoNews não está em primeiro plano; tentando relançar.");
                    await _neoNews.StartAsync(null, cancellationToken).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception exception)
            {
                _logs.Error("watchdog", "Falha no ciclo do watchdog.", exception);
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _shutdown?.Dispose();
    }
}
