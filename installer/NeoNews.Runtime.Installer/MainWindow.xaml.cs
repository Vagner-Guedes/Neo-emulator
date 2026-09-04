using System.Diagnostics;
using System.IO;
using System.Windows;

namespace NeoNews.Runtime.Installer;

public partial class MainWindow : Window
{
    private readonly string _payloadRoot;
    private readonly string _defaultDestination;
    private bool _installed;

    public MainWindow()
    {
        InitializeComponent();
        _payloadRoot = ResolvePayloadRoot();
        _defaultDestination = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "NeoNewsRuntime");
        DestinationBox.Text = ResolveArgument("--target") ?? _defaultDestination;
        PayloadLabel.Text = Directory.Exists(_payloadRoot)
            ? $"Payload autorizado: {_payloadRoot}"
            : "Payload nao encontrado. Distribua esta pasta junto com NeoNewsRuntime-current.";
    }

    private async void Install_Click(object sender, RoutedEventArgs e)
    {
        if (_installed) return;
        var destination = Path.GetFullPath(DestinationBox.Text.Trim());
        if (!Directory.Exists(_payloadRoot))
        {
            MessageBox.Show(this, "O payload do NeoNews Runtime nao foi encontrado.", "Instalacao", MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }
        if (PathsOverlap(_payloadRoot, destination))
        {
            MessageBox.Show(this, "O destino nao pode ser a propria pasta do payload.", "Instalacao", MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        SetBusy(true);
        try
        {
            var files = Directory.EnumerateFiles(_payloadRoot, "*", SearchOption.AllDirectories).ToArray();
            var progress = new Progress<(int completed, int total, string relative)>();
            progress.ProgressChanged += (_, value) =>
            {
                InstallProgress.Value = value.total == 0 ? 100 : value.completed * 100.0 / value.total;
                StatusLabel.Text = $"Copiando {value.relative} ({value.completed}/{value.total})";
            };
            await Task.Run(() => CopyPayload(files, _payloadRoot, destination, progress));
            _installed = true;
            InstallProgress.Value = 100;
            StatusLabel.Text = $"Instalacao concluida em {destination}.";
            CloseButton.IsEnabled = true;
            InstallButton.Content = "Instalado";
        }
        catch (Exception exception)
        {
            StatusLabel.Text = "A instalacao falhou.";
            MessageBox.Show(this, exception.Message, "Instalacao", MessageBoxButton.OK, MessageBoxImage.Error);
            SetBusy(false);
        }
    }

    private static void CopyPayload(string[] files, string sourceRoot, string destinationRoot, IProgress<(int completed, int total, string relative)> progress)
    {
        Directory.CreateDirectory(destinationRoot);
        var completed = 0;
        foreach (var file in files)
        {
            var attributes = File.GetAttributes(file);
            if ((attributes & FileAttributes.ReparsePoint) != 0) continue;
            var relative = Path.GetRelativePath(sourceRoot, file);
            var target = Path.Combine(destinationRoot, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target, true);
            completed++;
            progress.Report((completed, files.Length, relative));
        }
    }

    private void SetBusy(bool busy)
    {
        InstallButton.IsEnabled = !busy;
        DestinationBox.IsEnabled = !busy;
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();

    private string ResolvePayloadRoot()
    {
        var explicitPayload = ResolveArgument("--payload");
        var candidates = new[]
        {
            explicitPayload,
            Path.Combine(AppContext.BaseDirectory, "..", "NeoNewsRuntime-current"),
            Path.Combine(AppContext.BaseDirectory, ".."),
            Path.Combine(AppContext.BaseDirectory, "payload")
        };
        return candidates
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .Select(path => Path.GetFullPath(path!))
            .FirstOrDefault(path => File.Exists(Path.Combine(path, "NeoNewsRuntime.exe")) && File.Exists(Path.Combine(path, "config", "runtime.json")))
            ?? Path.GetFullPath(candidates.FirstOrDefault(path => !string.IsNullOrWhiteSpace(path)) ?? AppContext.BaseDirectory);
    }

    private static string? ResolveArgument(string name)
    {
        var prefix = name + "=";
        return Environment.GetCommandLineArgs()
            .Skip(1)
            .FirstOrDefault(argument => argument.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))?
            .Substring(prefix.Length)
            .Trim('"');
    }

    private static bool PathsOverlap(string left, string right)
    {
        var a = Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var b = Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return a.StartsWith(b, StringComparison.OrdinalIgnoreCase) || b.StartsWith(a, StringComparison.OrdinalIgnoreCase);
    }
}
