using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Windows.Input;
using System.Windows.Media;
using NeoNews.Runtime.Launcher.Models;
using NeoNews.Runtime.Launcher.Services;
using WpfBrush = System.Windows.Media.Brush;

namespace NeoNews.Runtime.Launcher.ViewModels;

public sealed record ErrorInfo(string Message, string Details);
public sealed record RecentLogLine(string Time, string Message);

public sealed class RuntimeViewModel : INotifyPropertyChanged, IAsyncDisposable
{
    private readonly RuntimeController _controller;
    private CancellationTokenSource? _operationCancellation;
    private RuntimeSnapshot _snapshot;
    private string _progressText = "Pronto para iniciar";
    private double _progressValue;
    private bool _progressIndeterminate;
    private bool _isBusy;
    private string _logs = string.Empty;
    private string _logFilter = string.Empty;
    private string _lastError = string.Empty;
    private readonly DateTimeOffset _startedAt = DateTimeOffset.Now;
    private DateTimeOffset? _lastExecutionAt;
    private IReadOnlyList<RecentLogLine> _recentLogLines = [];

    public RuntimeViewModel(RuntimeController controller)
    {
        _controller = controller;
        _snapshot = controller.Snapshot;
        _controller.SnapshotChanged += Controller_SnapshotChanged;

        StartCommand = new AsyncCommand(() => RunAsync("Iniciar sistema", (p, ct) => _controller.StartSystemAsync(p, ct)), () => !IsBusy);
        StopCommand = new AsyncCommand(() => RunAsync("Parar sistema", (p, ct) => _controller.StopSystemAsync(p, ct)), () => !IsBusy);
        RestartCommand = new AsyncCommand(() => RunAsync("Reiniciar sistema", (p, ct) => _controller.RestartSystemAsync(p, ct)), () => !IsBusy);
        OpenCommand = new AsyncCommand(() => RunAsync("Abrir NeoNews", (p, ct) => _controller.OpenNeoNewsAsync(p, ct)), () => !IsBusy);
        RestartNeoNewsCommand = new AsyncCommand(() => RunAsync("Reiniciar aplicativo", (p, ct) => _controller.RestartNeoNewsAsync(p, ct)), () => !IsBusy);
        InstallCommand = new AsyncCommand(() => RunAsync("Instalar / atualizar", (_, ct) => _controller.InstallNeoNewsAsync(null, ct)), () => !IsBusy);
        KioskCommand = new AsyncCommand(() => RunAsync("Ativar kiosk", (p, ct) => _controller.EnterKioskAsync(p, ct)), () => !IsBusy);
        ExitKioskCommand = new AsyncCommand(() => RunAsync("Sair do kiosk", (_, ct) => _controller.ExitKioskAsync(ct)), () => !IsBusy);
        DiagnosticsCommand = new AsyncCommand(CollectDiagnosticsAsync, () => !IsBusy);
        ToggleWatchdogCommand = new AsyncCommand(() => _controller.SetSupervisorAsync(!WatchdogEnabled), () => !IsBusy);
        ToggleStartupCommand = new AsyncCommand(() => _controller.SetStartupAsync(!StartWithWindows), () => !IsBusy);
        ResetDefaultsCommand = new AsyncCommand(ResetDefaultsAsync, () => !IsBusy);
        OpenLogsCommand = new AsyncCommand(() => { _controller.OpenLogsFolder(); return Task.CompletedTask; });
        CopyLogsCommand = new AsyncCommand(CopyLogsAsync);
        ExitCommand = new AsyncCommand(ExitAsync, () => !IsBusy);
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler<ErrorInfo>? ErrorRequested;
    public event EventHandler? ExitRequested;

    public RuntimeSnapshot Snapshot => _snapshot;
    public RuntimeState State => _snapshot.State;
    public string StateLabel => State switch
    {
        RuntimeState.Running => "Operação normal",
        RuntimeState.Error => "Atenção necessária",
        RuntimeState.Starting or RuntimeState.WaitingForAdb or RuntimeState.BootingAndroid or RuntimeState.Preparing or RuntimeState.StartingNeoNews or RuntimeState.EnteringKiosk => "Inicializando",
        RuntimeState.Stopping => "Encerrando",
        _ => "Parado"
    };
    public string AndroidStatus => _snapshot.Android;
    public string NeoNewsStatus => _snapshot.NeoNews;
    public string WebViewStatus => _snapshot.WebView;
    public string VoiceStatus => _snapshot.Voice;
    public string WatchdogStatus => _snapshot.Watchdog;
    public string StartupStatus => _snapshot.Startup;
    public string AdbStatus => _snapshot.Adb;
    public string ProgressText { get => _progressText; private set => SetField(ref _progressText, value); }
    public double ProgressValue { get => _progressValue; private set => SetField(ref _progressValue, value); }
    public bool ProgressIndeterminate { get => _progressIndeterminate; private set => SetField(ref _progressIndeterminate, value); }
    public bool IsBusy { get => _isBusy; private set { if (SetField(ref _isBusy, value)) RaiseCommands(); } }
    public string Logs { get => _logs; private set { if (SetField(ref _logs, value)) { OnPropertyChanged(nameof(FilteredLogs)); UpdateRecentLogLines(); } } }
    public string LogFilter { get => _logFilter; set { if (SetField(ref _logFilter, value)) OnPropertyChanged(nameof(FilteredLogs)); } }
    public string FilteredLogs => string.IsNullOrWhiteSpace(LogFilter)
        ? Logs
        : string.Join(Environment.NewLine, Logs.Split(["\r\n", "\n"], StringSplitOptions.None).Where(line => line.Contains(LogFilter, StringComparison.OrdinalIgnoreCase)));
    public string LastError { get => _lastError; private set { if (SetField(ref _lastError, value)) OnPropertyChanged(nameof(HasError)); } }
    public bool HasError => !string.IsNullOrWhiteSpace(LastError);
    public IReadOnlyList<RecentLogLine> RecentLogLines => _recentLogLines;

    public string SystemStatusText => State switch
    {
        RuntimeState.Running when _snapshot.Android is "Online" && _snapshot.PackageInstalled && _snapshot.NeoNewsRunning => "Sistema pronto",
        RuntimeState.Running when _snapshot.Android is "Online" => "Atenção necessária",
        RuntimeState.Starting or RuntimeState.WaitingForAdb or RuntimeState.BootingAndroid or RuntimeState.Preparing or RuntimeState.StartingNeoNews or RuntimeState.EnteringKiosk => "Inicializando",
        RuntimeState.Error => "Atenção necessária",
        _ => "Sistema parado"
    };
    public string SystemStatusDetail => State switch
    {
        RuntimeState.Error when !string.IsNullOrWhiteSpace(LastError) => LastError,
        RuntimeState.Running when _snapshot.Android is "Online" => _snapshot.NeoNews,
        RuntimeState.Starting or RuntimeState.WaitingForAdb or RuntimeState.BootingAndroid or RuntimeState.Preparing or RuntimeState.StartingNeoNews or RuntimeState.EnteringKiosk => ProgressText,
        _ => "Clique em iniciar sistema para começar."
    };
    public WpfBrush SystemStatusBrush => GetStatusBrush(SystemStatusText);
    public string HomeHeroTitle => SystemStatusText;
    public string HomeHeroDescription => State switch
    {
        RuntimeState.Running when _snapshot.NeoNewsRunning => "O NeoNews está em execução e pronto para operação.",
        RuntimeState.Running => "O Android está online, mas o NeoNews ainda precisa ser iniciado.",
        RuntimeState.Starting or RuntimeState.WaitingForAdb or RuntimeState.BootingAndroid or RuntimeState.Preparing or RuntimeState.StartingNeoNews or RuntimeState.EnteringKiosk => "Aguarde enquanto o Android e o NeoNews são preparados.",
        RuntimeState.Error => "A última operação não foi concluída. Consulte os detalhes no Diagnóstico.",
        _ => "Clique em iniciar sistema para começar."
    };
    public string HomeAndroidDetail => _snapshot.Adb == "Online" ? "ADB conectado" : "ADB não conectado";
    public string HomeNeoNewsDetail => _snapshot.PackageInstalled ? _snapshot.NeoNews : "Pacote não instalado";
    public string HomeInternetStatus => NetworkStatus;
    public string NetworkStatus => _snapshot.InternetState switch
    {
        InternetRuntimeState.Online => "Online",
        InternetRuntimeState.Offline => "Offline",
        _ => "Não verificado"
    };
    public string AndroidReleaseLabel => $"Android {_controller.Context.Config.Android.Release}";
    public string AndroidApiLabel => $"API {_controller.Context.Config.Android.ApiLevel}";
    public string LauncherVersionLabel => $"Versão {_controller.Context.Config.Launcher.Version}";
    public string WebViewVersionLabel => _snapshot.WebViewState switch
    {
        WebViewRuntimeState.Ready => $"Ativa {_controller.Context.Config.WebView.HomologatedVersion}",
        WebViewRuntimeState.Mismatch when WebViewStatus.StartsWith("Divergente", StringComparison.OrdinalIgnoreCase) => WebViewStatus,
        _ => $"Esperada {_controller.Context.Config.WebView.HomologatedVersion}"
    };
    public string VoiceLocaleLabel => _controller.Context.Config.Tts.Locale.Equals("pt-BR", StringComparison.OrdinalIgnoreCase)
        ? "Português Brasil"
        : _controller.Context.Config.Tts.Locale;
    public string StorageStatus
    {
        get
        {
            try
            {
                var root = Path.GetPathRoot(_controller.Context.RootDirectory) ?? "C:\\";
                return new DriveInfo(root).AvailableFreeSpace > 0 ? "Disponível" : "Indisponível";
            }
            catch { return "Indisponível"; }
        }
    }
    public string NeoNewsStatusHeading => _snapshot.PackageInstalled ? "Aplicativo instalado e pronto" : "Aplicativo não instalado";
    public string NeoNewsStatusDescription => _snapshot.PackageInstalled
        ? "O NeoNews está instalado no guest Android."
        : "O APK autorizado ainda não foi instalado no guest Android.";
    public string NeoNewsVersionDisplay => _snapshot.NeoNews.StartsWith("Instalado ", StringComparison.OrdinalIgnoreCase)
        ? _snapshot.NeoNews[10..]
        : $"Esperada {_controller.Context.Config.NeoNews.VersionName}";
    public string NeoNewsPackageDisplay => _controller.Context.Config.NeoNews.PackageName;
    public string NeoNewsCodeDisplay => _controller.Context.Config.NeoNews.VersionCode.ToString();
    public string NeoNewsArchitectureDisplay => string.Join(", ", _controller.Context.Config.NeoNews.SupportedApkAbis);
    public string NeoNewsLastUpdate
    {
        get
        {
            try
            {
                var path = _controller.Context.ResolveApkPath();
                return File.Exists(path) ? File.GetLastWriteTime(path).ToString("dd/MM/yyyy HH:mm") : "Não disponível";
            }
            catch { return "Não disponível"; }
        }
    }
    public string BuildLabel
    {
        get
        {
            try
            {
                var path = Environment.ProcessPath;
                return path is not null && File.Exists(path) ? $"Build {File.GetLastWriteTime(path):yyyy.MM.dd}" : "Build local";
            }
            catch { return "Build local"; }
        }
    }
    public string UptimeLabel => FormatDuration(DateTimeOffset.Now - _startedAt);
    public string LastExecutionLabel => _lastExecutionAt is { } value ? value.ToString("dd/MM/yyyy HH:mm") : "Nenhuma execução";
    public WpfBrush AndroidStatusBrush => GetStatusBrush(AndroidStatus);
    public WpfBrush AdbStatusBrush => GetStatusBrush(AdbStatus);
    public WpfBrush NeoNewsStatusBrush => GetStatusBrush(NeoNewsStatus);
    public WpfBrush WebViewStatusBrush => GetStatusBrush(WebViewStatus);
    public WpfBrush VoiceStatusBrush => GetStatusBrush(VoiceStatus);
    public WpfBrush WatchdogStatusBrush => GetStatusBrush(WatchdogStatus);
    public WpfBrush StartupStatusBrush => GetStatusBrush(StartupStatus);
    public string KioskStatus => _controller.IsKioskActive ? "Ativo" : "Inativo";
    public WpfBrush KioskStatusBrush => GetStatusBrush(KioskStatus);
    public WpfBrush NetworkStatusBrush => GetStatusBrush(NetworkStatus);
    public WpfBrush StorageStatusBrush => GetStatusBrush(StorageStatus);

    public bool StartWithWindows => _controller.Context.Config.Startup.StartWithWindows;
    public bool StartNeoNews => _controller.Context.Config.Startup.StartNeoNews;
    public bool AutoKiosk => _controller.Context.Config.Startup.AutoKiosk;
    public bool WatchdogEnabled => _controller.Context.Config.Supervisor.RestartOnActivityLoss;
    public int ScreenWidth => _controller.Context.Config.Android.Optimization.Screen.Width;
    public int ScreenHeight => _controller.Context.Config.Android.Optimization.Screen.Height;
    public int Density => _controller.Context.Config.Android.Optimization.Screen.Density;
    public string GpuMode => _controller.Context.Config.Android.Backend.Equals("qemu-android-x86", StringComparison.OrdinalIgnoreCase)
        ? _controller.Context.Config.Android.Qemu.Gpu
        : _controller.Context.Config.Android.Emulator.Gpu;
    public int MonitorIndex => _controller.Context.Config.Android.Kiosk.MonitorIndex;
    public string PerformanceProfile => _controller.Context.Config.Android.Optimization.Profile;
    public string Hotkey => _controller.Context.Config.Runtime.Hotkey;

    public ICommand StartCommand { get; }
    public ICommand StopCommand { get; }
    public ICommand RestartCommand { get; }
    public ICommand OpenCommand { get; }
    public ICommand RestartNeoNewsCommand { get; }
    public ICommand InstallCommand { get; }
    public ICommand KioskCommand { get; }
    public ICommand ExitKioskCommand { get; }
    public ICommand DiagnosticsCommand { get; }
    public ICommand ToggleWatchdogCommand { get; }
    public ICommand ToggleStartupCommand { get; }
    public ICommand ResetDefaultsCommand { get; }
    public ICommand OpenLogsCommand { get; }
    public ICommand CopyLogsCommand { get; }
    public ICommand ExitCommand { get; }

    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            await _controller.RefreshSnapshotAsync(cancellationToken);
            await TailLogsAsync(cancellationToken);
        }
        catch (Exception exception)
        {
            LastError = exception.Message;
            Logs = $"{Logs}{Environment.NewLine}[refresh] {exception.Message}".Trim();
        }
    }

    public Task ExecuteCommandAsync(RuntimeCommand command) => command switch
    {
        RuntimeCommand.Show => Task.CompletedTask,
        RuntimeCommand.Start => RunAsync("Iniciar sistema", (p, ct) => _controller.StartSystemAsync(p, ct)),
        RuntimeCommand.Stop => RunAsync("Parar sistema", (p, ct) => _controller.StopSystemAsync(p, ct)),
        RuntimeCommand.Restart => RunAsync("Reiniciar sistema", (p, ct) => _controller.RestartSystemAsync(p, ct)),
        RuntimeCommand.Kiosk => RunAsync("Ativar kiosk", (p, ct) => _controller.EnterKioskAsync(p, ct)),
        RuntimeCommand.ExitKiosk => RunAsync("Sair do kiosk", (_, ct) => _controller.ExitKioskAsync(ct)),
        RuntimeCommand.Autostart => RunAsync("Inicialização automática", (p, ct) => _controller.Context.Config.Startup.StartNeoNews
            ? _controller.StartSystemAsync(p, ct)
            : _controller.StartAndroidAsync(p, ct)),
        RuntimeCommand.Diagnostics => CollectDiagnosticsAsync(),
        RuntimeCommand.Install => RunAsync("Instalar / atualizar", (_, ct) => _controller.InstallNeoNewsAsync(null, ct)),
        RuntimeCommand.Exit => ExitAsync(),
        _ => Task.CompletedTask
    };

    public async Task TailLogsAsync(CancellationToken cancellationToken = default)
    {
        try { Logs = await _controller.ReadLogsAsync(240, cancellationToken); }
        catch (Exception exception) { Logs = $"Não foi possível ler os logs: {exception.Message}"; }
    }

    public void Tick()
    {
        OnPropertyChanged(nameof(UptimeLabel));
        OnPropertyChanged(nameof(LastExecutionLabel));
        OnPropertyChanged(nameof(NetworkStatus));
        OnPropertyChanged(nameof(NetworkStatusBrush));
        OnPropertyChanged(nameof(StorageStatus));
        OnPropertyChanged(nameof(StorageStatusBrush));
    }

    public async Task ApplySettingsAsync(bool startWithWindows, bool startNeoNews, bool autoKiosk, bool watchdog, int width, int height, int density, string gpu, int monitor, string profile, string hotkey)
    {
        var config = _controller.Context.Config;
        config.Startup.StartNeoNews = startNeoNews;
        config.Startup.AutoKiosk = autoKiosk;
        config.Supervisor.RestartOnActivityLoss = watchdog;
        config.Android.Optimization.Screen.Width = width;
        config.Android.Optimization.Screen.Height = height;
        config.Android.Optimization.Screen.Density = density;
        config.Android.Emulator.Gpu = gpu;
        config.Android.Qemu.Gpu = gpu.ToLowerInvariant() switch
        {
            "none" => "none",
            "cirrus" => "cirrus",
            "qxl" => "qxl",
            _ => "std"
        };
        config.Android.Kiosk.DisplaySize = $"{width}x{height}";
        config.Android.Kiosk.DisplayDensity = density;
        config.Android.Kiosk.MonitorIndex = monitor;
        config.Android.Optimization.Profile = profile;
        config.Runtime.Hotkey = hotkey;
        await _controller.SaveConfigAsync();
        if (startWithWindows != config.Startup.StartWithWindows) await _controller.SetStartupAsync(startWithWindows);
        if (watchdog != _controller.IsSupervisorActive) await _controller.SetSupervisorAsync(watchdog);
        RaiseSettingsChanged();
    }

    private async Task CollectDiagnosticsAsync()
    {
        while (IsBusy) await Task.Delay(100);
        IsBusy = true;
        ProgressText = "Coletando diagnóstico...";
        ProgressIndeterminate = true;
        try
        {
            var report = await _controller.CollectDiagnosticsAsync();
            Logs = $"Relatório salvo em:{Environment.NewLine}{report}{Environment.NewLine}{Environment.NewLine}{Logs}".Trim();
            await RefreshAsync();
        }
        catch (Exception exception) { ReportError(exception); }
        finally { IsBusy = false; ProgressIndeterminate = false; ProgressText = "Pronto"; }
    }

    private async Task RunAsync(string operation, Func<IProgress<RuntimeProgress>?, CancellationToken, Task> action)
    {
        while (IsBusy) await Task.Delay(100);
        IsBusy = true;
        _lastExecutionAt = DateTimeOffset.Now;
        OnPropertyChanged(nameof(LastExecutionLabel));
        _operationCancellation = new CancellationTokenSource();
        ProgressValue = 0;
        ProgressIndeterminate = true;
        ProgressText = operation;
        var progress = new Progress<RuntimeProgress>(UpdateProgress);
        try
        {
            await action(progress, _operationCancellation.Token);
            ProgressValue = 100;
            ProgressIndeterminate = false;
            ProgressText = "Concluído";
            await RefreshAsync();
        }
        catch (OperationCanceledException) { ProgressText = "Cancelado"; }
        catch (Exception exception) { ReportError(exception); }
        finally
        {
            _operationCancellation.Dispose();
            _operationCancellation = null;
            IsBusy = false;
            RaiseCommands();
        }
    }

    private void UpdateProgress(RuntimeProgress progress)
    {
        ProgressText = string.IsNullOrWhiteSpace(progress.Detail) ? progress.Phase : $"{progress.Phase} · {progress.Detail}";
        _controller.Logs.Info("launcher", ProgressText);
        if (progress.Percent is double percent)
        {
            ProgressIndeterminate = false;
            ProgressValue = percent;
        }
    }

    private void ReportError(Exception exception)
    {
        var details = exception is RuntimeOperationException operation
            ? operation.TechnicalDetails
            : exception.ToString();
        details = $"Timestamp: {DateTimeOffset.Now:O}{Environment.NewLine}{details}";
        LastError = exception.Message;
        ProgressIndeterminate = false;
        ProgressText = "A operação não foi concluída";
        ErrorRequested?.Invoke(this, new ErrorInfo(exception.Message, details));
    }

    private async Task ExitAsync()
    {
        _operationCancellation?.Cancel();
        ExitRequested?.Invoke(this, EventArgs.Empty);
        await Task.CompletedTask;
    }

    private void Controller_SnapshotChanged(object? sender, RuntimeSnapshot snapshot)
    {
        _snapshot = snapshot;
        OnPropertyChanged(nameof(Snapshot));
        OnPropertyChanged(nameof(State));
        OnPropertyChanged(nameof(StateLabel));
        OnPropertyChanged(nameof(AndroidStatus));
        OnPropertyChanged(nameof(NeoNewsStatus));
        OnPropertyChanged(nameof(WebViewStatus));
        OnPropertyChanged(nameof(VoiceStatus));
        OnPropertyChanged(nameof(WatchdogStatus));
        OnPropertyChanged(nameof(StartupStatus));
        OnPropertyChanged(nameof(AdbStatus));
        RaiseDerivedProperties();
    }

    private async Task ResetDefaultsAsync()
    {
        await ApplySettingsAsync(
            startWithWindows: false,
            startNeoNews: true,
            autoKiosk: true,
            watchdog: true,
            width: 1920,
            height: 1080,
            density: 160,
            gpu: "swiftshader",
            monitor: 0,
            profile: "signage-landscape",
            hotkey: "Ctrl+Alt+Shift+F12");
        await RefreshAsync();
    }

    private void RaiseDerivedProperties()
    {
        foreach (var name in new[]
        {
            nameof(SystemStatusText), nameof(SystemStatusDetail), nameof(SystemStatusBrush), nameof(HomeHeroTitle), nameof(HomeHeroDescription),
            nameof(HomeAndroidDetail), nameof(HomeNeoNewsDetail), nameof(NeoNewsStatusHeading), nameof(NeoNewsStatusDescription),
            nameof(NeoNewsVersionDisplay), nameof(AndroidStatusBrush), nameof(AdbStatusBrush), nameof(NeoNewsStatusBrush),
            nameof(WebViewStatusBrush), nameof(VoiceStatusBrush), nameof(WatchdogStatusBrush), nameof(StartupStatusBrush),
            nameof(KioskStatus), nameof(KioskStatusBrush), nameof(StartWithWindows), nameof(WatchdogEnabled),
            nameof(NetworkStatus), nameof(NetworkStatusBrush), nameof(StorageStatus), nameof(StorageStatusBrush)
        }) OnPropertyChanged(name);
    }

    private void UpdateRecentLogLines()
    {
        var lines = Logs
            .Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries)
            .TakeLast(4)
            .Select(line =>
            {
                var match = Regex.Match(line, @"T(?<time>\d{2}:\d{2}:\d{2})");
                var message = line;
                var separator = line.IndexOf("] ", StringComparison.Ordinal);
                if (separator >= 0) message = line[(separator + 2)..];
                return new RecentLogLine(match.Success ? match.Groups["time"].Value : "--:--:--", message);
            })
            .ToArray();
        _recentLogLines = lines;
        OnPropertyChanged(nameof(RecentLogLines));
    }

    private static WpfBrush GetStatusBrush(string value)
    {
        var key = value.Contains("não", StringComparison.OrdinalIgnoreCase) ||
                  value.Contains("offline", StringComparison.OrdinalIgnoreCase) ||
                  value.Contains("ausente", StringComparison.OrdinalIgnoreCase) ||
                  value.Contains("erro", StringComparison.OrdinalIgnoreCase) ||
                  value.Contains("indisponível", StringComparison.OrdinalIgnoreCase)
            ? "ErrorBrush"
            : value.Contains("atenção", StringComparison.OrdinalIgnoreCase) ||
              value.Contains("divergente", StringComparison.OrdinalIgnoreCase) ||
              value.Contains("pendente", StringComparison.OrdinalIgnoreCase) ||
              value.Contains("desconhecido", StringComparison.OrdinalIgnoreCase) ||
              value.Contains("parado", StringComparison.OrdinalIgnoreCase) ||
              value.Contains("inativo", StringComparison.OrdinalIgnoreCase) ||
              value.Contains("nenhuma", StringComparison.OrdinalIgnoreCase)
                ? "WarningBrush"
                : "SuccessBrush";
        return System.Windows.Application.Current.TryFindResource(key) as WpfBrush ?? System.Windows.Media.Brushes.White;
    }

    private static string FormatDuration(TimeSpan duration) =>
        $"{Math.Max(0, (int)duration.TotalDays):00}d {duration.Hours:00}h {duration.Minutes:00}m";

    private void RaiseSettingsChanged()
    {
        foreach (var name in new[] { nameof(StartWithWindows), nameof(StartNeoNews), nameof(AutoKiosk), nameof(WatchdogEnabled), nameof(ScreenWidth), nameof(ScreenHeight), nameof(Density), nameof(GpuMode), nameof(MonitorIndex), nameof(PerformanceProfile), nameof(Hotkey) }) OnPropertyChanged(name);
    }

    private void RaiseCommands()
    {
        foreach (var command in new[] { StartCommand, StopCommand, RestartCommand, OpenCommand, RestartNeoNewsCommand, InstallCommand, KioskCommand, ExitKioskCommand, DiagnosticsCommand, ToggleWatchdogCommand, ToggleStartupCommand, ResetDefaultsCommand, ExitCommand })
            (command as AsyncCommand)?.RaiseCanExecuteChanged();
    }

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private Task CopyLogsAsync()
    {
        System.Windows.Clipboard.SetText(FilteredLogs);
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        _operationCancellation?.Cancel();
        _controller.SnapshotChanged -= Controller_SnapshotChanged;
        await Task.CompletedTask;
    }
}
