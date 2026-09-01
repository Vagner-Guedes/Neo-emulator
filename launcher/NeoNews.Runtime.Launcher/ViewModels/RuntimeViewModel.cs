using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;
using NeoNews.Runtime.Launcher.Models;
using NeoNews.Runtime.Launcher.Services;

namespace NeoNews.Runtime.Launcher.ViewModels;

public sealed record ErrorInfo(string Message, string Details);

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
    private string _lastError = string.Empty;

    public RuntimeViewModel(RuntimeController controller)
    {
        _controller = controller;
        _snapshot = controller.Snapshot;
        _controller.SnapshotChanged += Controller_SnapshotChanged;

        StartCommand = new AsyncCommand(() => RunAsync("Iniciar NeoNews", (p, ct) => _controller.StartNeoNewsAsync(p, ct)), () => !IsBusy);
        StopCommand = new AsyncCommand(() => RunAsync("Parar Android", (p, ct) => _controller.StopAndroidAsync(p, ct)), () => !IsBusy);
        RestartCommand = new AsyncCommand(() => RunAsync("Reiniciar Android", (p, ct) => _controller.RestartAndroidAsync(p, ct)), () => !IsBusy);
        OpenCommand = new AsyncCommand(() => RunAsync("Abrir NeoNews", (p, ct) => _controller.OpenNeoNewsAsync(p, ct)), () => !IsBusy);
        InstallCommand = new AsyncCommand(() => RunAsync("Instalar / atualizar", (_, ct) => _controller.InstallNeoNewsAsync(null, ct)), () => !IsBusy);
        KioskCommand = new AsyncCommand(() => RunAsync("Ativar kiosk", (p, ct) => _controller.EnterKioskAsync(p, ct)), () => !IsBusy);
        ExitKioskCommand = new AsyncCommand(() => RunAsync("Sair do kiosk", (_, ct) => _controller.ExitKioskAsync(ct)), () => !IsBusy);
        DiagnosticsCommand = new AsyncCommand(CollectDiagnosticsAsync, () => !IsBusy);
        ToggleWatchdogCommand = new AsyncCommand(() => _controller.SetSupervisorAsync(!WatchdogEnabled), () => !IsBusy);
        ToggleStartupCommand = new AsyncCommand(() => _controller.SetStartupAsync(!StartWithWindows), () => !IsBusy);
        OpenLogsCommand = new AsyncCommand(() => { _controller.OpenLogsFolder(); return Task.CompletedTask; });
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
    public string Logs { get => _logs; private set => SetField(ref _logs, value); }
    public string LastError { get => _lastError; private set { if (SetField(ref _lastError, value)) OnPropertyChanged(nameof(HasError)); } }
    public bool HasError => !string.IsNullOrWhiteSpace(LastError);

    public bool StartWithWindows => _controller.Context.Config.Startup.StartWithWindows;
    public bool AutoKiosk => _controller.Context.Config.Startup.AutoKiosk;
    public bool WatchdogEnabled => _controller.Context.Config.Supervisor.RestartOnActivityLoss;
    public int ScreenWidth => _controller.Context.Config.Android.Optimization.Screen.Width;
    public int ScreenHeight => _controller.Context.Config.Android.Optimization.Screen.Height;
    public int Density => _controller.Context.Config.Android.Optimization.Screen.Density;
    public string GpuMode => _controller.Context.Config.Android.Emulator.Gpu;

    public ICommand StartCommand { get; }
    public ICommand StopCommand { get; }
    public ICommand RestartCommand { get; }
    public ICommand OpenCommand { get; }
    public ICommand InstallCommand { get; }
    public ICommand KioskCommand { get; }
    public ICommand ExitKioskCommand { get; }
    public ICommand DiagnosticsCommand { get; }
    public ICommand ToggleWatchdogCommand { get; }
    public ICommand ToggleStartupCommand { get; }
    public ICommand OpenLogsCommand { get; }
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
        RuntimeCommand.Start => RunAsync("Iniciar NeoNews", (p, ct) => _controller.StartNeoNewsAsync(p, ct)),
        RuntimeCommand.Stop => RunAsync("Parar Android", (p, ct) => _controller.StopAndroidAsync(p, ct)),
        RuntimeCommand.Restart => RunAsync("Reiniciar Android", (p, ct) => _controller.RestartAndroidAsync(p, ct)),
        RuntimeCommand.Kiosk => RunAsync("Ativar kiosk", (p, ct) => _controller.EnterKioskAsync(p, ct)),
        RuntimeCommand.ExitKiosk => RunAsync("Sair do kiosk", (_, ct) => _controller.ExitKioskAsync(ct)),
        RuntimeCommand.Autostart => RunAsync("Inicialização automática", (p, ct) => _controller.Context.Config.Startup.StartNeoNews
            ? _controller.StartNeoNewsAsync(p, ct)
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

    public async Task ApplySettingsAsync(bool startWithWindows, bool autoKiosk, bool watchdog, int width, int height, int density, string gpu)
    {
        var config = _controller.Context.Config;
        config.Startup.AutoKiosk = autoKiosk;
        config.Supervisor.RestartOnActivityLoss = watchdog;
        config.Android.Optimization.Screen.Width = width;
        config.Android.Optimization.Screen.Height = height;
        config.Android.Optimization.Screen.Density = density;
        config.Android.Emulator.Gpu = gpu;
        await _controller.SaveConfigAsync();
        if (startWithWindows != config.Startup.StartWithWindows) await _controller.SetStartupAsync(startWithWindows);
        if (watchdog != _controller.IsSupervisorActive) await _controller.SetSupervisorAsync(watchdog);
        RaiseSettingsChanged();
    }

    private async Task CollectDiagnosticsAsync()
    {
        if (IsBusy) return;
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
        if (IsBusy) return;
        IsBusy = true;
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
        LastError = exception.Message;
        ProgressIndeterminate = false;
        ProgressText = "A operação não foi concluída";
        ErrorRequested?.Invoke(this, new ErrorInfo(exception.Message, details));
    }

    private async Task ExitAsync()
    {
        if (IsBusy) return;
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
    }

    private void RaiseSettingsChanged()
    {
        foreach (var name in new[] { nameof(StartWithWindows), nameof(AutoKiosk), nameof(WatchdogEnabled), nameof(ScreenWidth), nameof(ScreenHeight), nameof(Density), nameof(GpuMode) }) OnPropertyChanged(name);
    }

    private void RaiseCommands()
    {
        foreach (var command in new[] { StartCommand, StopCommand, RestartCommand, OpenCommand, InstallCommand, KioskCommand, ExitKioskCommand, DiagnosticsCommand, ToggleWatchdogCommand, ToggleStartupCommand, ExitCommand })
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

    public async ValueTask DisposeAsync()
    {
        _operationCancellation?.Cancel();
        _controller.SnapshotChanged -= Controller_SnapshotChanged;
        await Task.CompletedTask;
    }
}
