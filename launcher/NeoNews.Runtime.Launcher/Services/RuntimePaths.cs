namespace NeoNews.Runtime.Launcher.Services;

/// <summary>
/// Centralizes every path owned by one NeoNews Runtime distribution.
/// Relative paths are always resolved from the distribution root; no host
/// SDK, emulator, or tool directory is consulted by the production launcher.
/// </summary>
public sealed class RuntimePaths
{
    public RuntimePaths(string rootDirectory, string configPath)
    {
        RootDirectory = Path.GetFullPath(rootDirectory);
        ConfigPath = Path.GetFullPath(configPath);
    }

    public string RootDirectory { get; }
    public string ConfigPath { get; }
    public string LogsDirectory => Path.Combine(RootDirectory, "logs");
    public string ReportsDirectory => Path.Combine(RootDirectory, "reports");
    public string StateDirectory => Path.Combine(RootDirectory, "runtime", "state");
    public string HostProcessStatePath => Path.Combine(StateDirectory, "host-process.json");
    public string AdbServerStatePath => Path.Combine(StateDirectory, "adb-server.json");

    public string Resolve(string configuredPath)
    {
        if (string.IsNullOrWhiteSpace(configuredPath)) return RootDirectory;
        if (Path.IsPathRooted(configuredPath)) return Path.GetFullPath(configuredPath);
        return Path.GetFullPath(Path.Combine(RootDirectory, configuredPath.Replace('/', Path.DirectorySeparatorChar)));
    }

    public string ResolveBundledTool(string sdkRoot, string relativePath)
    {
        if (Path.IsPathRooted(relativePath)) return Path.GetFullPath(relativePath);

        var candidate = Resolve(Path.Combine(sdkRoot ?? string.Empty, relativePath ?? string.Empty));
        if (File.Exists(candidate)) return candidate;

        // Compatibility for distributions that store the tool directly below
        // the root while retaining the historical sdkRoot setting.
        return Resolve(relativePath ?? string.Empty);
    }
}
