using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using NeoNews.Runtime.Launcher.Models;
using NeoNews.Runtime.Launcher.Services;
using NeoNews.Runtime.Launcher.ViewModels;

namespace NeoNews.Runtime.Launcher;

public partial class MainWindow : Window
{
    private const int HotKeyId = 0x4E52;
    private readonly RuntimeViewModel _viewModel;
    private readonly RuntimeController _controller;
    private readonly DispatcherTimer _refreshTimer;
    private HwndSource? _source;
    private bool _allowClose;

    public MainWindow(RuntimeController controller)
    {
        InitializeComponent();
        _controller = controller;
        _viewModel = new RuntimeViewModel(controller);
        DataContext = _viewModel;
        _viewModel.ErrorRequested += ViewModel_ErrorRequested;
        _viewModel.ExitRequested += (_, _) => RequestApplicationExit();
        _refreshTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _refreshTimer.Tick += async (_, _) => await _viewModel.RefreshAsync();
    }

    public RuntimeViewModel ViewModel => _viewModel;

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        _source = (HwndSource)PresentationSource.FromVisual(this)!;
        _source.AddHook(WindowHook);
        RegisterHotKey(_source.Handle, HotKeyId, ModifierControl | ModifierAlt | ModifierShift, KeyF12);
        _refreshTimer.Start();
        await _viewModel.RefreshAsync();
    }

    private async void Settings_Click(object sender, RoutedEventArgs e)
    {
        var window = new SettingsWindow(_viewModel) { Owner = this };
        window.ShowDialog();
        await _viewModel.RefreshAsync();
    }

    private async void ViewModel_ErrorRequested(object? sender, ErrorInfo error)
    {
        ShowError(error);
        await Task.CompletedTask;
    }

    public void ShowError(ErrorInfo error) => Dispatcher.Invoke(() => new ErrorDialog(error.Message, error.Details) { Owner = this }.ShowDialog());

    private IntPtr WindowHook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == WmHotKey && wParam.ToInt32() == HotKeyId)
        {
            handled = true;
            _ = _viewModel.ExecuteCommandAsync(RuntimeCommand.ExitKiosk);
            ShowPanel();
        }
        return IntPtr.Zero;
    }

    public void ShowPanel()
    {
        ShowInTaskbar = true;
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Topmost = true;
        Topmost = false;
    }

    public void PrepareForBackground()
    {
        ShowInTaskbar = false;
        Hide();
    }

    public void AllowClose() => _allowClose = true;

    private void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (!_allowClose)
        {
            e.Cancel = true;
            PrepareForBackground();
        }
        else
        {
            _refreshTimer.Stop();
            if (_source is not null) UnregisterHotKey(_source.Handle, HotKeyId);
        }
    }

    private void RequestApplicationExit()
    {
        AllowClose();
        System.Windows.Application.Current.Shutdown();
    }

    private const uint ModifierControl = 0x0002;
    private const uint ModifierAlt = 0x0001;
    private const uint ModifierShift = 0x0004;
    private const uint KeyF12 = 0x7B;
    private const int WmHotKey = 0x0312;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
