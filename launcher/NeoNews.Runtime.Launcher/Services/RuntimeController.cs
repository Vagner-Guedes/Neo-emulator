using System.Text.RegularExpressions;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class RuntimeController : IAsyncDisposable
{
    private readonly RuntimeContext _context;
    private readonly LogService _logs;
    private readonly ProcessRunnerService _runner;
    private readonly ScriptExecutionService _scripts;
    private readonly AdbService _adb;
    private readonly EmulatorService _emulator;
    private readonly NeoNewsService _neoNews;
    private readonly KioskService _kiosk;
    private readonly StartupService _startup;
    private readonly WatchdogService _supervisor;
    private readonly DiagnosticsService _diagnostics;
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private readonly RuntimeStateService _state = new();

    public RuntimeController(RuntimeContext context)
    {
        _context = context;
        _logs = new LogService(context);
        _runner = new ProcessRunnerService(_logs);
        _scripts = new ScriptExecutionService(context, _runner);
        _adb = new AdbService(context, _runner, _logs);
        _emulator = new EmulatorService(context, _runner, _logs, _adb);
        _neoNews = new NeoNewsService(context, _adb);
        _kiosk = new KioskService(context, _adb, _emulator);
        _startup = new StartupService(context, _runner);
        _supervisor = new WatchdogService(context, _neoNews, _adb, _emulator, _logs);
        _diagnostics = new DiagnosticsService(context, _adb, _emulator, _neoNews, _supervisor, _startup, _logs);
        _state.Changed += (_, state) => StateChanged?.Invoke(this, state);
        Snapshot = new RuntimeSnapshot(RuntimeState.Stopped, "Offline", "Não verificado", "Pendente", "Não instalado", "Inativo", "Não verificado", "Offline", false, false, false);
    }

    public RuntimeContext Context => _context;
    public LogService Logs => _logs;
    public ScriptExecutionService Scripts => _scripts;
    public RuntimeState State => _state.Current;
    public bool IsKioskActive => _kiosk.IsActive;
    public bool IsSupervisorActive => _supervisor.IsActive;
    public RuntimeSnapshot Snapshot { get; private set; }
    public event EventHandler<RuntimeState>? StateChanged;
    public event EventHandler<RuntimeSnapshot>? SnapshotChanged;

    public async Task<RuntimeSnapshot> RefreshSnapshotAsync(CancellationToken cancellationToken = default)
    {
        var emulatorRunning = await _emulator.IsRunningAsync(cancellationToken);
        var adbOnline = await _adb.IsDeviceOnlineAsync(cancellationToken);
        var booted = adbOnline && await _adb.GetPropertyAsync("sys.boot_completed", cancellationToken) == "1";
        var packageInstalled = false;
        var neoRunning = false;
        string neoLabel = "Não instalado";
        if (booted)
        {
            var neoStatus = await _neoNews.GetStatusAsync(cancellationToken);
            packageInstalled = neoStatus.Installed;
            neoRunning = neoStatus.Running;
            neoLabel = neoStatus.Installed ? (neoStatus.Running ? "Em execução" : $"Instalado {neoStatus.Version}") : "Não instalado";
        }

        var webViewLabel = "Pendente";
        if (booted)
        {
            var dump = await SafeAsync(() => _adb.GetPackageDumpAsync(_context.Config.WebView.Provider, cancellationToken), cancellationToken);
            var match = Regex.Match(dump, @"versionName=([^\s]+)");
            var version = match.Success ? match.Groups[1].Value : null;
            webViewLabel = version is null ? "Não encontrado" : version == _context.Config.WebView.HomologatedVersion ? "Validado" : $"Divergente ({version})";
        }

        var voiceLabel = "Não instalado";
        if (booted)
        {
            var packages = await SafeAsync(() => _adb.GetPackagesAsync(cancellationToken), cancellationToken);
            voiceLabel = packages.Contains("rhvoice", StringComparison.OrdinalIgnoreCase)
                ? "RHVoice instalada"
                : "RHVoice ausente";
        }

        var startupRegistered = await _startup.IsRegisteredAsync(cancellationToken);
        var startupValid = startupRegistered && await _startup.ValidateAsync(Environment.ProcessPath ?? string.Empty, cancellationToken);
        var startupLabel = startupValid ? "Ativo" : "Inativo";
        Snapshot = new RuntimeSnapshot(
            State,
            booted ? "Online" : emulatorRunning ? "Iniciando" : "Offline",
            neoLabel,
            webViewLabel,
            voiceLabel,
            _supervisor.IsActive ? "Ativo" : "Inativo",
            startupLabel,
            adbOnline ? "Online" : "Offline",
            emulatorRunning,
            packageInstalled,
            neoRunning);
        SnapshotChanged?.Invoke(this, Snapshot);
        return Snapshot;
    }

    public async Task StartAndroidAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        await WithOperationAsync(RuntimeState.Starting, async () =>
        {
            progress?.Report(new RuntimeProgress("Preparando ambiente", "Validando ferramentas locais...", 5));
            await _emulator.StartAsync(progress, cancellationToken);
            _state.Set(RuntimeState.WaitingForAdb);
            progress?.Report(new RuntimeProgress("Aguardando ADB", "Conectando ao Android...", 35));
            await _adb.WaitForBootAsync(progress, TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.BootSeconds)), cancellationToken);
            _state.Set(RuntimeState.Running);
            await _supervisor.StartAsync();
            await RefreshSnapshotAsync(cancellationToken);
            progress?.Report(new RuntimeProgress("Android online", "O guest está pronto.", 100));
        });
    }

    public async Task StartNeoNewsAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        await WithOperationAsync(RuntimeState.Starting, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            _state.Set(RuntimeState.StartingNeoNews);
            await _neoNews.StartAsync(progress, cancellationToken);
            if (_context.Config.Startup.AutoKiosk || _context.Config.Android.Kiosk.Status == "active")
            {
                _state.Set(RuntimeState.EnteringKiosk);
                await _kiosk.EnterAsync(progress, cancellationToken);
            }
            await _supervisor.StartAsync();
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
        });
    }

    public async Task StopAndroidAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        await WithOperationAsync(RuntimeState.Stopping, async () =>
        {
            progress?.Report(new RuntimeProgress("Encerrando runtime", "Parando watchdog...", 15));
            await _supervisor.StopAsync();
            if (await _adb.IsDeviceOnlineAsync(cancellationToken))
            {
                try
                {
                    if (await _neoNews.GetStatusAsync(cancellationToken) is { Installed: true }) await _neoNews.StopAsync(cancellationToken);
                    if (_kiosk.IsActive) await _kiosk.ExitAsync(cancellationToken);
                }
                catch (Exception exception) { _logs.Warning("launcher", $"Limpeza do guest parcial: {exception.Message}"); }
            }
            progress?.Report(new RuntimeProgress("Parando Android", "Encerrando o Emulator...", 65));
            await _emulator.StopAsync(cancellationToken);
            _state.Set(RuntimeState.Stopped);
            await RefreshSnapshotAsync(cancellationToken);
            progress?.Report(new RuntimeProgress("Runtime parado", "Recursos liberados.", 100));
        });
    }

    public async Task RestartAndroidAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        await WithOperationAsync(RuntimeState.Recovering, async () =>
        {
            await _supervisor.StopAsync();
            await _emulator.RestartAsync(progress, cancellationToken);
            _state.Set(RuntimeState.WaitingForAdb);
            await _adb.WaitForBootAsync(progress, TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.BootSeconds)), cancellationToken);
            _state.Set(RuntimeState.Running);
            await _supervisor.StartAsync();
            await RefreshSnapshotAsync(cancellationToken);
        });
    }

    public async Task OpenNeoNewsAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        await WithOperationAsync(RuntimeState.StartingNeoNews, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            await _neoNews.StartAsync(progress, cancellationToken);
            if (_context.Config.Startup.AutoKiosk) await _kiosk.EnterAsync(progress, cancellationToken);
            await _supervisor.StartAsync();
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
        });
    }

    public async Task RestartNeoNewsAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        await WithOperationAsync(RuntimeState.StartingNeoNews, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            await _neoNews.RestartAsync(progress, cancellationToken);
            if (_context.Config.Startup.AutoKiosk) await _kiosk.EnterAsync(progress, cancellationToken);
            await _supervisor.StartAsync();
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
        });
    }

    public async Task InstallNeoNewsAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        await WithOperationAsync(RuntimeState.Preparing, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            progress?.Report(new RuntimeProgress("Atualizando NeoNews", "Instalando APK autorizado...", 75));
            await _neoNews.InstallAsync(cancellationToken);
            await RefreshSnapshotAsync(cancellationToken);
            progress?.Report(new RuntimeProgress("NeoNews atualizado", "Instalação concluída.", 100));
        });
    }

    public async Task EnterKioskAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        await WithOperationAsync(RuntimeState.EnteringKiosk, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            await _kiosk.EnterAsync(progress, cancellationToken);
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
        });
    }

    public async Task ExitKioskAsync(CancellationToken cancellationToken = default)
    {
        await WithOperationAsync(RuntimeState.Preparing, async () =>
        {
            if (!await _adb.IsDeviceOnlineAsync(cancellationToken)) throw new RuntimeOperationException("Android não está conectado.", "Não há serial ADB disponível para sair do kiosk.");
            await _kiosk.ExitAsync(cancellationToken);
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
        });
    }

    public async Task SetSupervisorAsync(bool enabled, CancellationToken cancellationToken = default)
    {
        await WithOperationAsync(RuntimeState.Preparing, async () =>
        {
            if (enabled) await _supervisor.StartAsync();
            else await _supervisor.StopAsync();
            await RefreshSnapshotAsync(cancellationToken);
        });
    }

    public async Task SetStartupAsync(bool enabled, CancellationToken cancellationToken = default)
    {
        await WithOperationAsync(RuntimeState.Preparing, async () =>
        {
            var executable = Environment.ProcessPath ?? throw new RuntimeOperationException("Executável não identificado.", "Environment.ProcessPath retornou nulo.");
            if (enabled)
            {
                await _startup.RegisterAsync(executable, cancellationToken);
                if (!await _startup.ValidateAsync(executable, cancellationToken))
                    throw new RuntimeOperationException("A tarefa de inicialização não foi validada.", $"A tarefa '{_context.Config.Startup.TaskName}' não aponta para '{executable} --autostart'.");
            }
            else await _startup.UnregisterAsync(cancellationToken);
            _context.Config.Startup.StartWithWindows = enabled;
            await _context.SaveAsync(cancellationToken);
            await RefreshSnapshotAsync(cancellationToken);
        });
    }

    public async Task<string> CollectDiagnosticsAsync(CancellationToken cancellationToken = default)
    {
        await _operationGate.WaitAsync(cancellationToken);
        try { return await _diagnostics.CollectAsync(cancellationToken); }
        finally { _operationGate.Release(); }
    }

    public async Task SaveConfigAsync(CancellationToken cancellationToken = default) => await _context.SaveAsync(cancellationToken);

    public Task<string> ReadLogsAsync(int maxLines = 200, CancellationToken cancellationToken = default) =>
        _logs.ReadTailAsync("launcher.log", maxLines, cancellationToken);

    public void OpenLogsFolder()
    {
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = _context.LogsDirectory,
            UseShellExecute = true
        });
    }

    public async Task ShutdownAsync(CancellationToken cancellationToken = default)
    {
        try { await _supervisor.StopAsync().ConfigureAwait(false); } catch { }
        try
        {
            if (_emulator.ProcessId is not null && await _adb.IsDeviceOnlineAsync(cancellationToken).ConfigureAwait(false))
            {
                if (await _neoNews.IsInstalledAsync(cancellationToken).ConfigureAwait(false)) await _neoNews.StopAsync(cancellationToken).ConfigureAwait(false);
                if (_kiosk.IsActive) await _kiosk.ExitAsync(cancellationToken).ConfigureAwait(false);
            }
        }
        catch { }
        try { await _emulator.StopAsync(cancellationToken).ConfigureAwait(false); } catch { }
    }

    private async Task EnsureAndroidAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        if (!await _adb.IsDeviceOnlineAsync(cancellationToken))
        {
            await _emulator.StartAsync(progress, cancellationToken);
            _state.Set(RuntimeState.WaitingForAdb);
        }
        await _adb.WaitForBootAsync(progress, TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.BootSeconds)), cancellationToken);
        await _supervisor.StartAsync();
    }

    private async Task WithOperationAsync(RuntimeState state, Func<Task> operation)
    {
        await _operationGate.WaitAsync();
        try
        {
            _state.Set(state);
            await operation();
        }
        catch (Exception exception)
        {
            _state.Set(RuntimeState.Error);
            _logs.Error("launcher", "Operação do runtime falhou.", exception);
            throw;
        }
        finally
        {
            _operationGate.Release();
        }
    }

    private async Task<string> SafeAsync(Func<Task<string>> operation, CancellationToken cancellationToken)
    {
        try { return await operation(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) { _logs.Warning("launcher", exception.Message); return string.Empty; }
    }

    public async ValueTask DisposeAsync()
    {
        await ShutdownAsync().ConfigureAwait(false);
        await _supervisor.DisposeAsync().ConfigureAwait(false);
        await _emulator.DisposeAsync().ConfigureAwait(false);
        _operationGate.Dispose();
    }
}
