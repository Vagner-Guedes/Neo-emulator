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
    private readonly GuestConfigurationService _guestConfiguration;
    private readonly NeoNewsService _neoNews;
    private readonly KioskService _kiosk;
    private readonly StartupService _startup;
    private readonly RuntimeIntentService _intent;
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
        _backend = context.Config.Android.Backend.ToLowerInvariant() switch
        {
            "android-sdk-emulator" => new EmulatorService(context, _runner, _logs, _adb),
            "qemu-android-x86" => new QemuAndroidRuntimeBackend(context, _runner, _logs),
            _ => throw new RuntimeOperationException(
                "O backend Android configurado não é suportado.",
                $"Backend recebido: '{context.Config.Android.Backend}'. Valores aceitos: qemu-android-x86 ou android-sdk-emulator.")
        };
        _provisioning = new AndroidProvisioningService(context, _runner, _logs);
        _nativeBridge = new NativeBridgeValidationService(context, _adb);
        _guestConfiguration = new GuestConfigurationService(context, _adb, _logs);
        _neoNews = new NeoNewsService(context, _adb);
        _kiosk = new KioskService(context, _adb, _backend);
        _startup = new StartupService(context, _runner);
        _intent = new RuntimeIntentService(context);
        _supervisor = new WatchdogService(context, _neoNews, _adb, _backend, _nativeBridge, _kiosk, _intent, _logs);
        _diagnostics = new DiagnosticsService(context, _adb, _backend, _runner, _neoNews, _supervisor, _startup, _logs, () => _lastAbiCompatibility);
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
    public RuntimeIntentRecord Intent => _intent.Current;
    public RuntimeSnapshot Snapshot { get; private set; }
    public event EventHandler<RuntimeState>? StateChanged;
    public event EventHandler<RuntimeSnapshot>? SnapshotChanged;

    public async Task<RuntimeSnapshot> RefreshSnapshotAsync(CancellationToken cancellationToken = default)
    {
        var backendRunning = await SafeBoolAsync(() => _backend.IsRunningAsync(cancellationToken), cancellationToken);
        // Do not let a passive panel refresh auto-start an unowned ADB daemon
        // while the backend is offline. The normal start path owns the
        // configured private server before launching QEMU.
        var adbOnline = backendRunning && await SafeBoolAsync(() => _adb.IsDeviceOnlineAsync(cancellationToken), cancellationToken);
        var booted = adbOnline && await SafeAsync(() => _adb.GetPropertyAsync("sys.boot_completed", cancellationToken), cancellationToken) == "1";
        var packageInstalled = false;
        var neoRunning = false;
        var neoLabel = "Não instalado";
        var nativeBridgeState = NativeBridgeState.Unknown;
        var androidState = !backendRunning ? AndroidGuestState.Offline : !booted ? AndroidGuestState.Booting : AndroidGuestState.Online;

        if (booted)
        {
            var bridge = await SafeNativeBridgeAsync(cancellationToken);
            if (bridge is not null)
            {
                nativeBridgeState = _supervisor.HasNativeBridgeStructuralError
                    ? NativeBridgeState.Error
                    : !bridge.Ready ? bridge.State
                    : _lastAbiCompatibility?.RuntimeStable == true ? NativeBridgeState.Ready
                    : NativeBridgeState.Configured;
            }
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
            var localeCheck = await SafeAsync(() => _adb.CheckTtsDataAsync("por", "BRA", cancellationToken), cancellationToken);
            var ttsData = await ReadTtsVoiceDataAsync(cancellationToken);
            var providerPackage = string.IsNullOrWhiteSpace(_context.Config.Tts.ProviderPackage)
                ? "com.github.olga_yakovleva.rhvoice.android"
                : _context.Config.Tts.ProviderPackage;
            var hasRhvoice = packages.Contains(providerPackage, StringComparison.OrdinalIgnoreCase);
            var selected = defaultEngine.Contains("rhvoice", StringComparison.OrdinalIgnoreCase);
            var legacyLocaleReady = localeCheck.Contains("result=1", StringComparison.OrdinalIgnoreCase) || localeCheck.Contains("CHECK_TTS_DATA_PASS", StringComparison.OrdinalIgnoreCase) || localeCheck.Contains("CHECK_VOICE_DATA_PASS", StringComparison.OrdinalIgnoreCase);
            var localeReady = legacyLocaleReady || ttsData.Ready;
            voiceLabel = hasRhvoice ? (selected && localeReady ? "RHVoice ativa" : "RHVoice instalada") : "RHVoice ausente";
            ttsState = hasRhvoice && selected && localeReady ? TtsRuntimeState.Ready : TtsRuntimeState.Missing;
        }

        var startupRegistered = await _startup.IsRegisteredAsync(cancellationToken);
        var startupValid = startupRegistered && await _startup.ValidateAsync(Environment.ProcessPath ?? string.Empty, cancellationToken);
        var adbState = _adb.State;
        var internetState = InternetRuntimeState.Unknown;
        if (booted)
        {
            var routeTable = await SafeAsync(() => _adb.ShellAsync(["ip", "route"], cancellationToken: cancellationToken), cancellationToken);
            internetState = routeTable.Contains("default", StringComparison.OrdinalIgnoreCase)
                ? InternetRuntimeState.Online
                : InternetRuntimeState.Offline;
        }
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
            WatchdogState = _supervisor.IsActive ? WatchdogRuntimeState.Active : WatchdogRuntimeState.Inactive,
            StartupState = startupValid ? StartupRuntimeState.Active : StartupRuntimeState.Inactive,
            InternetState = internetState,
            KioskActive = _kiosk.IsActive
        };
        SnapshotChanged?.Invoke(this, Snapshot);
        return Snapshot;
    }

    public Task StartSystemAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        _intent.ClearUserStop();
        return WithOperationAsync(RuntimeState.Starting, () => StartSystemCoreAsync(progress, cancellationToken));
    }

    public Task StartAndroidAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        _intent.ClearUserStop();
        return WithOperationAsync(RuntimeState.Starting, async () =>
        {
            try
            {
                progress?.Report(new RuntimeProgress("Preparando ambiente", "Validando componentes locais...", 5));
                await _provisioning.ValidateLocalRuntimeAsync(cancellationToken);
                await _provisioning.SetStageAsync("HOST_VALIDATION", cancellationToken);
                await _adb.StartServerAsync(cancellationToken);
                await _backend.StartAsync(progress, cancellationToken);
                await _provisioning.SetStageAsync("ANDROID_START", cancellationToken);
                _state.Set(RuntimeState.WaitingForAdb);
                await WaitForConfiguredBootAsync(progress, cancellationToken);
                await _provisioning.SetStageAsync("BOOT_COMPLETED", cancellationToken);
                await _provisioning.SetStageAsync("PACKAGE_MANAGER_READY", cancellationToken);
                await _provisioning.SetStageAsync("SETTINGS_PROVIDER_READY", cancellationToken);
                await EnsureGuestIdentityAsync(cancellationToken);
                await EnsureGuestLocaleAsync(progress, cancellationToken);
                await EnsureGuestClockAsync(progress, cancellationToken);
                await EnsureGuestConfigurationAsync(progress, requireNeoNewsSuperuser: false, cancellationToken: cancellationToken);
                _state.Set(RuntimeState.Running);
                await _provisioning.SetStageAsync("AndroidReady", cancellationToken);
                await RefreshSnapshotAsync(cancellationToken);
                progress?.Report(new RuntimeProgress("Android online", "O guest está pronto.", 100));
            }
            catch (Exception exception)
            {
                try { await _provisioning.SetErrorAsync(exception, CancellationToken.None); } catch { }
                await CleanupFailedStartAsync();
                throw;
            }
        });
    }

    public Task StartNeoNewsAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) => StartSystemAsync(progress, cancellationToken);

    public async Task StartAutostartAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        if (_intent.IsRecoverySuppressed)
        {
            _logs.Info("intent", "Autostart ignorado: USER_STOPPED_RUNTIME permanece ativo; Guardian em silêncio.");
            _state.Set(RuntimeState.Stopped);
            await RefreshSnapshotAsync(cancellationToken);
            return;
        }

        if (_context.Config.Startup.StartNeoNews)
        {
            await StartSystemAsync(progress, cancellationToken);
            return;
        }

        await StartAndroidAsync(progress, cancellationToken);
        try
        {
            if (_context.Config.Startup.AutoKiosk)
            {
                await EnterKioskAsync(progress, cancellationToken);
            }
            await StartSupervisorIfEnabledAsync();
            await RefreshSnapshotAsync(cancellationToken);
        }
        catch
        {
            await CleanupFailedStartAsync();
            throw;
        }
    }

    public Task StopSystemAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        _intent.MarkUserStopped();
        return WithOperationAsync(RuntimeState.Stopping, () => StopSystemCoreAsync(progress, cancellationToken));
    }

    public Task StopAndroidAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) => StopSystemAsync(progress, cancellationToken);

    public Task RestartSystemAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        _intent.ClearUserStop();
        return WithOperationAsync(RuntimeState.Recovering, async () =>
        {
            await StopSystemCoreAsync(progress, cancellationToken, setStopped: false);
            await StartSystemCoreAsync(progress, cancellationToken);
        });
    }

    public Task RestartAndroidAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken) => RestartSystemAsync(progress, cancellationToken);

    public Task OpenNeoNewsAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        _intent.ClearUserStop();
        return WithOperationAsync(RuntimeState.StartingNeoNews, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            await _neoNews.EnsureInstalledAsync(progress, cancellationToken);
            await EnsureGuestConfigurationAsync(progress, requireNeoNewsSuperuser: true, cancellationToken: cancellationToken);
            await _neoNews.LaunchAsync(progress, cancellationToken);
            if (_context.Config.Startup.AutoKiosk) await _kiosk.EnterAsync(progress, cancellationToken);
            await StartSupervisorIfEnabledAsync();
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
        });
    }

    public Task RestartNeoNewsAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        _intent.ClearUserStop();
        return WithOperationAsync(RuntimeState.StartingNeoNews, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            await _neoNews.StopAsync(cancellationToken);
            await _neoNews.EnsureInstalledAsync(progress, cancellationToken);
            await EnsureGuestConfigurationAsync(progress, requireNeoNewsSuperuser: true, cancellationToken: cancellationToken);
            await _neoNews.LaunchAsync(progress, cancellationToken);
            if (_context.Config.Startup.AutoKiosk) await _kiosk.EnterAsync(progress, cancellationToken);
            await StartSupervisorIfEnabledAsync();
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
        });
    }

    public Task InstallNeoNewsAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        _intent.ClearUserStop();
        return WithOperationAsync(RuntimeState.Preparing, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            _lastAbiCompatibility = null;
            progress?.Report(new RuntimeProgress("Atualizando NeoNews", "Instalando APK autorizado sem apagar dados...", 75));
            await _neoNews.InstallAsync(cancellationToken);
            await EnsureGuestConfigurationAsync(progress, requireNeoNewsSuperuser: true, cancellationToken: cancellationToken);
            var bridge = await SafeNativeBridgeAsync(cancellationToken);
            if (bridge is not null)
            {
                _lastAbiCompatibility = await _nativeBridge.ValidateInstalledPackageAsync(
                    _neoNews.PackageName,
                    _neoNews.ActivityName,
                    ResolveApkAbis(),
                    _neoNews.LastInstallSucceeded,
                    cancellationToken);
            }
            await RefreshSnapshotAsync(cancellationToken);
            progress?.Report(new RuntimeProgress("NeoNews atualizado", "Instalação concluída.", 100));
        });
    }

    public Task EnterKioskAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        _intent.ClearUserStop();
        return WithOperationAsync(RuntimeState.EnteringKiosk, async () =>
        {
            await EnsureAndroidAsync(progress, cancellationToken);
            await _kiosk.EnterAsync(progress, cancellationToken);
            _state.Set(RuntimeState.Running);
            await RefreshSnapshotAsync(cancellationToken);
        });
    }

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
            _context.Config.Supervisor.RestartOnActivityLoss = enabled;
            await _context.SaveAsync(cancellationToken);
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
        _logs.Info("launcher", "Diagnóstico aguardando o lock de operações.");
        await _operationGate.WaitAsync(cancellationToken);
        _logs.Info("launcher", "Diagnóstico adquiriu o lock de operações.");
        try { return await _diagnostics.CollectAsync(cancellationToken); }
        finally
        {
            _operationGate.Release();
            _logs.Info("launcher", "Diagnóstico liberou o lock de operações.");
        }
    }

    public Task SaveConfigAsync(CancellationToken cancellationToken = default) => _context.SaveAsync(cancellationToken);

    public Task<string> ReadLogsAsync(int maxLines = 200, CancellationToken cancellationToken = default) => _logs.ReadTailAsync("launcher.log", maxLines, cancellationToken);

    public void OpenLogsFolder() => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo { FileName = _context.LogsDirectory, UseShellExecute = true });

    public async Task ShutdownAsync(CancellationToken cancellationToken = default)
    {
        try { await _supervisor.StopAsync().ConfigureAwait(false); } catch { }
        var backendRunning = false;
        try { backendRunning = await _backend.IsRunningAsync(cancellationToken).ConfigureAwait(false); } catch { }
        // A plain --exit on an already stopped runtime must not start a new
        // private ADB server merely to ask whether the guest is online.
        // Consult the guest only when this controller owns a live backend and
        // an ADB server is already running.
        var guestQueryable = backendRunning && _adb.IsServerRunning;
        if (guestQueryable)
        {
            try { if (await _adb.IsDeviceOnlineAsync(cancellationToken) && await _neoNews.IsInstalledAsync(cancellationToken)) await _neoNews.StopAsync(cancellationToken).ConfigureAwait(false); } catch { }
            try { if (_kiosk.IsActive && await _adb.IsDeviceOnlineAsync(cancellationToken)) await _kiosk.ExitAsync(cancellationToken).ConfigureAwait(false); } catch { }
        }
        try { await _backend.StopAsync(cancellationToken).ConfigureAwait(false); } catch { }
        if (guestQueryable)
        {
            try { await _adb.DisconnectAsync(cancellationToken).ConfigureAwait(false); } catch { }
        }
        try { await _adb.StopServerAsync(cancellationToken).ConfigureAwait(false); } catch { }
    }

    private async Task StartSystemCoreAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        try
        {
            _lastAbiCompatibility = null;
            progress?.Report(new RuntimeProgress("Preparando ambiente", "Validando componentes locais...", 5));
            await _provisioning.ValidateLocalRuntimeAsync(cancellationToken);
            await _provisioning.SetStageAsync("HOST_VALIDATION", cancellationToken);
            await _adb.StartServerAsync(cancellationToken);
            await _backend.StartAsync(progress, cancellationToken);
            await _provisioning.SetStageAsync("ANDROID_START", cancellationToken);
            _state.Set(RuntimeState.WaitingForAdb);
            progress?.Report(new RuntimeProgress("Aguardando ADB", $"Conectando a {_adb.Serial}...", 35));
            await WaitForConfiguredBootAsync(progress, cancellationToken);
            await _provisioning.SetStageAsync("BOOT_COMPLETED", cancellationToken);
            await _provisioning.SetStageAsync("PACKAGE_MANAGER_READY", cancellationToken);
            await _provisioning.SetStageAsync("SETTINGS_PROVIDER_READY", cancellationToken);
            await EnsureGuestIdentityAsync(cancellationToken);
            await EnsureGuestLocaleAsync(progress, cancellationToken);
            await EnsureGuestClockAsync(progress, cancellationToken);
            await _provisioning.SetStageAsync("NATIVE_BRIDGE_VALIDATION", cancellationToken);
            var bridge = await EnsureNativeBridgeAsync(progress, cancellationToken);
            if (_context.Config.Android.NativeBridge.Required && !bridge.Ready) throw new RuntimeOperationException("O Native Bridge ARM não está disponível.", bridge.Detail);
            await _provisioning.SetStageAsync("WEBVIEW_VALIDATION", cancellationToken);
            var webView = await ReadWebViewAsync(cancellationToken);
            if (_context.Config.Android.Provisioning.RequireWebView && !webView.Ready) throw new RuntimeOperationException("O WebView homologado não está disponível.", webView.Detail);
            await _provisioning.SetStageAsync("TTS_VALIDATION", cancellationToken);
            var tts = await ValidateTtsAsync(cancellationToken);
            if (_context.Config.Android.Provisioning.RequireTts && !tts.Ready) throw new RuntimeOperationException("A voz RHVoice pt-BR não está disponível.", tts.Detail);
            await _provisioning.SetStageAsync("NEONEWS_INSTALLATION", cancellationToken);
            _state.Set(RuntimeState.StartingNeoNews);
            await _neoNews.EnsureInstalledAsync(progress, cancellationToken);
            await EnsureGuestConfigurationAsync(progress, requireNeoNewsSuperuser: true, cancellationToken: cancellationToken);
            await _neoNews.LaunchAsync(progress, cancellationToken);
            await _provisioning.SetStageAsync("NEONEWS_INSTALL_VALIDATION", cancellationToken);
            _lastAbiCompatibility = await _nativeBridge.ValidateInstalledPackageAsync(_neoNews.PackageName, _neoNews.ActivityName, ResolveApkAbis(), _neoNews.LastInstallSucceeded, cancellationToken);
            if (_context.Config.Android.NativeBridge.Required && !_lastAbiCompatibility.RuntimeStable) throw new RuntimeOperationException("O NeoNews não permaneceu estável com a ABI ARM.", $"primaryCpuAbi={_lastAbiCompatibility.PrimaryCpuAbi}; selectedApkAbi={_lastAbiCompatibility.SelectedApkAbi}; runtimeStable=false");
            await _provisioning.SetStageAsync("NEONEWS_START", cancellationToken);
            await PersistProvisioningStatusAsync(bridge, webView, tts, await _neoNews.GetVersionAsync(cancellationToken), cancellationToken);
            await _provisioning.SetStageAsync("NEONEWS_RUNTIME_VALIDATION", cancellationToken);
            if (_context.Config.Startup.AutoKiosk) { _state.Set(RuntimeState.EnteringKiosk); await _provisioning.SetStageAsync("KIOSK", cancellationToken); await _kiosk.EnterAsync(progress, cancellationToken); }
            await _provisioning.SetStageAsync("WATCHDOG", cancellationToken);
            await StartSupervisorIfEnabledAsync();
            await _provisioning.SetReadinessAsync(!_context.Config.Startup.AutoKiosk || _kiosk.IsActive, !_context.Config.Supervisor.RestartOnActivityLoss || _supervisor.IsActive, cancellationToken);
            _state.Set(RuntimeState.Running);
            await _provisioning.SetStageAsync("Ready", cancellationToken);
            await RefreshSnapshotAsync(cancellationToken);
            progress?.Report(new RuntimeProgress("Sistema pronto", "QEMU, Android, NeoNews, kiosk e watchdog ativos.", 100));
        }
        catch (Exception exception)
        {
            try { await _provisioning.SetErrorAsync(exception, CancellationToken.None); } catch { }
            await CleanupFailedStartAsync();
            throw;
        }
    }

    private async Task<NativeBridgeValidationResult> EnsureNativeBridgeAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        var bridge = await _nativeBridge.ValidateGuestAsync(cancellationToken);
        if (bridge.Ready || !_context.Config.Android.NativeBridge.Required) return bridge;
        if (!bridge.TransportStable)
            throw new RuntimeOperationException("A conexao ADB ficou instavel durante a validacao do Native Bridge.", bridge.Detail);

        progress?.Report(new RuntimeProgress("Recuperando Native Bridge", "Reprovisionando somente artefatos oficiais quando necessario...", 48));
        await _provisioning.SetStageAsync("NATIVE_BRIDGE_PROVISIONING", cancellationToken);
        var reportPath = Path.Combine(_context.ReportsDirectory, "nativebridge-provisioning.json");
        var provision = await _scripts.ExecuteAsync(
            "scripts/provision/Provision-NativeBridgeOfficial.ps1",
            ["-RepositoryRoot", _context.RootDirectory, "-ConfigPath", _context.ConfigPath, "-Serial", _adb.Serial, "-DownloadOfficial", "-ReportPath", reportPath],
            "nativebridge-provision", TimeSpan.FromMinutes(12), cancellationToken);
        if (!provision.Succeeded)
            throw new RuntimeOperationException("Nao foi possivel recuperar o Native Bridge ARM com o mecanismo oficial.",
                $"Relatorio: {reportPath}\n{provision.StandardError}\n{provision.StandardOutput}".Trim());

        await _adb.WaitForDeviceAsync(TimeSpan.FromSeconds(_context.Config.Timeouts.BootSeconds), cancellationToken);
        bridge = await _nativeBridge.ValidateGuestAsync(cancellationToken);
        if (!bridge.Ready)
            throw new RuntimeOperationException("O Native Bridge ARM nao passou na validacao apos a recuperacao oficial.", bridge.Detail);
        return bridge;
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
        try { await _adb.StopServerAsync(CancellationToken.None); } catch { }
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
        await _adb.StopServerAsync(cancellationToken);
        if (setStopped) _state.Set(RuntimeState.Stopped);
        await RefreshSnapshotAsync(cancellationToken);
        progress?.Report(new RuntimeProgress("Sistema parado", "Disco persistente e dados preservados.", 100));
    }

    private async Task EnsureAndroidAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        if (!await _backend.IsRunningAsync(cancellationToken))
        {
            await _provisioning.ValidateLocalRuntimeAsync(cancellationToken);
            await _provisioning.SetStageAsync("HOST_VALIDATION", cancellationToken);
            await _adb.StartServerAsync(cancellationToken);
            await _backend.StartAsync(progress, cancellationToken);
            await _provisioning.SetStageAsync("ANDROID_START", cancellationToken);
            _state.Set(RuntimeState.WaitingForAdb);
        }
        else
        {
            // A backend may have been started by a prior operation while this
            // controller instance has not yet retained its ADB process handle.
            // StartServerAsync remains idempotent for the owned process and
            // still rejects an unrelated listener on the configured port.
            await _adb.StartServerAsync(cancellationToken);
        }
        await WaitForConfiguredBootAsync(progress, cancellationToken);
        await _provisioning.SetStageAsync("BOOT_COMPLETED", cancellationToken);
        await _provisioning.SetStageAsync("PACKAGE_MANAGER_READY", cancellationToken);
        await _provisioning.SetStageAsync("SETTINGS_PROVIDER_READY", cancellationToken);
        await EnsureGuestIdentityAsync(cancellationToken);
        await EnsureGuestLocaleAsync(progress, cancellationToken);
        await EnsureGuestClockAsync(progress, cancellationToken);
        await EnsureGuestConfigurationAsync(progress, requireNeoNewsSuperuser: false, cancellationToken: cancellationToken);
        await _provisioning.SetStageAsync("AndroidReady", cancellationToken);
        await StartSupervisorIfEnabledAsync();
    }

    private async Task EnsureGuestLocaleAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        if (!_context.Config.Android.Optimization.VoiceProtection.Enabled &&
            string.IsNullOrWhiteSpace(_context.Config.Tts.Locale))
        {
            return;
        }

        var requestedLocale = string.IsNullOrWhiteSpace(_context.Config.Tts.Locale)
            ? _context.Config.Android.Optimization.VoiceProtection.Locale
            : _context.Config.Tts.Locale;
        if (!requestedLocale.Equals("pt-BR", StringComparison.OrdinalIgnoreCase))
            throw new RuntimeOperationException("O locale configurado não é suportado pelo runtime.", $"Locale esperado para a primeira execução: pt-BR; configurado={requestedLocale}.");

        progress?.Report(new RuntimeProgress("Configurando idioma", "Validando Português (Brasil) antes de abrir o NeoNews...", 71));
        await _provisioning.SetStageAsync("LOCALE_CONFIGURATION", cancellationToken);
        var locale = await _adb.ReadLocaleAsync(cancellationToken);
        if (!locale.IsPtBr)
        {
            _state.Set(RuntimeState.Preparing);
            var configured = await _adb.EnsurePtBrLocaleAsync(cancellationToken);
            if (configured.RebootRequired)
            {
                _state.Set(RuntimeState.Recovering);
                progress?.Report(new RuntimeProgress("Reiniciando Android", "O locale pt-BR exige reinicialização controlada...", 73));
                await _adb.RebootGuestAsync(cancellationToken);
                await _provisioning.MarkRebootPerformedAsync(cancellationToken);
                await _adb.WaitForBootAsync(progress, TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.LocaleSeconds)), cancellationToken);
            }
            locale = await _adb.ReadLocaleAsync(cancellationToken);
        }

        if (!locale.IsPtBr)
        {
            throw new RuntimeOperationException(
                "O idioma Português (Brasil) não foi validado.",
                $"requested={locale.Requested}; effective={locale.Effective}; persist.sys.locale={locale.PersistedLocale}; system_locales={locale.SystemLocales}");
        }
        _logs.Info("provisioning", $"LOCALE_OK requested={locale.Requested}; effective={locale.Effective}; rebootRequired={locale.RebootRequired}.");
        await _provisioning.SetStageAsync("LOCALE_VALIDATION", cancellationToken);
        progress?.Report(new RuntimeProgress("Idioma validado", "Português (Brasil) confirmado; NeoNews pode iniciar.", 75));
    }

    private async Task EnsureGuestClockAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        if (!_context.Config.Runtime.SyncClockWithHost) return;

        var timezone = _context.Config.Runtime.Timezone;
        if (string.IsNullOrWhiteSpace(timezone))
            throw new RuntimeOperationException("O fuso horário do Android não está configurado.", "runtime.timezone está vazio.");

        progress?.Report(new RuntimeProgress("Sincronizando horário", "Aplicando o relógio do Windows ao Android...", 76));
        await _provisioning.SetStageAsync("CLOCK_CONFIGURATION", cancellationToken);
        await _adb.EnsureRootAsync(cancellationToken);
        var clock = await _adb.EnsureHostClockAsync(
            timezone,
            _context.Config.Runtime.MaxClockSkewSeconds,
            cancellationToken);
        if (!clock.Validated)
        {
            throw new RuntimeOperationException(
                "O horário do Android não corresponde ao Windows.",
                clock.Detail);
        }

        _logs.Info("provisioning", $"CLOCK_OK {clock.Detail}");
        await _provisioning.SetStageAsync("CLOCK_VALIDATION", cancellationToken);
        progress?.Report(new RuntimeProgress("Horário validado", $"Android sincronizado com o Windows; desvio de {clock.SkewSeconds}s.", 78));
    }

    private async Task WaitForConfiguredBootAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        var state = await _provisioning.LoadAsync(cancellationToken);
        var firstBoot = state is null || !state.PackageManagerReady;
        var seconds = firstBoot
            ? _context.Config.Timeouts.FirstBootSeconds
            : _context.Config.Timeouts.BootSeconds;
        progress?.Report(new RuntimeProgress(firstBoot ? "Primeiro boot Android" : "Boot Android", firstBoot ? "Aguardando dexopt, Package Manager e Settings Provider..." : "Aguardando o guest persistente...", 40));
        await _provisioning.SetStageAsync("ADB_CONNECTING", cancellationToken);
        await _adb.WaitForBootAsync(progress, TimeSpan.FromSeconds(Math.Max(15, seconds)), cancellationToken);
        await _provisioning.RecordAdbLastOnlineAsync(_adb.LastDeviceSeenAt, cancellationToken);
    }

    private Task StartSupervisorIfEnabledAsync() =>
        _context.Config.Supervisor.RestartOnActivityLoss ? _supervisor.StartAsync() : Task.CompletedTask;

    private IReadOnlyList<string> ResolveApkAbis()
    {
        var path = _context.ResolveApkPath();
        if (!File.Exists(path)) return [];
        try { return NativeBridgeValidationService.ReadApkAbis(path); }
        catch (Exception exception) { _logs.Warning("launcher", $"Falha ao extrair ABIs do APK local: {exception.Message}"); return []; }
    }

    private async Task EnsureGuestIdentityAsync(CancellationToken cancellationToken)
    {
        var guest = await _adb.ValidateGuestIdentityAsync(_context.Config.Android.Release, _context.Config.Android.ApiLevel, cancellationToken);
        if (!guest.Ready)
            throw new RuntimeOperationException("A imagem Android não corresponde ao runtime configurado.", guest.Detail);
    }

    private async Task EnsureGuestConfigurationAsync(
        IProgress<RuntimeProgress>? progress,
        bool requireNeoNewsSuperuser,
        CancellationToken cancellationToken)
    {
        await _provisioning.SetStageAsync("GUEST_CONFIGURATION", cancellationToken);
        var result = await _guestConfiguration.EnsureAsync(progress, requireNeoNewsSuperuser, cancellationToken);
        await _provisioning.RecordGuestConfigurationAsync(result, cancellationToken);
        if (!result.Ready)
        {
            throw new RuntimeOperationException(
                "A configuração persistente do guest não foi homologada.",
                result.Detail);
        }

        // Updating /system/etc/init.sh takes effect on the next boot. The
        // guest service already waits for that boot; recheck the identity and
        // locale gates before allowing any dependent application to start.
        if (result.RebootPerformed)
        {
            await EnsureGuestIdentityAsync(cancellationToken);
            await EnsureGuestLocaleAsync(progress, cancellationToken);
            await EnsureGuestClockAsync(progress, cancellationToken);
        }
    }

    private async Task<(bool Ready, string Label, string Detail, string Version)> ReadWebViewAsync(CancellationToken cancellationToken)
    {
        var providerDump = await SafeAsync(() => _adb.GetWebViewDumpAsync(cancellationToken), cancellationToken);
        var packageDump = await SafeAsync(() => _adb.GetPackageDumpAsync(_context.Config.WebView.Provider, cancellationToken), cancellationToken);
        var version = AndroidRuntimeParsing.ReadVersionName(packageDump) ?? string.Empty;
        var primaryAbi = AndroidRuntimeParsing.ReadPrimaryCpuAbi(packageDump);
        var providerReady = AndroidRuntimeParsing.IsActiveWebViewProvider(providerDump, _context.Config.WebView.Provider);
        var abiReady = !_context.Config.WebView.RequireNativeGuestAbi || AndroidRuntimeParsing.IsX86Abi(primaryAbi);
        var ready = providerReady && version.Equals(_context.Config.WebView.HomologatedVersion, StringComparison.OrdinalIgnoreCase) && abiReady;
        var label = string.IsNullOrWhiteSpace(version) ? "Não encontrado" : ready ? "Validado" : $"Divergente ({version})";
        return (ready, label, $"providerAtivo={providerReady}; provider={_context.Config.WebView.Provider}; versão={version}; esperada={_context.Config.WebView.HomologatedVersion}; primaryCpuAbi={primaryAbi}; ABI nativa x86={abiReady}", version);
    }

    private async Task<(bool Ready, string Detail, string DefaultEngine)> ValidateTtsAsync(CancellationToken cancellationToken)
    {
        // RHVoice data lives below the provider's private app directory. The
        // runtime validates it with the same root boundary used by the
        // project-approved synthesis probe; no package or engine is changed.
        await _adb.EnsureRootAsync(cancellationToken);
        var packages = await SafeAsync(() => _adb.GetPackagesAsync(cancellationToken), cancellationToken);
        var defaultEngine = await SafeAsync(() => _adb.GetTtsDefaultAsync(cancellationToken), cancellationToken);
        var localeCheck = await SafeAsync(() => _adb.CheckTtsDataAsync("por", "BRA", cancellationToken), cancellationToken);
        var ttsData = await ReadTtsVoiceDataAsync(cancellationToken);
        var providerPackage = string.IsNullOrWhiteSpace(_context.Config.Tts.ProviderPackage)
            ? "com.github.olga_yakovleva.rhvoice.android"
            : _context.Config.Tts.ProviderPackage;
        var packageReady = packages.Contains(providerPackage, StringComparison.OrdinalIgnoreCase);
        var selected = defaultEngine.Contains("rhvoice", StringComparison.OrdinalIgnoreCase);
        var legacyLocaleReady = localeCheck.Contains("result=1", StringComparison.OrdinalIgnoreCase) || localeCheck.Contains("CHECK_TTS_DATA_PASS", StringComparison.OrdinalIgnoreCase) || localeCheck.Contains("CHECK_VOICE_DATA_PASS", StringComparison.OrdinalIgnoreCase);
        var localeReady = legacyLocaleReady || ttsData.Ready;
        return (packageReady && selected && localeReady, $"engineEsperada={_context.Config.Tts.Engine}; provider={providerPackage}; default={defaultEngine}; locale={_context.Config.Tts.Locale}; pacoteRhvoice={packageReady}; engineSelecionada={selected}; dadosLocale={localeReady}; dadosInstalados={ttsData.Ready}; retorno={localeCheck}; paths={ttsData.Detail}", defaultEngine);
    }

    private async Task<(bool Ready, string Detail)> ReadTtsVoiceDataAsync(CancellationToken cancellationToken)
    {
        var providerPackage = string.IsNullOrWhiteSpace(_context.Config.Tts.ProviderPackage)
            ? "com.github.olga_yakovleva.rhvoice.android"
            : _context.Config.Tts.ProviderPackage;
        var dataRoot = $"/data/user/0/{providerPackage}/app_data";
        var result = await SafeAsync(() => _adb.ShellAsync(["find", dataRoot, "-maxdepth", "2", "-type", "d"], TimeSpan.FromSeconds(20), cancellationToken), cancellationToken);
        var languagePackage = _context.Config.Tts.LanguagePackage;
        var voicePackage = _context.Config.Tts.VoicePackage;
        var languageReady = !string.IsNullOrWhiteSpace(languagePackage) && result.Contains(languagePackage, StringComparison.OrdinalIgnoreCase);
        var voiceReady = !string.IsNullOrWhiteSpace(voicePackage) && result.Contains(voicePackage, StringComparison.OrdinalIgnoreCase);
        return (languageReady && voiceReady, $"root={dataRoot}; language={languagePackage}; languageReady={languageReady}; voice={voicePackage}; voiceReady={voiceReady}; listing={result}");
    }

    private async Task PersistProvisioningStatusAsync(
        NativeBridgeValidationResult bridge,
        (bool Ready, string Label, string Detail, string Version) webView,
        (bool Ready, string Detail, string DefaultEngine) tts,
        string? neoNewsVersion,
        CancellationToken cancellationToken)
    {
        var state = await _provisioning.LoadAsync(cancellationToken) ?? new ProvisioningState();
        state.PackageManagerReady = true;
        state.SettingsProviderReady = true;
        state.LocaleValidated = true;
        state.NeoNewsInstalled = true;
        state.NeoNewsRunning = true;
        state.LastError = string.Empty;
        state.NativeBridgeStatus = _lastAbiCompatibility?.RuntimeStable == true
            ? "ready"
            : bridge.State.ToString().ToLowerInvariant();
        state.WebViewVersion = webView.Version;
        state.TtsStatus = tts.Ready ? $"ready:{tts.DefaultEngine}" : "missing-or-not-selected";
        state.NeoNewsVersion = neoNewsVersion ?? string.Empty;
        state.LastValidation = DateTimeOffset.UtcNow;
        await _provisioning.SaveAsync(state, cancellationToken);
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
