using System.Text.Json;
using System.Text.Json.Serialization;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class ProvisioningState
{
    public int Schema { get; set; } = 1;
    public string Stage { get; set; } = "NotOptimized";
    public bool Completed { get; set; }
    public bool PackageManagerReady { get; set; }
    public bool SettingsProviderReady { get; set; }
    public bool LocaleValidated { get; set; }
    public bool RebootPerformed { get; set; }
    public bool NeoNewsInstalled { get; set; }
    public bool NeoNewsRunning { get; set; }
    public bool KioskActive { get; set; }
    public bool WatchdogActive { get; set; }
    public DateTimeOffset LastAttempt { get; set; }
    public string LastError { get; set; } = string.Empty;
    public string AndroidImageVersion { get; set; } = string.Empty;
    public string NativeBridgeStatus { get; set; } = "unknown";
    public string GuestConfigurationStatus { get; set; } = "unknown";
    public string AndroidSetupStatus { get; set; } = "unknown";
    public string GuestNetworkStatus { get; set; } = "unknown";
    public string NeoNewsSuperuserStatus { get; set; } = "unknown";
    public string GuestInitScriptSha256 { get; set; } = string.Empty;
    public string WebViewVersion { get; set; } = string.Empty;
    public string TtsStatus { get; set; } = "unknown";
    public string NeoNewsVersion { get; set; } = string.Empty;
    public DateTimeOffset LastValidation { get; set; }
    // ImageHash is retained as a backwards-compatible alias for the approved
    // baseline. A persistent guest disk is expected to change after Android,
    // NeoNews or a component writes to /data, so its live SHA must never be
    // compared to this value as a normal-boot gate.
    public string ImageHash { get; set; } = string.Empty;
    public string BaselineSha256 { get; set; } = string.Empty;
    public string DiskFingerprint { get; set; } = string.Empty;
    public string DiskMutationStatus { get; set; } = "unknown";
    public ActiveDiskMetadata ActiveDiskMetadata { get; set; } = new();
    public int Attempt { get; set; }
    public string LastSuccessfulStage { get; set; } = string.Empty;
    public DateTimeOffset BootStartedAt { get; set; }
    public DateTimeOffset AdbLastOnline { get; set; }
    public bool RebootRequired { get; set; }
    public bool ResumeAllowed { get; set; } = true;
    [JsonPropertyName("provenance")]
    public Dictionary<string, ProvisionedComponent> Provenance { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class ActiveDiskMetadata
{
    public string Role { get; set; } = "persistent-guest-disk";
    public string Path { get; set; } = string.Empty;
    public string Format { get; set; } = string.Empty;
    public long VirtualSizeBytes { get; set; }
    public long ActualSizeBytes { get; set; }
    public long FileLengthBytes { get; set; }
    public string BackingFile { get; set; } = string.Empty;
    public bool Corrupt { get; set; }
    public bool DirtyFlag { get; set; }
    public int CheckErrors { get; set; }
    public long AllocatedClusters { get; set; }
    public long FragmentedClusters { get; set; }
    public string CurrentSha256 { get; set; } = string.Empty;
    public string Status { get; set; } = "unknown";
    public DateTimeOffset ObservedAt { get; set; }
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
    private readonly ProcessRunnerService _runner;
    private readonly LogService _logs;
    private readonly SemaphoreSlim _stateSaveGate = new(1, 1);

    public AndroidProvisioningService(RuntimeContext context, ProcessRunnerService runner, LogService logs)
    {
        _context = context;
        _runner = runner;
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
        var baselineSha256 = IsSha256(state.BaselineSha256)
            ? state.BaselineSha256
            : state.ImageHash;
        if (!IsSha256(baselineSha256))
        {
            throw new RuntimeOperationException(
                "O registro de provisionamento não possui SHA-256 forte do baseline.",
                "Reexecute scripts/provision/Provision-QemuAndroidRuntime.ps1; o baseline aprovado precisa ser registrado antes do boot normal.");
        }
        if (IsSha256(state.BaselineSha256) && IsSha256(state.ImageHash) &&
            !state.BaselineSha256.Equals(state.ImageHash, StringComparison.OrdinalIgnoreCase))
        {
            throw new RuntimeOperationException(
                "O estado de integridade do disco é inconsistente.",
                $"baselineSha256={state.BaselineSha256}; imageHash legado={state.ImageHash}. Reexecute o provisionamento aprovado para reconstruir o estado, sem substituir o qcow2 automaticamente.");
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
        var registeredQemuHash = state.Provenance["qemu"].Sha256;
        var registeredAdbHash = state.Provenance["adb"].Sha256;
        var registeredImageHash = state.Provenance["installerImage"].Sha256;
        var imageHash = await ComputeSha256Async(image, cancellationToken);
        if (!registeredQemuHash.Equals(qemuHash, StringComparison.OrdinalIgnoreCase) ||
            !registeredAdbHash.Equals(adbHash, StringComparison.OrdinalIgnoreCase) ||
            !registeredImageHash.Equals(imageHash, StringComparison.OrdinalIgnoreCase))
        {
            throw new RuntimeOperationException(
                "Os binários locais não correspondem ao provisionamento registrado.",
                $"QEMU registrado={registeredQemuHash}; atual={qemuHash}; ADB registrado={registeredAdbHash}; atual={adbHash}; imagem registrada={registeredImageHash}; atual={imageHash}. Reexecute o provisionamento após uma troca aprovada.");
        }

        var qemuImg = Path.Combine(Path.GetDirectoryName(qemu) ?? _context.RootDirectory, "qemu-img.exe");
        if (!HasContent(qemuImg))
        {
            throw new RuntimeOperationException(
                "O validador qemu-img não está disponível.",
                $"Caminho esperado: {qemuImg}. A distribuição precisa manter qemu-img.exe ao lado de qemu-system-x86_64.exe.");
        }

        var activeDisk = await ReadActiveDiskMetadataAsync(qemuImg, disk, cancellationToken);
        var fingerprint = await ComputeFingerprintAsync(disk, cancellationToken);
        var previousActive = state.ActiveDiskMetadata ?? new ActiveDiskMetadata();
        var currentDiskHash = previousActive.CurrentSha256 is { Length: 64 } &&
                              previousActive.Path.Equals(_context.Config.Android.Qemu.Disk, StringComparison.OrdinalIgnoreCase) &&
                              string.Equals(state.DiskFingerprint, fingerprint, StringComparison.OrdinalIgnoreCase)
            ? previousActive.CurrentSha256
            : await ComputeSha256Async(disk, cancellationToken);

        var expectedVirtualSize = previousActive.VirtualSizeBytes;
        var structuralFailure = !activeDisk.Format.Equals("qcow2", StringComparison.OrdinalIgnoreCase) ||
                                activeDisk.CheckErrors != 0 ||
                                activeDisk.Corrupt ||
                                activeDisk.DirtyFlag ||
                                !string.IsNullOrWhiteSpace(activeDisk.BackingFile) ||
                                (expectedVirtualSize > 0 && activeDisk.VirtualSizeBytes != expectedVirtualSize);
        activeDisk.Path = _context.Config.Android.Qemu.Disk;
        activeDisk.CurrentSha256 = currentDiskHash;
        activeDisk.ObservedAt = DateTimeOffset.UtcNow;
        activeDisk.Status = structuralFailure
            ? "UNEXPECTED_IMAGE_MUTATION"
            : currentDiskHash.Equals(baselineSha256, StringComparison.OrdinalIgnoreCase)
                ? "BASELINE_UNCHANGED"
                : "EXPECTED_PERSISTENT_MUTATION";

        state.Schema = 1;
        state.AndroidImageVersion = _context.Config.Android.Release;
        state.LastValidation = DateTimeOffset.UtcNow;
        if (!string.IsNullOrWhiteSpace(state.DiskFingerprint) &&
            !state.DiskFingerprint.Equals(fingerprint, StringComparison.OrdinalIgnoreCase))
        {
            // qcow2 is the mutable data store: Android, NeoNews, WebView and
            // TTS legitimately update it during normal operation. The cheap
            // fingerprint is retained as an audit trail, but must not turn a
            // valid guest write into a boot blocker.
            _logs.Warning("provisioning", $"Fingerprint do qcow2 mudou desde a última validação; aceitando a mutação persistente. anterior={state.DiskFingerprint}; atual={fingerprint}; disco={disk}.");
        }
        state.BaselineSha256 = baselineSha256;
        state.ImageHash = baselineSha256;
        state.DiskFingerprint = fingerprint;
        state.ActiveDiskMetadata = activeDisk;
        state.DiskMutationStatus = activeDisk.Status;
        if (structuralFailure)
        {
            await SaveAsync(state, cancellationToken);
            throw new RuntimeOperationException(
                "O qcow2 persistente falhou na validação estrutural.",
                $"UNEXPECTED_IMAGE_MUTATION; format={activeDisk.Format}; virtualSizeBytes={activeDisk.VirtualSizeBytes}; expectedVirtualSizeBytes={expectedVirtualSize}; backingFile={activeDisk.BackingFile}; corrupt={activeDisk.Corrupt}; dirtyFlag={activeDisk.DirtyFlag}; checkErrors={activeDisk.CheckErrors}.");
        }
        await SaveAsync(state, cancellationToken);
        _logs.Info("provisioning", $"Estrutura local validada. diskMutationStatus={activeDisk.Status}; QEMU={qemu}; disco={disk}; ADB={adb}.");
        return state;
    }

    public async Task<ProvisioningState?> LoadAsync(CancellationToken cancellationToken = default)
    {
        var path = _context.ResolveProvisioningStatePath();
        if (!File.Exists(path)) return null;
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, useAsync: true);
        return await JsonSerializer.DeserializeAsync<ProvisioningState>(stream, RuntimeContext.JsonOptions, cancellationToken);
    }

    public async Task SaveAsync(ProvisioningState state, CancellationToken cancellationToken = default)
    {
        var path = _context.ResolveProvisioningStatePath();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporaryPath = $"{path}.{Environment.ProcessId}.{Guid.NewGuid():N}.tmp";
        await _stateSaveGate.WaitAsync(cancellationToken);
        try
        {
            await File.WriteAllTextAsync(temporaryPath, JsonSerializer.Serialize(state, RuntimeContext.JsonOptions), cancellationToken);
            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    File.Move(temporaryPath, path, true);
                    break;
                }
                catch (IOException) when (attempt < 5)
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(100 * (attempt + 1)), cancellationToken);
                }
                catch (UnauthorizedAccessException) when (attempt < 5)
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(100 * (attempt + 1)), cancellationToken);
                }
            }
        }
        finally
        {
            _stateSaveGate.Release();
            try { if (File.Exists(temporaryPath)) File.Delete(temporaryPath); } catch { }
        }
    }

    public async Task SetStageAsync(string stage, CancellationToken cancellationToken = default)
    {
        var state = await LoadAsync(cancellationToken) ?? new ProvisioningState();
        state.Stage = stage;
        state.LastAttempt = DateTimeOffset.UtcNow;
        if (stage.Equals("HOST_VALIDATION", StringComparison.OrdinalIgnoreCase))
        {
            state.Attempt++;
            state.Completed = false;
            state.LastError = string.Empty;
            state.ResumeAllowed = true;
            state.RebootRequired = false;
        }
        if (stage.Equals("ANDROID_START", StringComparison.OrdinalIgnoreCase))
        {
            state.BootStartedAt = DateTimeOffset.UtcNow;
            state.AdbLastOnline = default;
        }
        switch (stage.ToUpperInvariant())
        {
            case "PACKAGE_MANAGER_READY":
                state.PackageManagerReady = true;
                break;
            case "SETTINGS_PROVIDER_READY":
                state.PackageManagerReady = true;
                state.SettingsProviderReady = true;
                break;
            case "LOCALE_VALIDATION":
                state.LocaleValidated = true;
                break;
            case "NEONEWS_INSTALL_VALIDATION":
                state.NeoNewsInstalled = true;
                break;
            case "NEONEWS_RUNTIME_VALIDATION":
                state.NeoNewsInstalled = true;
                state.NeoNewsRunning = true;
                break;
            case "KIOSK":
                state.KioskActive = true;
                break;
            case "WATCHDOG":
                state.WatchdogActive = true;
                break;
        }
        if (stage.Equals("Ready", StringComparison.OrdinalIgnoreCase))
        {
            state.Completed = true;
            state.LastError = string.Empty;
        }
        else if (stage.Equals("Error", StringComparison.OrdinalIgnoreCase))
        {
            state.Completed = false;
        }
        else if (!stage.Equals("ADB_CONNECTING", StringComparison.OrdinalIgnoreCase) &&
                 !stage.Equals("BOOTING", StringComparison.OrdinalIgnoreCase))
        {
            state.LastSuccessfulStage = stage;
        }
        await SaveAsync(state, cancellationToken);
    }

    public async Task SetErrorAsync(Exception exception, CancellationToken cancellationToken = default)
    {
        var state = await LoadAsync(cancellationToken) ?? new ProvisioningState();
        state.Completed = false;
        state.LastAttempt = DateTimeOffset.UtcNow;
        state.LastError = exception.Message;
        state.ResumeAllowed = true;
        // Keep a recoverable boot/provisioning stage visible while a transient
        // guest failure is being cleaned up. Error is reserved for timeout,
        // QEMU/WHPX/process failures and structural/runtime validation faults.
        if (IsTerminalFailure(exception)) state.Stage = "Error";
        await SaveAsync(state, cancellationToken);
    }

    public async Task RecordAdbLastOnlineAsync(DateTimeOffset? observedAt, CancellationToken cancellationToken = default)
    {
        if (observedAt is null) return;
        var state = await LoadAsync(cancellationToken) ?? new ProvisioningState();
        state.AdbLastOnline = observedAt.Value;
        await SaveAsync(state, cancellationToken);
    }

    public async Task SetReadinessAsync(bool kioskActive, bool watchdogActive, CancellationToken cancellationToken = default)
    {
        var state = await LoadAsync(cancellationToken) ?? new ProvisioningState();
        state.KioskActive = kioskActive;
        state.WatchdogActive = watchdogActive;
        await SaveAsync(state, cancellationToken);
    }

    public async Task MarkRebootPerformedAsync(CancellationToken cancellationToken = default)
    {
        var state = await LoadAsync(cancellationToken) ?? new ProvisioningState();
        state.RebootPerformed = true;
        await SaveAsync(state, cancellationToken);
    }

    public async Task RecordGuestConfigurationAsync(
        GuestConfigurationResult result,
        CancellationToken cancellationToken = default)
    {
        var state = await LoadAsync(cancellationToken) ?? new ProvisioningState();
        state.GuestConfigurationStatus = result.Ready ? "ready" : "error";
        state.AndroidSetupStatus = result.AndroidSetupComplete ? "complete" : "error";
        state.GuestNetworkStatus = result.NetworkConfigured ? "ready" : "error";
        state.NeoNewsSuperuserStatus = result.SuperuserConfigured ? "allow-forever-notification-off" : result.SuperuserStatus;
        state.GuestInitScriptSha256 = result.InitScriptSha256;
        if (result.RebootPerformed) state.RebootPerformed = true;
        await SaveAsync(state, cancellationToken);
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

    private async Task<ActiveDiskMetadata> ReadActiveDiskMetadataAsync(
        string qemuImgPath,
        string diskPath,
        CancellationToken cancellationToken)
    {
        var info = await _runner.RunAsync(
            qemuImgPath,
            ["info", "--output=json", diskPath],
            _context.RootDirectory,
            "qemu-img",
            TimeSpan.FromSeconds(60),
            cancellationToken,
            logOutput: false,
            isolateEnvironment: _context.Config.HostIsolation.ClearHostToolEnvironment);
        if (!info.Succeeded)
            throw new RuntimeOperationException(
                "Não foi possível ler a geometria do qcow2.",
                $"qemu-img info falhou: exit={info.ExitCode}; timeout={info.TimedOut}; stderr={info.StandardError}; stdout={info.StandardOutput}");

        var check = await _runner.RunAsync(
            qemuImgPath,
            ["check", "--output=json", diskPath],
            _context.RootDirectory,
            "qemu-img",
            TimeSpan.FromSeconds(60),
            cancellationToken,
            logOutput: false,
            isolateEnvironment: _context.Config.HostIsolation.ClearHostToolEnvironment);
        if (!check.Succeeded)
            throw new RuntimeOperationException(
                "O qcow2 não passou no qemu-img check.",
                $"UNEXPECTED_IMAGE_MUTATION; qemu-img check falhou: exit={check.ExitCode}; timeout={check.TimedOut}; stderr={check.StandardError}; stdout={check.StandardOutput}");

        try
        {
            using var infoDocument = JsonDocument.Parse(info.StandardOutput);
            using var checkDocument = JsonDocument.Parse(check.StandardOutput);
            var infoRoot = infoDocument.RootElement;
            var checkRoot = checkDocument.RootElement;
            var formatSpecificData = infoRoot.TryGetProperty("format-specific", out var formatSpecific) &&
                                     formatSpecific.TryGetProperty("data", out var data)
                ? data
                : default;
            var backing = ReadString(infoRoot, "backing-filename");
            if (string.IsNullOrWhiteSpace(backing)) backing = ReadString(infoRoot, "full-backing-filename");
            return new ActiveDiskMetadata
            {
                Format = ReadString(infoRoot, "format"),
                VirtualSizeBytes = ReadInt64(infoRoot, "virtual-size"),
                ActualSizeBytes = ReadInt64(infoRoot, "actual-size"),
                BackingFile = backing,
                Corrupt = ReadBool(formatSpecificData, "corrupt"),
                DirtyFlag = ReadBool(infoRoot, "dirty-flag"),
                CheckErrors = (int)ReadInt64(checkRoot, "check-errors"),
                AllocatedClusters = ReadInt64(checkRoot, "allocated-clusters"),
                FragmentedClusters = ReadInt64(checkRoot, "fragmented-clusters")
            };
        }
        catch (JsonException exception)
        {
            throw new RuntimeOperationException(
                "O qemu-img retornou metadados inválidos para o qcow2.",
                $"UNEXPECTED_IMAGE_MUTATION; falha ao interpretar qemu-img: {exception.Message}",
                exception);
        }
    }

    private static string ReadString(JsonElement element, string property)
    {
        return element.ValueKind == JsonValueKind.Object &&
               element.TryGetProperty(property, out var value) &&
               value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? string.Empty
            : string.Empty;
    }

    private static long ReadInt64(JsonElement element, string property)
    {
        return element.ValueKind == JsonValueKind.Object &&
               element.TryGetProperty(property, out var value) &&
               value.ValueKind == JsonValueKind.Number &&
               value.TryGetInt64(out var result)
            ? result
            : 0;
    }

    private static bool ReadBool(JsonElement element, string property)
    {
        return element.ValueKind == JsonValueKind.Object &&
               element.TryGetProperty(property, out var value) &&
               (value.ValueKind is JsonValueKind.True or JsonValueKind.False) &&
               value.GetBoolean();
    }

    private static bool IsTerminalFailure(Exception exception)
    {
        if (exception is OperationCanceledException) return false;
        var detail = exception is RuntimeOperationException runtime
            ? $"{runtime.Message} {runtime.TechnicalDetails}"
            : exception.ToString();
        return detail.Contains("timeout", StringComparison.OrdinalIgnoreCase) ||
               detail.Contains("tempo", StringComparison.OrdinalIgnoreCase) ||
               detail.Contains("qemu", StringComparison.OrdinalIgnoreCase) ||
               detail.Contains("whpx", StringComparison.OrdinalIgnoreCase) ||
               detail.Contains("qcow2", StringComparison.OrdinalIgnoreCase) ||
               detail.Contains("UNEXPECTED_IMAGE_MUTATION", StringComparison.OrdinalIgnoreCase) ||
               detail.Contains("não foi possível conectar", StringComparison.OrdinalIgnoreCase) ||
               detail.Contains("não foi possível iniciar", StringComparison.OrdinalIgnoreCase);
    }
}
