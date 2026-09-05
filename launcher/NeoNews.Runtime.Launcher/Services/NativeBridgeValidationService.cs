using System.Text.RegularExpressions;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed record NativeBridgeValidationResult(
    string Property,
    string GuestAbi,
    string GuestAbiList,
    string Abi2,
    bool Ready,
    string Detail,
    string PersistNativeBridge,
    IReadOnlyList<NativeBridgeFileEvidence> Files,
    NativeBridgeState State,
    bool TransportStable,
    int Attempts);

public sealed record NativeBridgeFileEvidence(
    string Path,
    bool Exists,
    long Length,
    string Detail)
{
    public bool HasContent => Exists && Length > 0;
}

public sealed record AbiCompatibilityResult(
    string GuestAbi,
    string GuestAbiList,
    string NativeBridgeProperty,
    bool NativeBridgeReady,
    IReadOnlyList<string> ApkAbis,
    string? SelectedApkAbi,
    bool InstallSucceeded,
    string? PrimaryCpuAbi,
    bool LaunchSucceeded,
    bool RuntimeStable,
    NativeBridgeState NativeBridgeState);

public sealed class NativeBridgeValidationService
{
    private readonly RuntimeContext _context;
    private readonly AdbService _adb;

    public NativeBridgeValidationService(RuntimeContext context, AdbService adb)
    {
        _context = context;
        _adb = adb;
    }

