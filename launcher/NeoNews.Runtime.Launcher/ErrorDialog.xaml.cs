using System.Windows;

namespace NeoNews.Runtime.Launcher;

public partial class ErrorDialog : Window
{
    public ErrorDialog(string message, string details)
    {
        InitializeComponent();
        MessageText.Text = message;
        DetailsText.Text = details;
    }

    private void Copy_Click(object sender, RoutedEventArgs e) => System.Windows.Clipboard.SetText(DetailsText.Text);
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
