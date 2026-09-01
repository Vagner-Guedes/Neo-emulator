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
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        _singleInstance = new SingleInstanceService();
        var command = RuntimeCommandParser.Parse(e.Args);

        if (!_singleInstance.TryAcquire())
        {
            var sent = false;
            for (var attempt = 0; attempt < 4 && !sent; attempt++)
            {
                sent = await SingleInstanceService.SendCommandAsync(command.ToArgument());
                if (!sent) await Task.Delay(150);
            }
            Shutdown();
            return;
        }

        try
        {
            _context = RuntimeContext.Load();
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
        }
        catch (Exception exception)
        {
            if (_mainWindow is not null) _mainWindow.ShowError(new ErrorInfo("Não foi possível iniciar o runtime.", exception.ToString()));
            else new ErrorDialog("Não foi possível iniciar o runtime.", exception.ToString()).ShowDialog();
            Shutdown();
        }
    }

    private async Task HandlePipeCommandAsync(string text)
    {
        var command = RuntimeCommandParser.Parse([text]);
        if (_mainWindow is null) return;
        var operation = await Dispatcher.InvokeAsync(() => _mainWindow.ViewModel.ExecuteCommandAsync(command));
        await operation.ConfigureAwait(false);
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
            try
            {
                if (_controller is not null)
                {
                    Task.Run(() => _controller.DisposeAsync().AsTask()).GetAwaiter().GetResult();
                }
            }
            catch { }
            _pipeCancellation?.Dispose();
            _singleInstance?.Dispose();
        }
        base.OnExit(e);
    }
}