    public async Task<NativeBridgeValidationResult> ValidateGuestAsync(CancellationToken cancellationToken = default)
    {
        // Android-x86 can report boot completed just before its TCP ADB
        // transport settles. A partial probe is not evidence that Houdini is
        // absent from the baked-in image, so retry only transport failures.
        const int maximumAttempts = 4;
        NativeBridgeValidationResult? last = null;
        for (var attempt = 1; attempt <= maximumAttempts; attempt++)
        {
            last = await ValidateGuestOnceAsync(attempt, cancellationToken);
            if (last.TransportStable || attempt == maximumAttempts) return last;
            await _adb.RecoverTransportAsync(cancellationToken);
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds)), cancellationToken);
        }
        return last!;
    }

    private async Task<NativeBridgeValidationResult> ValidateGuestOnceAsync(int attempt, CancellationToken cancellationToken)
    {
        var property = await _adb.GetPropertyAsync(_context.Config.Android.NativeBridge.Property, cancellationToken);
        var persistNativeBridge = await _adb.GetPropertyAsync("persist.sys.nativebridge", cancellationToken);
        var abi = await _adb.GetPropertyAsync("ro.product.cpu.abi", cancellationToken);
        var abiList = await _adb.GetPropertyAsync("ro.product.cpu.abilist", cancellationToken);
        var abi2 = await _adb.GetPropertyAsync("ro.product.cpu.abi2", cancellationToken);
        var files = new[]
        {
            await ReadGuestFileAsync("/system/lib/libnb.so", cancellationToken),
            await ReadGuestFileAsync("/system/lib64/libnb.so", cancellationToken),
            await ReadGuestFileAsync("/system/lib/libhoudini.so", cancellationToken),
            await ReadGuestFileAsync("/system/lib64/libhoudini.so", cancellationToken)
        };
        var x86Guest = abi.Equals("x86", StringComparison.OrdinalIgnoreCase) || abi.Equals("x86_64", StringComparison.OrdinalIgnoreCase);
        var abiListHasX86 = abiList.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Any(item => item.Equals("x86", StringComparison.OrdinalIgnoreCase) || item.Equals("x86_64", StringComparison.OrdinalIgnoreCase));
        var nativeBridgeEnabled = IsTrue(persistNativeBridge);
        var libNbReady = files[0].HasContent && files[1].HasContent;
        var translatorReady = files[2].HasContent && files[3].HasContent;
        var ready = !string.IsNullOrWhiteSpace(property) &&
                    !property.Equals("0", StringComparison.OrdinalIgnoreCase) &&
                    nativeBridgeEnabled && x86Guest && abiListHasX86 && libNbReady && translatorReady;
        var transportStable = files.All(file => !IsTransportFailure(file.Detail));
        var state = ready ? NativeBridgeState.Configured : transportStable ? NativeBridgeState.Missing : NativeBridgeState.Error;
        var detail = ready
            ? $"Native Bridge declarado como '{property}' para guest {abi}. A execução do APK ainda precisa ser comprovada."
            : $"Native Bridge não operacional: property='{property}', abi='{abi}', abilist='{abiList}', abi2='{abi2}'.";
        return new NativeBridgeValidationResult(property, abi, abiList, abi2, ready, detail, persistNativeBridge, files, state, transportStable, attempt);
    }

    public async Task<AbiCompatibilityResult> ValidateInstalledPackageAsync(
        string packageName,
        string activityName,
        IReadOnlyList<string> apkAbis,
        bool installSucceeded,
        CancellationToken cancellationToken = default)
    {
        var guest = await ValidateGuestAsync(cancellationToken);
        var primary = await _adb.GetPrimaryCpuAbiAsync(packageName, cancellationToken);
        var preferredAbi = string.IsNullOrWhiteSpace(_context.Config.Android.NativeBridge.PreferredAbi)
            ? _context.Config.Android.PreferredApkAbi
            : _context.Config.Android.NativeBridge.PreferredAbi;
        var selected = primary is not null && apkAbis.Contains(primary, StringComparer.OrdinalIgnoreCase)
                       && (string.IsNullOrWhiteSpace(preferredAbi) || primary.Equals(preferredAbi, StringComparison.OrdinalIgnoreCase))
            ? primary
            : null;
        if (selected is null && !installSucceeded && apkAbis.Count == 0 && primary is not null &&
            (string.IsNullOrWhiteSpace(preferredAbi) || primary.Equals(preferredAbi, StringComparison.OrdinalIgnoreCase)))
        {
            // A provisioned guest may retain the authorized APK while the
            // host-side package is intentionally absent from the portable
            // distribution. In that case package-manager evidence is enough
            // to select the ABI for a normal offline boot; installSucceeded
            // remains false until this run observes adb install -r Success.
            selected = primary;
        }
        var launched = await _adb.IsActivityRunningAsync(packageName, activityName, cancellationToken);
        var stable = false;
        // Installation evidence and runtime evidence are independent. An
        // already-installed matching APK must still be launchable; the
        // install gate remains false until this run actually observed
        // adb install -r returning Success.
        if (guest.Ready && selected is not null && launched)
        {
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.NativeBridgeStabilitySeconds)), cancellationToken);
            stable = await _adb.IsActivityRunningAsync(packageName, activityName, cancellationToken);
        }
        var state = stable ? NativeBridgeState.Ready : guest.State;
        return new AbiCompatibilityResult(guest.GuestAbi, guest.GuestAbiList, guest.Property, guest.Ready, apkAbis, selected, installSucceeded, primary, launched, stable, state);
    }

    private async Task<NativeBridgeFileEvidence> ReadGuestFileAsync(string path, CancellationToken cancellationToken)
    {
        var result = await _adb.ShellResultAsync(["ls", "-l", path], TimeSpan.FromSeconds(10), cancellationToken);
        var output = string.Join(" | ", new[] { result.StandardOutput.Trim(), result.StandardError.Trim() }
            .Where(value => !string.IsNullOrWhiteSpace(value)));
        if (!result.Succeeded) return new NativeBridgeFileEvidence(path, false, 0, output);

        var match = Regex.Match(result.StandardOutput, @"(?m)^\S+\s+\S+\s+\S+\s+\S+\s+(?<length>\d+)\s+");
        var length = match.Success && long.TryParse(match.Groups["length"].Value, out var parsed) ? parsed : 0;
        return new NativeBridgeFileEvidence(path, true, length, output);
    }

    private static bool IsTransportFailure(string detail) =>
        detail.Contains("device offline", StringComparison.OrdinalIgnoreCase) ||
        detail.Contains("device not found", StringComparison.OrdinalIgnoreCase) ||
        detail.Contains("no devices", StringComparison.OrdinalIgnoreCase) ||
        detail.Contains("closed", StringComparison.OrdinalIgnoreCase);

    private static bool IsTrue(string value) => value.Equals("1", StringComparison.OrdinalIgnoreCase) ||
                                                value.Equals("true", StringComparison.OrdinalIgnoreCase) ||
                                                value.Equals("yes", StringComparison.OrdinalIgnoreCase) ||
                                                value.Equals("on", StringComparison.OrdinalIgnoreCase);

    public static IReadOnlyList<string> ReadApkAbis(string apkPath)
    {
        using var archive = System.IO.Compression.ZipFile.OpenRead(apkPath);
        return archive.Entries
            .Select(entry => Regex.Match(entry.FullName, @"^lib/([^/]+)/"))
            .Where(match => match.Success)
            .Select(match => match.Groups[1].Value)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }
}
