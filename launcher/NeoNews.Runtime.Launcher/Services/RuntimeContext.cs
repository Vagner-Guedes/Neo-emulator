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
        if (config.SchemaVersion < 2)
        {
            MigrateLegacyConfig(configPath, config);
        }
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
        return Config.Android.Tooling.AllowEnvironmentFallback
            ? FindToolInRoots("adb.exe", Config.Android.Tooling.AdbRelativePath, Path.Combine("platform-tools", "adb.exe"))
            : configured;
    }

    public string ResolveQemuPath()
    {
        var configured = ResolvePath(Config.Android.Qemu.Executable);
        return configured;
    }

    public string ResolveAndroidDiskPath() => ResolvePath(Config.Android.Qemu.Disk);

    public string ResolveAndroidImagePath() => ResolvePath(Config.Android.Qemu.AndroidImage);

    public string ResolveProvisioningPackagePath(string configuredPath) => ResolvePath(configuredPath);

    public string ResolveProvisioningStatePath() => ResolvePath(Config.Android.Provisioning.StatePath);

    public string ResolveEmulatorPath()
    {
        var configured = ResolvePath(Path.Combine(Config.Android.Tooling.SdkRoot, Config.Android.Tooling.EmulatorRelativePath));
        if (File.Exists(configured)) return configured;
        return Config.Android.Tooling.AllowEnvironmentFallback
            ? FindToolInRoots("emulator.exe", Config.Android.Tooling.EmulatorRelativePath, Path.Combine("emulator", "emulator.exe"))
            : configured;
    }

    public string ResolveApkPath()
    {
        var configured = ResolvePath(Config.NeoNews.ApkPath);
        if (File.Exists(configured)) return configured;

        // Development convenience: the supplied proprietary APK may be placed
        // at the repository root as app.apk. The publish script copies it to
        // the configured distribution path when it is present.
        var rootApk = Path.Combine(RootDirectory, "app.apk");
        return File.Exists(rootApk) ? rootApk : configured;
    }

    public async Task SaveAsync(CancellationToken cancellationToken = default)
    {
        var json = JsonSerializer.Serialize(Config, JsonOptions);
        var temporaryPath = ConfigPath + ".tmp";
        Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
        await File.WriteAllTextAsync(temporaryPath, json, cancellationToken);
        File.Move(temporaryPath, ConfigPath, true);
    }

    private static void MigrateLegacyConfig(string configPath, RuntimeConfig config)
    {
        var backupPath = configPath + ".bak";
        if (!File.Exists(backupPath)) File.Copy(configPath, backupPath);

        // Schema 1 was Android-Emulator-centric. Preserve its behavior while
        // introducing the new transport/backend fields explicitly; users can
        // opt into QEMU by changing only the backend in the migrated config.
        config.SchemaVersion = 2;
        if (string.IsNullOrWhiteSpace(config.Android.Backend) || config.Android.Backend.Equals("qemu-android-x86", StringComparison.OrdinalIgnoreCase))
            config.Android.Backend = "android-sdk-emulator";
        config.Android.Adb.Transport = "emulatorSerial";
        config.Android.Adb.EmulatorSerial = $"emulator-{config.Android.Emulator.ValidationPort}";
        if (string.IsNullOrWhiteSpace(config.Android.PreferredApkAbi))
            config.Android.PreferredApkAbi = config.Android.AbiValidation.ApkAbis.FirstOrDefault() ?? "armeabi-v7a";
        if (string.IsNullOrWhiteSpace(config.Android.NativeBridge.PreferredAbi))
            config.Android.NativeBridge.PreferredAbi = config.Android.PreferredApkAbi;

        var migratedJson = JsonSerializer.Serialize(config, JsonOptions);
        File.WriteAllText(configPath, migratedJson);
    }

    private string FindToolInRoots(string executableName, params string[] relativePaths)
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
                foreach (var relativePath in relativePaths)
                {
                    var candidate = Path.Combine(root!, relativePath.Replace('/', Path.DirectorySeparatorChar));
                    if (File.Exists(candidate)) return candidate;
                }
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
