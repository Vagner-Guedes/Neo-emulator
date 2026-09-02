using System.Text.Json;
using System.Text.Json.Serialization;
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
    public string DiskFingerprint { get; set; } = string.Empty;
    [JsonPropertyName("provenance")]
    public Dictionary<string, ProvisionedComponent> Provenance { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class ProvisionedComponent
{
    public string Path { get; set; } = string.Empty;
    public string Sha256 { get; set; } = string.Empty;
    public string Origin { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
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
        var image = _context.ResolveAndroidImagePath();
        var adb = _context.ResolveAdbPath();
        var missing = new List<string>();
        if (!HasContent(qemu)) missing.Add($"QEMU ausente ou vazio: {qemu}");
        if (!HasContent(disk)) missing.Add($"disco Android persistente ausente ou vazio: {disk}");
        if (!HasContent(image)) missing.Add($"imagem Android-x86 ausente ou vazia: {image}");
        if (!HasContent(adb)) missing.Add($"ADB ausente ou vazio: {adb}");
        if (missing.Count > 0)
        {
            throw new RuntimeOperationException(
                "O runtime local não está provisionado.",
                $"Arquivos obrigatórios ausentes ou vazios:\n{string.Join("\n", missing)}\nO provisionamento deve ser feito antes da execução normal; o launcher não baixa binários pela Internet.");
        }

        var state = await LoadAsync(cancellationToken);
        if (state is null)
        {
            throw new RuntimeOperationException(
                "O provisionamento local ainda não foi registrado.",
                "Execute scripts/provision/Provision-QemuAndroidRuntime.ps1 com os componentes locais aprovados antes do boot normal.");
        }

        if (string.IsNullOrWhiteSpace(state.AndroidImageVersion) ||
            !state.AndroidImageVersion.Equals(_context.Config.Android.Release, StringComparison.OrdinalIgnoreCase))
        {
            throw new RuntimeOperationException(
                "O registro de provisionamento aponta para outra release Android.",
                $"Release registrada={state.AndroidImageVersion}; esperada={_context.Config.Android.Release}; estado={_context.ResolveProvisioningStatePath()}.");
        }
        if (!IsSha256(state.ImageHash))
        {
            throw new RuntimeOperationException(
                "O registro de provisionamento não possui SHA-256 forte do disco.",
                "Reexecute scripts/provision/Provision-QemuAndroidRuntime.ps1; o boot normal não substitui esse hash por um marcador fraco.");
        }
        if (state.Provenance is null || state.Provenance.Count == 0)
        {
            throw new RuntimeOperationException(
                "O registro de provisionamento não possui proveniência dos componentes.",
                $"Estado sem entradas de provenance: {_context.ResolveProvisioningStatePath()}.");
        }

        foreach (var componentName in new[] { "qemu", "adb", "disk", "installerImage" })
        {
            if (!state.Provenance.TryGetValue(componentName, out var component) ||
                !IsSha256(component.Sha256) ||
                string.IsNullOrWhiteSpace(component.Origin))
            {
                throw new RuntimeOperationException(
                    "O registro de provisionamento não possui hash e proveniência fortes dos componentes-base.",
                    $"Entrada ausente, sem SHA-256 ou sem origem: provenance.{componentName}; estado={_context.ResolveProvisioningStatePath()}.");
            }
        }

        var qemuHash = await ComputeSha256Async(qemu, cancellationToken);
        var adbHash = await ComputeSha256Async(adb, cancellationToken);
        var imageHash = await ComputeSha256Async(image, cancellationToken);
        var registeredQemuHash = state.Provenance["qemu"].Sha256;
        var registeredAdbHash = state.Provenance["adb"].Sha256;
        var registeredImageHash = state.Provenance["installerImage"].Sha256;
        if (!registeredQemuHash.Equals(qemuHash, StringComparison.OrdinalIgnoreCase) ||
            !registeredAdbHash.Equals(adbHash, StringComparison.OrdinalIgnoreCase) ||
            !registeredImageHash.Equals(imageHash, StringComparison.OrdinalIgnoreCase))
        {
            throw new RuntimeOperationException(
                "Os binários locais não correspondem ao provisionamento registrado.",
                $"QEMU registrado={registeredQemuHash}; atual={qemuHash}; ADB registrado={registeredAdbHash}; atual={adbHash}; imagem registrada={registeredImageHash}; atual={imageHash}. Reexecute o provisionamento após uma troca aprovada.");
        }

        state.Schema = 1;
        state.AndroidImageVersion = _context.Config.Android.Release;
        state.LastValidation = DateTimeOffset.UtcNow;
        var fingerprint = await ComputeFingerprintAsync(disk, cancellationToken);
        if (!string.IsNullOrWhiteSpace(state.DiskFingerprint) &&
            !state.DiskFingerprint.Equals(fingerprint, StringComparison.OrdinalIgnoreCase))
        {
            // qcow2 is the mutable data store: Android, NeoNews, WebView and
            // TTS legitimately update it during normal operation. The cheap
            // fingerprint is retained as an audit trail, but must not turn a
            // valid guest write into a boot blocker.
            _logs.Warning("provisioning", $"Fingerprint do qcow2 mudou desde a última validação; aceitando a mutação persistente. anterior={state.DiskFingerprint}; atual={fingerprint}; disco={disk}.");
        }
        state.DiskFingerprint = fingerprint;
        // Provision-QemuAndroidRuntime.ps1 records the strong SHA-256 in
        // ImageHash. Keep it intact; DiskFingerprint is only a cheap,
        // last-observed change marker for this mutable qcow2.
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

    private static async Task<string> ComputeSha256Async(string path, CancellationToken cancellationToken)
    {
        await using var stream = File.OpenRead(path);
        return Convert.ToHexString(await System.Security.Cryptography.SHA256.HashDataAsync(stream, cancellationToken));
    }

    private static bool IsSha256(string? value) =>
        !string.IsNullOrWhiteSpace(value) && value.Length == 64 && value.All(Uri.IsHexDigit);

    private static bool HasContent(string path)
    {
        try { return File.Exists(path) && new FileInfo(path).Length > 0; }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }
}
