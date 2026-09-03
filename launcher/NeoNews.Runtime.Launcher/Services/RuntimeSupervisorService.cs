namespace NeoNews.Runtime.Launcher.Services;

public sealed class RuntimeSupervisorService : IAsyncDisposable
{
    private readonly RuntimeContext _context;
    private readonly NeoNewsService _neoNews;
    private readonly AdbService _adb;
    private readonly IAndroidRuntimeBackend _backend;
    private readonly NativeBridgeValidationService _nativeBridge;
    private readonly KioskService _kiosk;
    private readonly LogService _logs;
    private CancellationTokenSource? _shutdown;
    private Task? _loop;
    private int _started;
    private int _recoveryAttempts;
    private DateTimeOffset _cooldownUntil;
    private DateTimeOffset _lastAdbOfflineLog = DateTimeOffset.MinValue;
    private DateTimeOffset _lastBootingLog = DateTimeOffset.MinValue;
    private DateTimeOffset _lastActivityLossLog = DateTimeOffset.MinValue;
    private DateTimeOffset _lastKioskLossLog = DateTimeOffset.MinValue;
    private DateTimeOffset _lastClockSync = DateTimeOffset.MinValue;
    private bool _nativeBridgeStructuralError;

    public RuntimeSupervisorService(
        RuntimeContext context,
        NeoNewsService neoNews,
        AdbService adb,
        IAndroidRuntimeBackend backend,
        NativeBridgeValidationService nativeBridge,
        KioskService kiosk,
        LogService logs)
    {
        _context = context;
        _neoNews = neoNews;
        _adb = adb;
        _backend = backend;
        _nativeBridge = nativeBridge;
        _kiosk = kiosk;
        _logs = logs;
    }

    public bool IsActive => Volatile.Read(ref _started) == 1;
    public bool HasNativeBridgeStructuralError => _nativeBridgeStructuralError;

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
                if (!await _backend.IsRunningAsync(cancellationToken).ConfigureAwait(false))
                {
                    await RecoverBackendAsync(cancellationToken).ConfigureAwait(false);
                    continue;
                }
                if (!await _adb.IsDeviceOnlineAsync(cancellationToken).ConfigureAwait(false))
                {
                    if (ShouldLog(ref _lastAdbOfflineLog))
                        _logs.Warning("watchdog", "Nível 2: ADB está offline; aguardando/reconectando sem reiniciar o guest.");
                    _ = await _adb.ConnectAsync(cancellationToken).ConfigureAwait(false);
                    continue;
                }
                if (await _adb.GetPropertyAsync("sys.boot_completed", cancellationToken).ConfigureAwait(false) != "1")
                {
                    if (ShouldLog(ref _lastBootingLog))
                        _logs.Warning("watchdog", "Android ainda não confirmou boot completo.");
                    continue;
                }
                await SynchronizeClockIfDueAsync(cancellationToken).ConfigureAwait(false);
                var bridge = await _nativeBridge.ValidateGuestAsync(cancellationToken).ConfigureAwait(false);
                if (_context.Config.Android.NativeBridge.Required && !bridge.Ready)
                {
                    if (!_nativeBridgeStructuralError)
                        _logs.Error("watchdog", $"Native Bridge indisponível; nenhuma reinstalação automática será tentada. {bridge.Detail}");
                    _nativeBridgeStructuralError = true;
                    continue;
                }
                if (_nativeBridgeStructuralError)
                {
                    _logs.Info("watchdog", "Native Bridge voltou a responder; retomando supervisão.");
                    _nativeBridgeStructuralError = false;
                }

