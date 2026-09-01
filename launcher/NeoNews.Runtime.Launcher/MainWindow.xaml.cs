using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows;

namespace NeoNews.Runtime.Launcher;

public partial class MainWindow : Window
{
    private readonly string _repositoryRoot;
    private bool _busy;

    public MainWindow()
    {
        InitializeComponent();
        _repositoryRoot = FindRepositoryRoot();
        StatusText.Text = $"Pronto • {_repositoryRoot}";
    }

    private async void StartNeoNews_Click(object sender, RoutedEventArgs e)
    {
        await RunActionAsync(
            "Iniciando NeoNews...",
            "scripts/runtime/Start-NeoNews.ps1",
            "-StartEmulator", "-Launch", "-ReportPath", Path.Combine("reports", "launcher-neonews.json"));
    }

    private async void ApplyKiosk_Click(object sender, RoutedEventArgs e)
    {
        await RunActionAsync(
            "Aplicando configuração kiosk...",
            "scripts/runtime/Apply-KioskSettings.ps1",
            "-ReportPath", Path.Combine("reports", "launcher-kiosk.json"));
    }

    private async void Diagnostics_Click(object sender, RoutedEventArgs e)
    {
        await RunActionAsync(
            "Coletando baseline do runtime...",
            "scripts/benchmark/Measure-AndroidRuntime.ps1",
            "-StartEmulator", "-StopEmulator", "-ReportPath", Path.Combine("reports", "launcher-diagnostics.json"));
    }

    private void Exit_Click(object sender, RoutedEventArgs e)
    {
        Close();
    }

    private async Task RunActionAsync(string status, string relativeScript, params string[] arguments)
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        StatusText.Text = status;
        try
        {
            var scriptPath = Path.Combine(_repositoryRoot, relativeScript.Replace('/', Path.DirectorySeparatorChar));
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException("Script do runtime não encontrado.", scriptPath);
            }

            var result = await RunPowerShellAsync(scriptPath, arguments);
            OutputText.Text = result.Output;
            StatusText.Text = result.ExitCode == 0
                ? "Concluído"
                : $"Falha • código {result.ExitCode}";
        }
        catch (Exception exception)
        {
            OutputText.Text = exception.ToString();
            StatusText.Text = "Falha ao executar ação";
        }
        finally
        {
            _busy = false;
        }
    }

    private static async Task<(int ExitCode, string Output)> RunPowerShellAsync(string scriptPath, IEnumerable<string> arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = FindPowerShell(),
            WorkingDirectory = Path.GetDirectoryName(scriptPath) ?? AppContext.BaseDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(scriptPath);
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Não foi possível iniciar o PowerShell.");
        var standardOutput = process.StandardOutput.ReadToEndAsync();
        var standardError = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        var output = new StringBuilder()
            .AppendLine(await standardOutput)
            .AppendLine(await standardError)
            .ToString()
            .Trim();
        return (process.ExitCode, output);
    }

    private static string FindPowerShell()
    {
        var pwsh = Environment.GetEnvironmentVariable("PATH")?
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(path => Path.Combine(path, "pwsh.exe"))
            .FirstOrDefault(File.Exists);
        return pwsh ?? "powershell.exe";
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "config", "runtime.json")))
            {
                return directory.FullName;
            }
            directory = directory.Parent;
        }

        return Directory.GetCurrentDirectory();
    }
}
