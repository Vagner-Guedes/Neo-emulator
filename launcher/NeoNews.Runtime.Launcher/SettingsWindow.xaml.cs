using System.Windows;
using NeoNews.Runtime.Launcher.Services;
using NeoNews.Runtime.Launcher.ViewModels;

namespace NeoNews.Runtime.Launcher;

public partial class SettingsWindow : Window
{
    private readonly RuntimeViewModel _viewModel;

    public SettingsWindow(RuntimeViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        StartWithWindows.IsChecked = viewModel.StartWithWindows;
        StartNeoNews.IsChecked = viewModel.StartNeoNews;
        AutoKiosk.IsChecked = viewModel.AutoKiosk;
        Watchdog.IsChecked = viewModel.WatchdogEnabled;
        WidthInput.Text = viewModel.ScreenWidth.ToString();
        HeightInput.Text = viewModel.ScreenHeight.ToString();
        DensityInput.Text = viewModel.Density.ToString();
        Gpu.SelectedIndex = Array.FindIndex(new[] { "swiftshader", "host", "auto" }, value => value.Equals(viewModel.GpuMode, StringComparison.OrdinalIgnoreCase));
        MonitorInput.Text = viewModel.MonitorIndex.ToString();
        Profile.SelectedIndex = Array.FindIndex(new[] { "signage-landscape", "balanced", "performance" }, value => value.Equals(viewModel.PerformanceProfile, StringComparison.OrdinalIgnoreCase));
        HotkeyInput.Text = viewModel.Hotkey;
    }

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(WidthInput.Text, out var width) || !int.TryParse(HeightInput.Text, out var height) || !int.TryParse(DensityInput.Text, out var density) || !int.TryParse(MonitorInput.Text, out var monitor) || width < 640 || height < 480 || density < 80 || monitor < 0)
        {
            new ErrorDialog("Valores de tela inválidos.", "Informe largura, altura e densidade numéricas. A largura mínima é 640, a altura mínima é 480 e a densidade mínima é 80.") { Owner = this }.ShowDialog();
            return;
        }

        if (!HotkeyService.TryParse(HotkeyInput.Text, out _, out _))
        {
            new ErrorDialog("Hotkey inválida.", "Use um formato como Ctrl+Alt+Shift+F12.") { Owner = this }.ShowDialog();
            return;
        }

        try
        {
            var gpu = (Gpu.SelectedItem as System.Windows.Controls.ComboBoxItem)?.Content?.ToString() ?? "swiftshader";
            var profile = (Profile.SelectedItem as System.Windows.Controls.ComboBoxItem)?.Content?.ToString() ?? "signage-landscape";
            await _viewModel.ApplySettingsAsync(StartWithWindows.IsChecked == true, StartNeoNews.IsChecked == true, AutoKiosk.IsChecked == true, Watchdog.IsChecked == true, width, height, density, gpu, monitor, profile, HotkeyInput.Text.Trim());
            DialogResult = true;
        }
        catch (Exception exception)
        {
            new ErrorDialog("Não foi possível salvar a configuração.", exception.ToString()) { Owner = this }.ShowDialog();
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
