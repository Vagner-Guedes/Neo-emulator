using System.Windows;
using System.Windows.Controls;

namespace NeoNews.Runtime.Launcher.Views;

public partial class SettingsView : System.Windows.Controls.UserControl
{
    public SettingsView() => InitializeComponent();

    private void SettingsRow_Click(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is MainWindow window) window.OpenSettingsDialog();
    }
}
