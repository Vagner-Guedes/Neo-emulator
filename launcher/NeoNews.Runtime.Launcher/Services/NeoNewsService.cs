using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed record NeoNewsStatus(bool Installed, bool Running, string? Version, string Detail);

public sealed class NeoNewsService
{
    private readonly RuntimeContext _context;
    private readonly AdbService _adb;

    public NeoNewsService(RuntimeContext context, AdbService adb)
    {
        _context = context;
        _adb = adb;
    }

    public string PackageName => _context.Config.NeoNews.PackageName;
    public string ActivityName => NormalizeActivity(_context.Config.NeoNews.LaunchActivity);

    public Task<bool> IsInstalledAsync(CancellationToken cancellationToken = default) =>
        _adb.IsPackageInstalledAsync(PackageName, cancellationToken);

    public async Task<bool> IsRunningAsync(CancellationToken cancellationToken = default) =>
        (await GetStatusAsync(cancellationToken)).Running;

    public Task<string?> GetVersionAsync(CancellationToken cancellationToken = default) =>
        _adb.GetPackageVersionAsync(PackageName, cancellationToken);

    public Task ForceStopAsync(CancellationToken cancellationToken = default) => StopAsync(cancellationToken);

    public Task InstallAuthorizedApkAsync(CancellationToken cancellationToken = default) => InstallAsync(cancellationToken);

    public async Task<NeoNewsStatus> GetStatusAsync(CancellationToken cancellationToken = default)
    {
        var installed = await IsInstalledAsync(cancellationToken);
        if (!installed) return new NeoNewsStatus(false, false, null, "APK não instalado");
        var version = await _adb.GetPackageVersionAsync(PackageName, cancellationToken);
        var running = await _adb.IsActivityRunningAsync(PackageName, ActivityName, cancellationToken);
        return new NeoNewsStatus(true, running, version, running ? "Em execução" : "Instalado");
    }

    public async Task StartAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        var status = await GetStatusAsync(cancellationToken);
        var versionMismatch = status.Installed &&
                              !string.IsNullOrWhiteSpace(_context.Config.NeoNews.VersionName) &&
                              !string.Equals(status.Version, _context.Config.NeoNews.VersionName, StringComparison.OrdinalIgnoreCase);
        if (!status.Installed || versionMismatch)
        {
            var apkPath = _context.ResolveApkPath();
            if (!File.Exists(apkPath))
            {
                throw new RuntimeOperationException(
                    "NeoNews.apk não está instalado.",
                    $"Pacote esperado: {PackageName}. APK local não encontrado em: {apkPath}. ABI declarada: {string.Join(", ", _context.Config.NeoNews.SupportedApkAbis)}.");
            }

            progress?.Report(new RuntimeProgress("Instalando NeoNews", "APK local autorizado encontrado; instalando no Android...", 78));
            await _adb.InstallApkAsync(apkPath, cancellationToken);
            status = await GetStatusAsync(cancellationToken);
            if (!status.Installed)
            {
                throw new RuntimeOperationException(
                    "NeoNews.apk foi processado, mas o pacote não apareceu no Android.",
                    $"Pacote esperado: {PackageName}. APK: {apkPath}");
            }
        }
        await ValidateInstalledVersionAsync(cancellationToken);
        progress?.Report(new RuntimeProgress("Abrindo NeoNews", $"{PackageName}/{ActivityName}", 82));
        await _adb.StartActivityAsync(PackageName, ActivityName, cancellationToken);
    }

    public Task StopAsync(CancellationToken cancellationToken = default) => _adb.StopPackageAsync(PackageName, cancellationToken);

    public async Task RestartAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        await StopAsync(cancellationToken);
        await StartAsync(progress, cancellationToken);
    }

    public async Task InstallAsync(CancellationToken cancellationToken = default)
    {
        await _adb.InstallApkAsync(_context.ResolveApkPath(), cancellationToken);
        await ValidateInstalledVersionAsync(cancellationToken);
    }

    private async Task ValidateInstalledVersionAsync(CancellationToken cancellationToken)
    {
        var version = await _adb.GetPackageVersionAsync(PackageName, cancellationToken);
        var versionCode = await _adb.GetPackageVersionCodeAsync(PackageName, cancellationToken);
        if (!string.IsNullOrWhiteSpace(_context.Config.NeoNews.VersionName) && !string.Equals(version, _context.Config.NeoNews.VersionName, StringComparison.OrdinalIgnoreCase))
            throw new RuntimeOperationException("A versão do NeoNews não corresponde à versão esperada.", $"Pacote={PackageName}; versão encontrada={version}; esperada={_context.Config.NeoNews.VersionName}; versionCode={versionCode}; esperado={_context.Config.NeoNews.VersionCode}.");
        if (_context.Config.NeoNews.VersionCode > 0 && versionCode is not null && versionCode != _context.Config.NeoNews.VersionCode)
            throw new RuntimeOperationException("O versionCode do NeoNews não corresponde ao esperado.", $"Pacote={PackageName}; versionCode encontrado={versionCode}; esperado={_context.Config.NeoNews.VersionCode}.");
    }

    private string NormalizeActivity(string activity)
    {
        if (activity.Contains('/')) activity = activity.Split('/').Last();
        if (activity.StartsWith('.')) return activity[1..];
        if (activity.StartsWith(PackageName + ".", StringComparison.Ordinal)) return activity[(PackageName.Length + 1)..];
        return activity;
    }
}