                var status = await _neoNews.GetStatusAsync(cancellationToken).ConfigureAwait(false);
                if (_context.Config.Supervisor.RestartOnActivityLoss && status.Installed && !status.Running)
                {
                    var recentLogcat = await _adb.GetLogcatAsync(160, cancellationToken).ConfigureAwait(false);
                    if (ContainsStructuralRuntimeFailure(recentLogcat))
                    {
                        if (!_nativeBridgeStructuralError)
                            _logs.Error("watchdog", "Falha estrutural detectada no logcat do NeoNews; nenhum relançamento automático será tentado.");
                        _nativeBridgeStructuralError = true;
                        continue;
                    }
                    if (ShouldLog(ref _lastActivityLossLog))
                        _logs.Warning("watchdog", "Nível 1: NeoNews não está em primeiro plano; relançando somente a activity.");
                    await _neoNews.StartAsync(null, cancellationToken).ConfigureAwait(false);
                }
                else if (status.Running)
                {
                    _recoveryAttempts = 0;
                }
                if (_kiosk.IsActive && !await _kiosk.IsGuestConfigurationAppliedAsync(cancellationToken).ConfigureAwait(false))
                {
                    if (ShouldLog(ref _lastKioskLossLog))
                        _logs.Warning("watchdog", "Configuração kiosk perdida; reaplicando a política configurada.");
                    await _kiosk.EnterAsync(null, cancellationToken).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception exception)
            {
                _logs.Error("watchdog", "Falha no ciclo do watchdog.", exception);
            }
        }
    }

    private async Task SynchronizeClockIfDueAsync(CancellationToken cancellationToken)
    {
        if (!_context.Config.Runtime.SyncClockWithHost) return;

        var now = DateTimeOffset.UtcNow;
        if (now - _lastClockSync < TimeSpan.FromSeconds(30)) return;

        try
        {
            var clock = await _adb.EnsureHostClockAsync(
                _context.Config.Runtime.Timezone,
                _context.Config.Runtime.MaxClockSkewSeconds,
                cancellationToken).ConfigureAwait(false);
            _lastClockSync = now;
            if (!clock.Validated)
                _logs.Warning("watchdog", $"Relógio do Android fora de sincronia; nova verificação será feita em breve. {clock.Detail}");
            else
                _logs.Info("watchdog", $"CLOCK_SYNC_OK {clock.Detail}");
        }
        catch (Exception exception)
        {
            _logs.Warning("watchdog", $"Não foi possível sincronizar o relógio do Android neste ciclo: {exception.Message}");
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
            var guest = await _adb.ValidateGuestIdentityAsync(_context.Config.Android.Release, _context.Config.Android.ApiLevel, cancellationToken).ConfigureAwait(false);
            if (!guest.Ready)
            {
                _logs.Error("watchdog", $"Runtime recuperado, mas a identidade do guest não confere: {guest.Detail}");
                _nativeBridgeStructuralError = true;
                return;
            }
            var bridge = await _nativeBridge.ValidateGuestAsync(cancellationToken).ConfigureAwait(false);
            if (_context.Config.Android.NativeBridge.Required && !bridge.Ready)
            {
                _logs.Error("watchdog", $"Runtime recuperado, mas Native Bridge não está disponível: {bridge.Detail}");
                _nativeBridgeStructuralError = true;
                return;
            }
            _logs.Info("watchdog", "Runtime Android recuperado; a activity será verificada no próximo ciclo.");
        }
        catch (Exception exception)
        {
            _logs.Error("watchdog", "Falha na recuperação do runtime Android.", exception);
            _cooldownUntil = DateTimeOffset.UtcNow.AddSeconds(Math.Max(5, _context.Config.Resilience.RetryDelaySeconds));
        }
    }

    private static bool ContainsStructuralRuntimeFailure(string logcat)
    {
        if (string.IsNullOrWhiteSpace(logcat)) return false;
        var relevant = logcat
            .Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries)
            .Where(line => line.Contains("com.in9midia.neonews.player", StringComparison.OrdinalIgnoreCase) ||
                           line.Contains("native bridge", StringComparison.OrdinalIgnoreCase) ||
                           System.Text.RegularExpressions.Regex.IsMatch(line, "UnsatisfiedLinkError|linker|SIGSEGV|FATAL EXCEPTION|dex2oat|zygote", System.Text.RegularExpressions.RegexOptions.IgnoreCase));
        return relevant.Any(line => System.Text.RegularExpressions.Regex.IsMatch(
            line,
            "UnsatisfiedLinkError|linker.*(error|fail)|SIGSEGV|FATAL EXCEPTION|dex2oat.*(error|fail)|zygote.*(error|fail)|native bridge.*(error|fail)",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase));
    }

    private bool ShouldLog(ref DateTimeOffset lastLog)
    {
        var now = DateTimeOffset.UtcNow;
        var cooldownSeconds = Math.Max(15, _context.Config.Resilience.RetryDelaySeconds * 3);
        if (now - lastLog < TimeSpan.FromSeconds(cooldownSeconds)) return false;
        lastLog = now;
        return true;
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _shutdown?.Dispose();
    }
}
