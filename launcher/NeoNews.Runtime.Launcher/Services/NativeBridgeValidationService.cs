using System.Text.RegularExpressions;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed record NativeBridgeValidationResult(
    string Property,
    string GuestAbi,
    string GuestAbiList,
    string Abi2,
    bool Ready,
    string Detail);

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
    bool RuntimeStable);

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
        var property = await _adb.GetPropertyAsync(_context.Config.Android.NativeBridge.Property, cancellationToken);
        var abi = await _adb.GetPropertyAsync("ro.product.cpu.abi", cancellationToken);
        var abiList = await _adb.GetPropertyAsync("ro.product.cpu.abilist", cancellationToken);
        var abi2 = await _adb.GetPropertyAsync("ro.product.cpu.abi2", cancellationToken);
        var ready = !string.IsNullOrWhiteSpace(property) &&
                    !property.Equals("0", StringComparison.OrdinalIgnoreCase) &&
                    (abi.Equals("x86", StringComparison.OrdinalIgnoreCase) || abi.Equals("x86_64", StringComparison.OrdinalIgnoreCase)) &&
                    abiList.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                        .Any(item => item.Equals("x86", StringComparison.OrdinalIgnoreCase) || item.Equals("x86_64", StringComparison.OrdinalIgnoreCase));
        var detail = ready
            ? $"Native Bridge declarado como '{property}' para guest {abi}. A execução do APK ainda precisa ser comprovada."
            : $"Native Bridge não operacional: property='{property}', abi='{abi}', abilist='{abiList}', abi2='{abi2}'.";
        return new NativeBridgeValidationResult(property, abi, abiList, abi2, ready, detail);
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
        var selected = primary is not null && apkAbis.Contains(primary, StringComparer.OrdinalIgnoreCase)
            ? primary
            : null;
        var launched = await _adb.IsActivityRunningAsync(packageName, activityName, cancellationToken);
        var stable = false;
        if (guest.Ready && installSucceeded && selected is not null && launched)
        {
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.NativeBridgeStabilitySeconds)), cancellationToken);
            stable = await _adb.IsActivityRunningAsync(packageName, activityName, cancellationToken);
        }
        return new AbiCompatibilityResult(guest.GuestAbi, guest.GuestAbiList, guest.Property, guest.Ready, apkAbis, selected, installSucceeded, primary, launched, stable);
    }

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
