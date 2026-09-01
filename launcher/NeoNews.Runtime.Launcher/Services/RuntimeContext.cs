using System.Text.Json;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class RuntimeContext
{
    private RuntimeContext(string rootDirectory, string configPath, RuntimeConfig config)
    {
        RootDirectory = rootDirectory;
        ConfigPath = configPath;
        Config = config;
    }

    public string RootDirectory { get; }
    public string ConfigPath { get; }
    public RuntimeConfig Config { get; }
    public string LogsDirectory => Path.Combine(RootDirectory, "logs");
    public string ReportsDirectory => Path.Combine(RootDirectory, "reports");

    public static RuntimeContext Load(string? explicitConfigPath = null)
    {
        var configPath = FindConfigPath(explicitConfigPath);
        var json = File.ReadAllText(configPath);
        var config = JsonSerializer.Deserialize<RuntimeConfig>(json, JsonOptions) ?? new RuntimeConfig();
        var root = Directory.GetParent(configPath)?.Parent?.FullName ?? Directory.GetCurrentDirectory();
        return new RuntimeContext(root, configPath, config);
    }

    public string ResolvePath(string configuredPath)
    {
        if (Path.IsPathRooted(configuredPath))
        {
            return configuredPath;
        }

        return Path.GetFullPath(Path.Combine(RootDirectory, configuredPath.Replace('/', Path.DirectorySeparatorChar)));
    }

    public string ResolveAdbPath()
    {
        var configured = ResolvePath(Path.Combine(Config.Android.Tooling.SdkRoot, Config.Android.Tooling.AdbRelativePath));
        if (File.Exists(configured)) return configured;
        return FindToolInRoots("adb.exe", Config.Android.Tooling.AdbRelativePath);
    }

    public string ResolveEmulatorPath()
    {
        var configured = ResolvePath(Path.Combine(Config.Android.Tooling.SdkRoot, Config.Android.Tooling.EmulatorRelativePath));
        if (File.Exists(configured)) return configured;
        return FindToolInRoots("emulator.exe", Config.Android.Tooling.EmulatorRelativePath);
    }

    public string ResolveApkPath() => ResolvePath(Config.NeoNews.ApkPath);

    public async Task SaveAsync(CancellationToken cancellationToken = default)
    {
        var json = JsonSerializer.Serialize(Config, JsonOptions);
        var temporaryPath = ConfigPath + ".tmp";
        await File.WriteAllTextAsync(temporaryPath, json, cancellationToken);
        File.Move(temporaryPath, ConfigPath, true);
    }

    private string FindToolInRoots(string executableName, string relativePath)
    {
        if (Config.Android.Tooling.AllowEnvironmentFallback)
        {
            var roots = new[]
            {
                Environment.GetEnvironmentVariable("ANDROID_SDK_ROOT"),
                Environment.GetEnvironmentVariable("ANDROID_HOME"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Android", "Sdk")
            };
            foreach (var root in roots.Where(path => !string.IsNullOrWhiteSpace(path)))
            {
                var candidate = Path.Combine(root!, relativePath.Replace('/', Path.DirectorySeparatorChar));
                if (File.Exists(candidate)) return candidate;
            }
        }

        return executableName;
    }

    private static string FindConfigPath(string? explicitConfigPath)
    {
        if (!string.IsNullOrWhiteSpace(explicitConfigPath))
        {
            var explicitPath = Path.GetFullPath(explicitConfigPath);
            if (!File.Exists(explicitPath)) throw new FileNotFoundException("Configuração não encontrada.", explicitPath);
            return explicitPath;
        }

        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var adjacent = Path.Combine(directory.FullName, "config", "runtime.json");
            if (File.Exists(adjacent)) return adjacent;
            directory = directory.Parent;
        }

        throw new FileNotFoundException("config/runtime.json não foi encontrado a partir do launcher.");
    }

    public static JsonSerializerOptions JsonOptions { get; } = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };
}
