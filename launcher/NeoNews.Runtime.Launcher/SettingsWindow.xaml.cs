using System.Windows;
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
        AutoKiosk.IsChecked = viewModel.AutoKiosk;
        Watchdog.IsChecked = viewModel.WatchdogEnabled;
        WidthInput.Text = viewModel.ScreenWidth.ToString();
        HeightInput.Text = viewModel.ScreenHeight.ToString();
        DensityInput.Text = viewModel.Density.ToString();
        Gpu.SelectedValue = viewModel.GpuMode;
    }

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(WidthInput.Text, out var width) || !int.TryParse(HeightInput.Text, out var height) || !int.TryParse(DensityInput.Text, out var density) || width < 640 || height < 480 || density < 80)
        {
            new ErrorDialog("Valores de tela inválidos.", "Informe largura, altura e densidade numéricas. A largura mínima é 640, a altura mínima é 480 e a densidade mínima é 80.") { Owner = this }.ShowDialog();
            return;
        }

        try
        {
            var gpu = (Gpu.SelectedItem as System.Windows.Controls.ComboBoxItem)?.Content?.ToString() ?? "swiftshader";
            await _viewModel.ApplySettingsAsync(StartWithWindows.IsChecked == true, AutoKiosk.IsChecked == true, Watchdog.IsChecked == true, width, height, density, gpu);
            DialogResult = true;
        }
        catch (Exception exception)
        {
            new ErrorDialog("Não foi possível salvar a configuração.", exception.ToString()) { Owner = this }.ShowDialog();
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
