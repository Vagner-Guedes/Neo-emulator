namespace NeoNews.Runtime.Launcher.Services;

public sealed class RuntimeSupervisorService : IAsyncDisposable
{
    private readonly RuntimeContext _context;
    private readonly NeoNewsService _neoNews;
    private readonly AdbService _adb;
    private readonly IAndroidRuntimeBackend _backend;
    private readonly LogService _logs;
    private CancellationTokenSource? _shutdown;
    private Task? _loop;
    private int _started;
    private int _recoveryAttempts;
    private DateTimeOffset _cooldownUntil;

    public RuntimeSupervisorService(RuntimeContext context, NeoNewsService neoNews, AdbService adb, IAndroidRuntimeBackend backend, LogService logs)
    {
        _context = context;
        _neoNews = neoNews;
        _adb = adb;
        _backend = backend;
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
                if (!await _backend.IsRunningAsync(cancellationToken).ConfigureAwait(false))
                {
                    await RecoverBackendAsync(cancellationToken).ConfigureAwait(false);
                    continue;
                }
                if (!await _adb.IsDeviceOnlineAsync(cancellationToken).ConfigureAwait(false))
                {
                    _logs.Warning("watchdog", "Nível 2: ADB está offline; aguardando/reconectando sem reiniciar o guest.");
                    _ = await _adb.ConnectAsync(cancellationToken).ConfigureAwait(false);
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
                    _logs.Warning("watchdog", "Nível 1: NeoNews não está em primeiro plano; relançando somente a activity.");
                    await _neoNews.StartAsync(null, cancellationToken).ConfigureAwait(false);
                }
                else if (status.Running)
                {
                    _recoveryAttempts = 0;
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception exception)
            {
                _logs.Error("watchdog", "Falha no ciclo do watchdog.", exception);
            }
        }
    }

    private async Task RecoverBackendAsync(CancellationToken cancellationToken)
    {
        if (DateTimeOffset.UtcNow < _cooldownUntil) return;
        var maxAttempts = Math.Max(1, _context.Config.Resilience.MaxAttempts);
        if (_recoveryAttempts >= maxAttempts)
        {
            _logs.Error("watchdog", $"Nível 3: {_backend.Name} continua indisponível após {maxAttempts} tentativas; cooldown aplicado.");
            _cooldownUntil = DateTimeOffset.UtcNow.AddMinutes(1);
            _recoveryAttempts = 0;
            return;
        }

        _recoveryAttempts++;
        _logs.Warning("watchdog", $"Nível 3: {_backend.Name} encerrou; reiniciando runtime (tentativa {_recoveryAttempts}/{maxAttempts}).");
        try
        {
            await _backend.RestartAsync(null, cancellationToken).ConfigureAwait(false);
            await _adb.WaitForBootAsync(null, TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.BootSeconds)), cancellationToken).ConfigureAwait(false);
            _logs.Info("watchdog", "Runtime Android recuperado; a activity será verificada no próximo ciclo.");
        }
        catch (Exception exception)
        {
            _logs.Error("watchdog", "Falha na recuperação do runtime Android.", exception);
            _cooldownUntil = DateTimeOffset.UtcNow.AddSeconds(Math.Max(5, _context.Config.Resilience.RetryDelaySeconds));
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _shutdown?.Dispose();
    }
}
