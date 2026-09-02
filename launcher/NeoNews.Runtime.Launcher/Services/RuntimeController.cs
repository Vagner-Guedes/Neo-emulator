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
    private readonly IAndroidRuntimeBackend _backend;
    private readonly AndroidProvisioningService _provisioning;
    private readonly NativeBridgeValidationService _nativeBridge;
    private readonly NeoNewsService _neoNews;
    private readonly KioskService _kiosk;
    private readonly StartupService _startup;
    private readonly WatchdogService _supervisor;
    private readonly DiagnosticsService _diagnostics;
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private readonly RuntimeStateService _state = new();
    private AbiCompatibilityResult? _lastAbiCompatibility;

    public RuntimeController(RuntimeContext context)
    {
        _context = context;
        _logs = new LogService(context);
        _runner = new ProcessRunnerService(_logs);
        _scripts = new ScriptExecutionService(context, _runner);
        _adb = new AdbService(context, _runner, _logs);
        _backend = context.Config.Android.Backend.Equals("android-sdk-emulator", StringComparison.OrdinalIgnoreCase)
            ? new EmulatorService(context, _runner, _logs, _adb)
            : new QemuAndroidRuntimeBackend(context, _runner, _logs);
        _provisioning = new AndroidProvisioningService(context, _logs);
        _nativeBridge = new NativeBridgeValidationService(context, _adb);
        _neoNews = new NeoNewsService(context, _adb);
        _kiosk = new KioskService(context, _adb, _backend);
        _startup = new StartupService(context, _runner);
        _supervisor = new WatchdogService(context, _neoNews, _adb, _backend, _logs);
        _diagnostics = new DiagnosticsService(context, _adb, _backend, _neoNews, _supervisor, _startup, _logs, () => _lastAbiCompatibility);
        _state.Changed += (_, state) => StateChanged?.Invoke(this, state);
        Snapshot = new RuntimeSnapshot(RuntimeState.Stopped, "Offline", "Não verificado", "Pendente", "Não instalado", "Inativo", "Não verificado", "Offline", false, false, false);
    }

    public RuntimeContext Context => _context;
    public LogService Logs => _logs;
    public ScriptExecutionService Scripts => _scripts;
    public string BackendName => _backend.Name;
    public int? BackendProcessId => _backend.ProcessId;
    public RuntimeState State => _state.Current;
    public bool IsKioskActive => _kiosk.IsActive;
    public bool IsSupervisorActive => _supervisor.IsActive;
    public RuntimeSnapshot Snapshot { get; private set; }
    public event EventHandler<RuntimeState>? StateChanged;
    public event EventHandler<RuntimeSnapshot>? SnapshotChanged;

    public async Task<RuntimeSnapshot> RefreshSnapshotAsync(CancellationToken cancellationToken = default)
    {
        var backendRunning = await SafeBoolAsync(() => _backend.IsRunningAsync(cancellationToken), cancellationToken);
        var adbOnline = await SafeBoolAsync(() => _adb.IsDeviceOnlineAsync(cancellationToken), cancellationToken);
        var booted = adbOnline && await SafeAsync(() => _adb.GetPropertyAsync("sys.boot_completed", cancellationToken), cancellationToken) == "1";
        var packageInstalled = false;
        var neoRunning = false;
        var neoLabel = "Não instalado";
        var nativeBridgeState = NativeBridgeState.Unknown;
        var androidState = !backendRunning ? AndroidGuestState.Offline : !booted ? AndroidGuestState.Booting : AndroidGuestState.Online;

        if (booted)
        {
            var bridge = await SafeNativeBridgeAsync(cancellationToken);
            if (bridge is not null) nativeBridgeState = bridge.Ready ? NativeBridgeState.Ready : NativeBridgeState.Unavailable;
            var neoStatus = await SafeNeoNewsAsync(cancellationToken);
            if (neoStatus is not null)
            {
                packageInstalled = neoStatus.Installed;
                neoRunning = neoStatus.Running;
                neoLabel = neoStatus.Installed ? (neoStatus.Running ? "Em execução" : $"Instalado {neoStatus.Version}") : "Não instalado";
            }
        }

        var webViewLabel = "Pendente";
        var webViewState = WebViewRuntimeState.Unknown;
        if (booted)
        {
            var webView = await ReadWebViewAsync(cancellationToken);
            webViewLabel = webView.Label;
            webViewState = webView.Ready ? WebViewRuntimeState.Ready : WebViewRuntimeState.Mismatch;
        }

        var voiceLabel = "Não instalado";
        var ttsState = TtsRuntimeState.Unknown;
        if (booted)
        {
            var packages = await SafeAsync(() => _adb.GetPackagesAsync(cancellationToken), cancellationToken);
            var defaultEngine = await SafeAsync(() => _adb.GetTtsDefaultAsync(cancellationToken), cancellationToken);
            var hasRhvoice = packages.Contains("rhvoice", StringComparison.OrdinalIgnoreCase);
            var selected = defaultEngine.Contains("rhvoice", StringComparison.OrdinalIgnoreCase);
            voiceLabel = hasRhvoice ? (selected ? "RHVoice ativa" : "RHVoice instalada") : "RHVoice ausente";
            ttsState = hasRhvoice && selected ? TtsRuntimeState.Ready : TtsRuntimeState.Missing;
        }

        var startupRegistered = await _startup.IsRegisteredAsync(cancellationToken);
        var startupValid = startupRegistered && await _startup.ValidateAsync(Environment.ProcessPath ?? string.Empty, cancellationToken);
        var adbState = _adb.State;
        Snapshot = new RuntimeSnapshot(
            State,
            androidState switch { AndroidGuestState.Online => "Online", AndroidGuestState.Booting => "Iniciando", _ => "Offline" },
            neoLabel,
            webViewLabel,
            voiceLabel,
            _supervisor.IsActive ? "Ativo" : "Inativo",
            startupValid ? "Ativo" : "Inativo",
            adbState is AdbRuntimeState.Ready or AdbRuntimeState.Device ? "Online" : "Offline",
            backendRunning,
            packageInstalled,
            neoRunning)
        {
            AndroidState = androidState,
            AdbState = adbState,
            NativeBridge = nativeBridgeState,
            NeoNewsState = !packageInstalled ? NeoNewsRuntimeState.NotInstalled : neoRunning ? NeoNewsRuntimeState.Running : NeoNewsRuntimeState.Installed,
            WebViewState = webViewState,
            TtsState = ttsState,
            KioskActive = _kiosk.IsActive
        };
        SnapshotChanged?.Invoke(this, Snapshot);
        return Snapshot;
    }

    public Task StartSystemAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) =>
        WithOperationAsync(RuntimeState.Starting, () => StartSystemCoreAsync(progress, cancellationToken));

    public Task StartAndroidAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) =>
        WithOperationAsync(RuntimeState.Starting, async () =>
        {
            try
            {
                progress?.Report(new RuntimeProgress("Preparando ambiente", "Validando componentes locais...", 5));
                await _provisioning.ValidateLocalRuntimeAsync(cancellationToken);
                await _backend.StartAsync(progress, cancellationToken);
                _state.Set(RuntimeState.WaitingForAdb);
                await _adb.WaitForBootAsync(progress, TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.BootSeconds)), cancellationToken);
                _state.Set(RuntimeState.Running);
                await RefreshSnapshotAsync(cancellationToken);
                progress?.Report(new RuntimeProgress("Android online", "O guest está pronto.", 100));
            }
            catch
            {
                await CleanupFailedStartAsync();
                throw;
            }
        });

    public Task StartNeoNewsAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) => StartSystemAsync(progress, cancellationToken);

    public Task StopSystemAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) =>
        WithOperationAsync(RuntimeState.Stopping, () => StopSystemCoreAsync(progress, cancellationToken));

    public Task StopAndroidAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) => StopSystemAsync(progress, cancellationToken);

    public Task RestartSystemAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) =>
        WithOperationAsync(RuntimeState.Recovering, async () =>
        {
            await StopSystemCoreAsync(progress, cancellationToken, setStopped: false);
            await StartSystemCoreAsync(progress, cancellationToken);
        });

    public Task RestartAndroidAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) => RestartSystemAsync(progress, cancellationToken);

    public Task OpenNeoNewsAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) =>
        WithOperationAsync(RuntimeState.StartingNeoNews, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            await _neoNews.StartAsync(progress, cancellationToken);
            if (_context.Config.Startup.AutoKiosk) await _kiosk.EnterAsync(progress, cancellationToken);
            await _supervisor.StartAsync();
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
        });

    public Task RestartNeoNewsAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) =>
        WithOperationAsync(RuntimeState.StartingNeoNews, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            await _neoNews.RestartAsync(progress, cancellationToken);
            if (_context.Config.Startup.AutoKiosk) await _kiosk.EnterAsync(progress, cancellationToken);
            await _supervisor.StartAsync();
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
        });

    public Task InstallNeoNewsAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) =>
        WithOperationAsync(RuntimeState.Preparing, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            progress?.Report(new RuntimeProgress("Atualizando NeoNews", "Instalando APK autorizado sem apagar dados...", 75));
            await _neoNews.InstallAsync(cancellationToken);
            await RefreshSnapshotAsync(cancellationToken);
            progress?.Report(new RuntimeProgress("NeoNews atualizado", "Instalação concluída.", 100));
        });

    public Task EnterKioskAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) =>
        WithOperationAsync(RuntimeState.EnteringKiosk, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            await _kiosk.EnterAsync(progress, cancellationToken);
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
        });

    public Task ExitKioskAsync(CancellationToken cancellationToken = default) =>
        WithOperationAsync(RuntimeState.Preparing, async () =>
        {
            if (!await _adb.IsDeviceOnlineAsync(cancellationToken)) throw new RuntimeOperationException("Android não está conectado.", $"Não há transporte ADB disponível para sair do kiosk: {_adb.Serial}.");
            await _kiosk.ExitAsync(cancellationToken);
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
        });

    public Task SetSupervisorAsync(bool enabled, CancellationToken cancellationToken = default) =>
        WithOperationAsync(RuntimeState.Preparing, async () =>
        {
            if (enabled) await _supervisor.StartAsync(); else await _supervisor.StopAsync();
            await RefreshSnapshotAsync(cancellationToken);
        });

    public Task SetStartupAsync(bool enabled, CancellationToken cancellationToken = default) =>
        WithOperationAsync(RuntimeState.Preparing, async () =>
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

    public async Task<string> CollectDiagnosticsAsync(CancellationToken cancellationToken = default)
    {
        await _operationGate.WaitAsync(cancellationToken);
        try { return await _diagnostics.CollectAsync(cancellationToken); }
        finally { _operationGate.Release(); }
    }

    public Task SaveConfigAsync(CancellationToken cancellationToken = default) => _context.SaveAsync(cancellationToken);

    public Task<string> ReadLogsAsync(int maxLines = 200, CancellationToken cancellationToken = default) => _logs.ReadTailAsync("launcher.log", maxLines, cancellationToken);

    public void OpenLogsFolder() => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo { FileName = _context.LogsDirectory, UseShellExecute = true });

    public async Task ShutdownAsync(CancellationToken cancellationToken = default)
    {
        try { await _supervisor.StopAsync().ConfigureAwait(false); } catch { }
        try { if (await _adb.IsDeviceOnlineAsync(cancellationToken) && await _neoNews.IsInstalledAsync(cancellationToken)) await _neoNews.StopAsync(cancellationToken).ConfigureAwait(false); } catch { }
        try { if (_kiosk.IsActive && await _adb.IsDeviceOnlineAsync(cancellationToken)) await _kiosk.ExitAsync(cancellationToken).ConfigureAwait(false); } catch { }
        try { await _backend.StopAsync(cancellationToken).ConfigureAwait(false); } catch { }
        try { await _adb.DisconnectAsync(cancellationToken).ConfigureAwait(false); } catch { }
    }

    private async Task StartSystemCoreAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        try
        {
            _lastAbiCompatibility = null;
            progress?.Report(new RuntimeProgress("Preparando ambiente", "Validando componentes locais...", 5));
            await _provisioning.ValidateLocalRuntimeAsync(cancellationToken);
            await _backend.StartAsync(progress, cancellationToken);
            _state.Set(RuntimeState.WaitingForAdb);
            progress?.Report(new RuntimeProgress("Aguardando ADB", $"Conectando a {_adb.Serial}...", 35));
            await _adb.WaitForBootAsync(progress, TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.BootSeconds)), cancellationToken);
            var bridge = await _nativeBridge.ValidateGuestAsync(cancellationToken);
            if (_context.Config.Android.NativeBridge.Required && !bridge.Ready) throw new RuntimeOperationException("O Native Bridge ARM não está disponível.", bridge.Detail);
            var webView = await ReadWebViewAsync(cancellationToken);
            if (_context.Config.Android.Provisioning.RequireWebView && !webView.Ready) throw new RuntimeOperationException("O WebView homologado não está disponível.", webView.Detail);
            var tts = await ValidateTtsAsync(cancellationToken);
            if (_context.Config.Android.Provisioning.RequireTts && !tts.Ready) throw new RuntimeOperationException("A voz RHVoice pt-BR não está disponível.", tts.Detail);
            _state.Set(RuntimeState.StartingNeoNews);
            await _neoNews.StartAsync(progress, cancellationToken);
            _lastAbiCompatibility = await _nativeBridge.ValidateInstalledPackageAsync(_neoNews.PackageName, _neoNews.ActivityName, ResolveApkAbis(), true, cancellationToken);
            if (_context.Config.Android.NativeBridge.Required && !_lastAbiCompatibility.RuntimeStable) throw new RuntimeOperationException("O NeoNews não permaneceu estável com a ABI ARM.", $"primaryCpuAbi={_lastAbiCompatibility.PrimaryCpuAbi}; selectedApkAbi={_lastAbiCompatibility.SelectedApkAbi}; runtimeStable=false");
            if (_context.Config.Startup.AutoKiosk) { _state.Set(RuntimeState.EnteringKiosk); await _kiosk.EnterAsync(progress, cancellationToken); }
            await _supervisor.StartAsync();
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
            progress?.Report(new RuntimeProgress("Sistema pronto", "QEMU, Android, NeoNews, kiosk e watchdog ativos.", 100));
        }
        catch
        {
            await CleanupFailedStartAsync();
            throw;
        }
    }

    private async Task CleanupFailedStartAsync()
    {
        try { await _supervisor.StopAsync(); } catch { }
        try
        {
            if (await SafeBoolAsync(() => _adb.IsDeviceOnlineAsync(CancellationToken.None), CancellationToken.None))
            {
                if (await _neoNews.IsInstalledAsync(CancellationToken.None)) await _neoNews.StopAsync(CancellationToken.None);
                if (_kiosk.IsActive) await _kiosk.ExitAsync(CancellationToken.None);
            }
        }
        catch { }
        try { await _backend.StopAsync(CancellationToken.None); } catch { }
        try { await _adb.DisconnectAsync(CancellationToken.None); } catch { }
    }

    private async Task StopSystemCoreAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken, bool setStopped = true)
    {
        progress?.Report(new RuntimeProgress("Encerrando sistema", "Parando watchdog...", 15));
        await _supervisor.StopAsync();
        if (await SafeBoolAsync(() => _adb.IsDeviceOnlineAsync(cancellationToken), cancellationToken))
        {
            try { if (await _neoNews.IsInstalledAsync(cancellationToken)) await _neoNews.StopAsync(cancellationToken); } catch (Exception exception) { _logs.Warning("launcher", $"Falha ao parar NeoNews: {exception.Message}"); }
            try { if (_kiosk.IsActive) await _kiosk.ExitAsync(cancellationToken); } catch (Exception exception) { _logs.Warning("launcher", $"Falha ao sair do kiosk: {exception.Message}"); }
        }
        progress?.Report(new RuntimeProgress("Parando Android", $"Encerrando {_backend.Name}...", 65));
        await _backend.StopAsync(cancellationToken);
        await _adb.DisconnectAsync(cancellationToken);
        if (setStopped) _state.Set(RuntimeState.Stopped);
        await RefreshSnapshotAsync(cancellationToken);
        progress?.Report(new RuntimeProgress("Sistema parado", "Disco persistente e dados preservados.", 100));
    }

    private async Task EnsureAndroidAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        if (!await _backend.IsRunningAsync(cancellationToken))
        {
            await _provisioning.ValidateLocalRuntimeAsync(cancellationToken);
            await _backend.StartAsync(progress, cancellationToken);
            _state.Set(RuntimeState.WaitingForAdb);
        }
        await _adb.WaitForBootAsync(progress, TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.BootSeconds)), cancellationToken);
        await _supervisor.StartAsync();
    }

    private IReadOnlyList<string> ResolveApkAbis()
    {
        var path = _context.ResolveApkPath();
        if (!File.Exists(path)) return _context.Config.NeoNews.SupportedApkAbis;
        try { return NativeBridgeValidationService.ReadApkAbis(path); }
        catch (Exception exception) { _logs.Warning("launcher", $"Não foi possível extrair ABIs do APK local: {exception.Message}"); return _context.Config.NeoNews.SupportedApkAbis; }
    }

    private async Task<(bool Ready, string Label, string Detail)> ReadWebViewAsync(CancellationToken cancellationToken)
    {
        var providerDump = await SafeAsync(() => _adb.GetWebViewDumpAsync(cancellationToken), cancellationToken);
        var packageDump = await SafeAsync(() => _adb.GetPackageDumpAsync(_context.Config.WebView.Provider, cancellationToken), cancellationToken);
        var match = Regex.Match(packageDump, @"versionName=([^\s]+)");
        var version = match.Success ? match.Groups[1].Value : string.Empty;
        var providerReady = providerDump.Contains(_context.Config.WebView.Provider, StringComparison.OrdinalIgnoreCase);
        var ready = providerReady && version.Equals(_context.Config.WebView.HomologatedVersion, StringComparison.OrdinalIgnoreCase);
        var label = string.IsNullOrWhiteSpace(version) ? "Não encontrado" : ready ? "Validado" : $"Divergente ({version})";
        return (ready, label, $"providerAtivo={providerReady}; provider={_context.Config.WebView.Provider}; versão={version}; esperada={_context.Config.WebView.HomologatedVersion}");
    }

    private async Task<(bool Ready, string Detail)> ValidateTtsAsync(CancellationToken cancellationToken)
    {
        var packages = await SafeAsync(() => _adb.GetPackagesAsync(cancellationToken), cancellationToken);
        var defaultEngine = await SafeAsync(() => _adb.GetTtsDefaultAsync(cancellationToken), cancellationToken);
        var packageReady = packages.Contains("rhvoice", StringComparison.OrdinalIgnoreCase);
        var selected = defaultEngine.Contains("rhvoice", StringComparison.OrdinalIgnoreCase);
        return (packageReady && selected, $"engineEsperada={_context.Config.Tts.Engine}; default={defaultEngine}; locale={_context.Config.Tts.Locale}; pacoteRhvoice={packageReady}; engineSelecionada={selected}");
    }

    private async Task<NativeBridgeValidationResult?> SafeNativeBridgeAsync(CancellationToken cancellationToken)
    {
        try { return await _nativeBridge.ValidateGuestAsync(cancellationToken); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) { _logs.Warning("launcher", $"Native Bridge não pôde ser consultado: {exception.Message}"); return null; }
    }

    private async Task<NeoNewsStatus?> SafeNeoNewsAsync(CancellationToken cancellationToken)
    {
        try { return await _neoNews.GetStatusAsync(cancellationToken); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) { _logs.Warning("launcher", $"NeoNews não pôde ser consultado: {exception.Message}"); return null; }
    }

    private async Task<bool> SafeBoolAsync(Func<Task<bool>> operation, CancellationToken cancellationToken)
    {
        try { return await operation(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) { _logs.Warning("launcher", exception.Message); return false; }
    }

    private async Task<string> SafeAsync(Func<Task<string>> operation, CancellationToken cancellationToken)
    {
        try { return await operation(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) { _logs.Warning("launcher", exception.Message); return string.Empty; }
    }

    private async Task WithOperationAsync(RuntimeState state, Func<Task> operation)
    {
        await _operationGate.WaitAsync();
        try { _state.Set(state); await operation(); }
        catch (Exception exception) { _state.Set(RuntimeState.Error); _logs.Error("launcher", "Operação do runtime falhou.", exception); throw; }
        finally { _operationGate.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        await ShutdownAsync().ConfigureAwait(false);
        await _supervisor.DisposeAsync().ConfigureAwait(false);
        await _backend.DisposeAsync().ConfigureAwait(false);
        _operationGate.Dispose();
    }
}
