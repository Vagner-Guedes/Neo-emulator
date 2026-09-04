using System.Windows;
using System.Windows.Threading;
using NeoNews.Runtime.Launcher.Models;
using NeoNews.Runtime.Launcher.Services;
using NeoNews.Runtime.Launcher.ViewModels;

namespace NeoNews.Runtime.Launcher;

public partial class App : System.Windows.Application
{
    private SingleInstanceService? _singleInstance;
    private RuntimeContext? _context;
    private RuntimeController? _controller;
    private MainWindow? _mainWindow;
    private TrayService? _tray;
    private CancellationTokenSource? _pipeCancellation;
    private Task? _pipeServer;
    private bool _exiting;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        RegisterGlobalExceptionHandlers();
        SessionEnding += (_, _) => HandleSessionEnding();
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        var command = RuntimeCommandParser.Parse(e.Args);
        var exitAfterDiagnostics = e.Args.Length > 0 && command == RuntimeCommand.Diagnostics;

        try
        {
            _context = RuntimeContext.Load();
            _singleInstance = new SingleInstanceService(_context.RootDirectory);
            if (!_singleInstance.TryAcquire())
            {
                var sent = false;
                for (var attempt = 0; attempt < 4 && !sent; attempt++)
                {
                    sent = await _singleInstance.SendCommandAsync(command.ToArgument());
                    if (!sent) await Task.Delay(150);
                }
                Shutdown();
                return;
            }
            _controller = new RuntimeController(_context);
            _mainWindow = new MainWindow(_controller);
            MainWindow = _mainWindow;
            _tray = new TrayService(
                _mainWindow.ShowPanel,
                () => RunTrayCommandAsync(RuntimeCommand.Start),
                () => RunTrayCommandAsync(RuntimeCommand.Stop),
                () => RunTrayCommandAsync(RuntimeCommand.Restart),
                () => RunTrayCommandAsync(RuntimeCommand.Kiosk),
                () => RunTrayCommandAsync(RuntimeCommand.ExitKiosk),
                () => RunTrayCommandAsync(RuntimeCommand.Diagnostics),
                () => RunTrayCommandAsync(RuntimeCommand.Exit));
            _pipeCancellation = new CancellationTokenSource();
            _pipeServer = _singleInstance.RunServerAsync(HandlePipeCommandAsync, _pipeCancellation.Token);

            if (command == RuntimeCommand.Show) _mainWindow.ShowPanel();
            else { _mainWindow.SuppressErrors = true; _mainWindow.PrepareForBackground(); }
            await _mainWindow.ViewModel.ExecuteCommandAsync(command);
            if (exitAfterDiagnostics) RequestExit();
        }
        catch (Exception exception)
        {
            if (_mainWindow is not null) _mainWindow.ShowError(new ErrorInfo("Não foi possível iniciar o runtime.", exception.ToString()));
            else new ErrorDialog("Não foi possível iniciar o runtime.", exception.ToString()).ShowDialog();
            RequestExit();
        }
    }

    public async void RequestExit()
    {
        if (_exiting) return;
        _exiting = true;
        _pipeCancellation?.Cancel();
        _tray?.Dispose();
        _mainWindow?.AllowClose();
        try
        {
            if (_controller is not null) await _controller.DisposeAsync().ConfigureAwait(true);
        }
        catch (Exception exception)
        {
            try { _controller?.Logs.Warning("launcher", $"Falha no encerramento: {exception.Message}"); } catch { }
        }
        _pipeCancellation?.Dispose();
        _singleInstance?.Dispose();
        Shutdown();
    }

    private async Task HandlePipeCommandAsync(string text)
    {
        try
        {
            var command = RuntimeCommandParser.Parse([text]);
            if (_mainWindow is null) return;
            var operation = await Dispatcher.InvokeAsync(() => _mainWindow.ViewModel.ExecuteCommandAsync(command));
            if (command == RuntimeCommand.Diagnostics)
            {
                // A diagnostic collection may wait for the controller gate while
                // --start finishes its UI refresh. Do not block the named-pipe
                // server on that operation, otherwise the endurance harness can
                // never receive its first report.
                _ = ObserveRemoteOperationAsync(operation, text);
                return;
            }
            await operation.ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            try { _controller?.Logs.Error("launcher", $"Falha ao processar comando remoto '{text}'.", exception); } catch { }
        }
    }

    private async Task ObserveRemoteOperationAsync(Task operation, string text)
    {
        try { await operation.ConfigureAwait(false); }
        catch (Exception exception)
        {
            try { _controller?.Logs.Error("launcher", $"Falha ao concluir comando remoto '{text}'.", exception); } catch { }
        }
    }

    private Task RunTrayCommandAsync(RuntimeCommand command)
    {
        _mainWindow?.ShowPanel();
        return _mainWindow?.ViewModel.ExecuteCommandAsync(command) ?? Task.CompletedTask;
    }

    private void RegisterGlobalExceptionHandlers()
    {
        DispatcherUnhandledException += (_, args) =>
        {
            args.Handled = true;
            ReportUnhandled(args.Exception);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception exception) ReportUnhandled(exception);
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            args.SetObserved();
            ReportUnhandled(args.Exception);
        };
    }

    private void ReportUnhandled(Exception exception)
    {
        try { _controller?.Logs.Error("launcher", "Exceção não tratada.", exception); } catch { }
        if (_mainWindow is not null && _mainWindow.IsLoaded)
        {
            try { _mainWindow.ShowError(new ErrorInfo("O runtime encontrou um erro inesperado.", exception.ToString())); } catch { }
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (!_exiting)
        {
            _exiting = true;
            _pipeCancellation?.Cancel();
            _tray?.Dispose();
            _mainWindow?.AllowClose();
            ShutdownControllerForProcessExit();
            _pipeCancellation?.Dispose();
            _singleInstance?.Dispose();
        }
        base.OnExit(e);
    }

    private void ShutdownControllerForProcessExit()
    {
        if (_controller is null) return;
        try
        {
            // OnExit is synchronous and can be raised by Windows session
            // shutdown. Run the async cleanup off the dispatcher so QMP and
            // process waits can finish without leaving QEMU orphaned.
            var shutdown = Task.Run(() => _controller.ShutdownAsync(CancellationToken.None));
            if (!shutdown.Wait(TimeSpan.FromSeconds(30)))
                _controller.Logs.Warning("launcher", "Encerramento excedeu 30 segundos durante a saída do processo.");
        }
        catch (Exception exception)
        {
            try { _controller.Logs.Error("launcher", "Falha no encerramento síncrono do runtime.", exception); } catch { }
        }
    }

    private void HandleSessionEnding()
    {
        if (_exiting) return;
        _exiting = true;
        _pipeCancellation?.Cancel();
        _tray?.Dispose();
        _mainWindow?.AllowClose();
        ShutdownControllerForProcessExit();
        _pipeCancellation?.Dispose();
        _singleInstance?.Dispose();
    }
}
