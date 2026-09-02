using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

/// <summary>
/// Lifecycle contract for an Android guest. The controller deliberately knows
/// nothing about whether the guest is provided by QEMU or the legacy SDK tool.
/// </summary>
public interface IAndroidRuntimeBackend : IAsyncDisposable
{
    string Name { get; }
    int? ProcessId { get; }
    IntPtr WindowHandle { get; }

    Task<bool> IsRunningAsync(CancellationToken cancellationToken = default);
    Task StartAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken);
    Task StopAsync(CancellationToken cancellationToken);
    Task RestartAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken);
}
