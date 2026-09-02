using System.Text.Json;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class ProvisioningState
{
    public int Schema { get; set; } = 1;
    public string AndroidImageVersion { get; set; } = string.Empty;
    public string NativeBridgeStatus { get; set; } = "unknown";
    public string WebViewVersion { get; set; } = string.Empty;
    public string TtsStatus { get; set; } = "unknown";
    public string NeoNewsVersion { get; set; } = string.Empty;
    public DateTimeOffset LastValidation { get; set; }
    public string ImageHash { get; set; } = string.Empty;
}

public sealed class AndroidProvisioningService
{
    private readonly RuntimeContext _context;
    private readonly LogService _logs;

    public AndroidProvisioningService(RuntimeContext context, LogService logs)
    {
        _context = context;
        _logs = logs;
    }

    public async Task<ProvisioningState> ValidateLocalRuntimeAsync(CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(_context.LogsDirectory);
        Directory.CreateDirectory(_context.ReportsDirectory);
        Directory.CreateDirectory(Path.GetDirectoryName(_context.ResolveProvisioningStatePath())!);

        var qemu = _context.ResolveQemuPath();
        var disk = _context.ResolveAndroidDiskPath();
        var adb = _context.ResolveAdbPath();
        var missing = new List<string>();
        if (!File.Exists(qemu)) missing.Add($"QEMU: {qemu}");
        if (!File.Exists(disk)) missing.Add($"disco Android persistente: {disk}");
        if (!File.Exists(adb) && !_context.Config.Android.Tooling.AllowEnvironmentFallback) missing.Add($"ADB: {adb}");
        if (missing.Count > 0)
        {
            throw new RuntimeOperationException(
                "O runtime local não está provisionado.",
                $"Arquivos obrigatórios ausentes:\n{string.Join("\n", missing)}\nO provisionamento deve ser feito antes da execução normal; o launcher não baixa binários pela Internet.");
        }

        var state = await LoadAsync(cancellationToken) ?? new ProvisioningState();
        state.Schema = 1;
        state.AndroidImageVersion = _context.Config.Android.Release;
        state.LastValidation = DateTimeOffset.UtcNow;
        state.ImageHash = await ComputeFingerprintAsync(disk, cancellationToken);
        await SaveAsync(state, cancellationToken);
        _logs.Info("provisioning", $"Estrutura local validada. QEMU={qemu}; disco={disk}; ADB={adb}.");
        return state;
    }

    public async Task<ProvisioningState?> LoadAsync(CancellationToken cancellationToken = default)
    {
        var path = _context.ResolveProvisioningStatePath();
        if (!File.Exists(path)) return null;
        await using var stream = File.OpenRead(path);
        return await JsonSerializer.DeserializeAsync<ProvisioningState>(stream, RuntimeContext.JsonOptions, cancellationToken);
    }

    public async Task SaveAsync(ProvisioningState state, CancellationToken cancellationToken = default)
    {
        var path = _context.ResolveProvisioningStatePath();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporaryPath = path + ".tmp";
        await File.WriteAllTextAsync(temporaryPath, JsonSerializer.Serialize(state, RuntimeContext.JsonOptions), cancellationToken);
        File.Move(temporaryPath, path, true);
    }

    private static async Task<string> ComputeFingerprintAsync(string path, CancellationToken cancellationToken)
    {
        var info = new FileInfo(path);
        // Avoid hashing a multi-gigabyte disk during every normal boot while
        // retaining a deterministic change marker in provisioning state.
        await Task.CompletedTask;
        cancellationToken.ThrowIfCancellationRequested();
        return $"{info.Length:x}-{info.LastWriteTimeUtc.Ticks:x}";
    }
}
