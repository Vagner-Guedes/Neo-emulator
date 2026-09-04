using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using NeoNews.Runtime.Launcher.Models;
using NeoNews.Runtime.Launcher.Services;
using NeoNews.Runtime.Launcher.ViewModels;
using NeoNews.Runtime.Launcher.Views;
using WpfUserControl = System.Windows.Controls.UserControl;

namespace NeoNews.Runtime.Launcher;

public partial class MainWindow : Window
{
    private const int HotKeyId = 0x4E52;
    private readonly RuntimeViewModel _viewModel;
    private readonly RuntimeController _controller;
    private readonly DispatcherTimer _refreshTimer;
    private readonly DispatcherTimer _clockTimer;
    private readonly HotkeyService _hotkeyService = new(HotKeyId);
    private readonly HotkeyService _stopRuntimeHotkey = new(HotKeyId + 1);
    private readonly HotkeyService _toggleFullscreenHotkey = new(HotKeyId + 2);
    private readonly Dictionary<string, WpfUserControl> _pages = new(StringComparer.OrdinalIgnoreCase);
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
        _clockTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _clockTimer.Tick += (_, _) => _viewModel.Tick();
        BuildPages();
        _controller.Logs.Info("launcher", "Janela principal construída.");
    }

    public RuntimeViewModel ViewModel => _viewModel;
    public bool SuppressErrors { get; set; }

    private void BuildPages()
    {
        _pages["Home"] = new HomeView { DataContext = _viewModel };
        _pages["Runtime"] = new RuntimeView { DataContext = _viewModel };
        _pages["NeoNews"] = new NeoNewsView { DataContext = _viewModel };
        _pages["Diagnostics"] = new DiagnosticsView { DataContext = _viewModel };
        _pages["Settings"] = new SettingsView { DataContext = _viewModel };
        PageHost.Content = _pages["Home"];
    }

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        _controller.Logs.Info("launcher", "Janela principal carregada.");
        _source = (HwndSource)PresentationSource.FromVisual(this)!;
        _source.AddHook(WindowHook);
        RegisterOperationalHotkey(_stopRuntimeHotkey, _controller.Context.Config.Runtime.StopRuntimeHotkey, "parar runtime");
        RegisterOperationalHotkey(_toggleFullscreenHotkey, _controller.Context.Config.Runtime.ToggleFullscreenHotkey, "alternar fullscreen");
        if (!_hotkeyService.Register(_source.Handle, _controller.Context.Config.Runtime.Hotkey))
            _controller.Logs.Warning("launcher", $"Hotkey inválida ou indisponível: {_controller.Context.Config.Runtime.Hotkey}");
        _refreshTimer.Start();
        _clockTimer.Start();
        Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(async () => await _viewModel.RefreshAsync()));
    }

    private void Navigation_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not ToggleButton button || button.Tag is not string pageName) return;
        foreach (var item in new[] { NavHome, NavRuntime, NavNeoNews, NavDiagnostics, NavSettings })
            item.IsChecked = ReferenceEquals(item, button);
        if (_pages.TryGetValue(pageName, out var page)) PageHost.Content = page;
    }

    public void OpenSettingsDialog()
    {
        var window = new SettingsWindow(_viewModel) { Owner = this };
        window.ShowDialog();
        RefreshHotkey();
        _ = _viewModel.RefreshAsync();
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        if (e.ClickCount == 2)
        {
            ToggleMaximize();
            return;
        }
        try { DragMove(); } catch (InvalidOperationException) { }
    }

    private void Minimize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void MinimizePanel_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void Maximize_Click(object sender, RoutedEventArgs e) => ToggleMaximize();
    private void ToggleMaximize() => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    private void Close_Click(object sender, RoutedEventArgs e) => Close();

    public void RefreshHotkey()
    {
        if (_source is not null && !_hotkeyService.Register(_source.Handle, _controller.Context.Config.Runtime.Hotkey))
            _controller.Logs.Warning("launcher", $"Hotkey inválida ou indisponível: {_controller.Context.Config.Runtime.Hotkey}");
    }

    private void ViewModel_ErrorRequested(object? sender, ErrorInfo error) => ShowError(error);

    public void ShowError(ErrorInfo error)
    {
        if (SuppressErrors)
        {
            _controller.Logs.Warning("launcher", $"Erro em modo background: {error.Message}");
            return;
        }
        Dispatcher.BeginInvoke(DispatcherPriority.Normal, new Action(() =>
        {
            if (!IsVisible) Show();
            var dialog = new ErrorDialog(error.Message, error.Details) { Owner = this };
            dialog.ShowDialog();
        }));
    }

    private IntPtr WindowHook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (_stopRuntimeHotkey.IsHotKeyMessage(message, wParam, lParam))
        {
            handled = true;
            _ = _viewModel.ExecuteCommandAsync(RuntimeCommand.Stop);
        }
        else if (_toggleFullscreenHotkey.IsHotKeyMessage(message, wParam, lParam))
        {
            handled = true;
            _ = _viewModel.ExecuteCommandAsync(_controller.IsKioskActive ? RuntimeCommand.ExitKiosk : RuntimeCommand.Kiosk);
        }
        else if (_hotkeyService.IsHotKeyMessage(message, wParam, lParam))
        {
            handled = true;
            _ = _viewModel.ExecuteCommandAsync(RuntimeCommand.ExitKiosk);
            ShowPanel();
        }
        return IntPtr.Zero;
    }

    private void RegisterOperationalHotkey(HotkeyService service, string specification, string purpose)
    {
        if (!service.Register(_source!.Handle, specification))
            _controller.Logs.Warning("launcher", $"Hotkey de {purpose} indisponivel: {specification}; Win32Error={service.LastRegistrationError}");
        else
            _controller.Logs.Info("launcher", $"Hotkey de {purpose} registrada: {specification}.");
    }

    public void ShowPanel()
    {
        SuppressErrors = false;
        _controller.Logs.Info("launcher", $"Solicitação para exibir painel. Visível antes: {IsVisible}.");
        ShowInTaskbar = true;
        Visibility = Visibility.Visible;
        if (!IsVisible)
        {
            Dispatcher.BeginInvoke(DispatcherPriority.Normal, new Action(() =>
            {
                if (!IsVisible) Show();
                FocusPanel();
            }));
            return;
        }
        FocusPanel();
    }

    private void FocusPanel()
    {
        _controller.Logs.Info("launcher", $"Painel exibido. Visível depois: {IsVisible}, handle: {(new WindowInteropHelper(this)).Handle}.");
        Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() =>
        {
            if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
            Activate();
            Topmost = true;
            Topmost = false;
        }));
    }

    public void PrepareForBackground()
    {
        ShowInTaskbar = false;
        if (!IsLoaded)
        {
            Visibility = Visibility.Hidden;
            Show();
        }
        else Hide();
    }

    public void AllowClose() => _allowClose = true;

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (!_allowClose)
        {
            _controller.Logs.Info("launcher", "Fechamento convertido para modo tray.");
            e.Cancel = true;
            PrepareForBackground();
        }
        else
        {
            _controller.Logs.Info("launcher", "Janela autorizada a fechar.");
            _refreshTimer.Stop();
            _clockTimer.Stop();
            _hotkeyService.Dispose();
            _stopRuntimeHotkey.Dispose();
            _toggleFullscreenHotkey.Dispose();
        }
    }

    private void RequestApplicationExit()
    {
        if (System.Windows.Application.Current is App app) app.RequestExit();
        else System.Windows.Application.Current.Shutdown();
    }
}
