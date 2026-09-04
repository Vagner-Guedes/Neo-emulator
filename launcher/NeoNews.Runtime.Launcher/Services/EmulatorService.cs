using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class EmulatorService : IAndroidRuntimeBackend
{
    private readonly RuntimeContext _context;
    private readonly ProcessRunnerService _runner;
    private readonly LogService _logs;
    private readonly AdbService _adb;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private ManagedProcess? _process;

    public EmulatorService(RuntimeContext context, ProcessRunnerService runner, LogService logs, AdbService adb)
    {
        _context = context;
        _runner = runner;
        _logs = logs;
        _adb = adb;
    }

    public int? ProcessId
    {
        get
        {
            return _process is { HasExited: false } process ? process.ProcessId : null;
        }
    }

    public string Name => "Android SDK Emulator";

    public IntPtr WindowHandle
    {
        get
        {
            if (ProcessId is not int processId) return IntPtr.Zero;
            try { return System.Diagnostics.Process.GetProcessById(processId).MainWindowHandle; }
            catch (ArgumentException) { return IntPtr.Zero; }
        }
    }

    public Task<bool> WaitForAdbAsync(TimeSpan timeout, CancellationToken cancellationToken = default) =>
        _adb.WaitForDeviceAsync(timeout, cancellationToken);

    public Task<bool> IsRunningAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(_process is { HasExited: false });

    public async Task StartAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (_process is { HasExited: true } staleProcess)
            {
                await staleProcess.DisposeAsync();
                _process = null;
            }
            if (await IsRunningAsync(cancellationToken))
            {
                progress?.Report(new RuntimeProgress("Android já iniciado", "Emulator detectado; reutilizando processo.", 25));
                return;
            }

            var emulatorPath = _context.ResolveEmulatorPath();
            var emulator = _context.Config.Android.Emulator;
            var arguments = new List<string>
            {
                "-avd", _context.Config.Android.PreferredAvd,
                "-gpu", string.IsNullOrWhiteSpace(emulator.Gpu) ? "auto" : emulator.Gpu,
                "-accel", string.IsNullOrWhiteSpace(emulator.Acceleration) ? "auto" : emulator.Acceleration,
                "-timezone", _context.Config.Runtime.Timezone,
                "-port", ResolveEmulatorPort()
            };
            if (emulator.NoBootAnimation) arguments.Add("-no-boot-anim");
            if (emulator.SnapshotPolicy.Contains("cold", StringComparison.OrdinalIgnoreCase)) arguments.Add("-no-snapshot");
            if (!emulator.ShowWindow) arguments.Add("-no-window");

            progress?.Report(new RuntimeProgress("Iniciando Android", $"AVD {_context.Config.Android.PreferredAvd}", 20));
            _process = _runner.StartLongRunning(emulatorPath, arguments, _context.RootDirectory, "emulator", showWindow: emulator.ShowWindow);
            await Task.Delay(500, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (_process is not null)
            {
                await _process.StopAsync(TimeSpan.FromSeconds(Math.Max(5, _context.Config.Timeouts.EmulatorStopSeconds)), cancellationToken);
                await _process.DisposeAsync();
                _process = null;
                return;
            }

            // The legacy backend can only stop processes it owns. The QEMU
            // backend has its own QMP/process shutdown and never uses the
            // Android Emulator console protocol.
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task RestartAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        progress?.Report(new RuntimeProgress("Reiniciando Android", "Encerrando o Emulator atual...", 15));
        await StopAsync(cancellationToken);
        await StartAsync(progress, cancellationToken);
    }

    public async ValueTask DisposeAsync()
    {
        try { await StopAsync(CancellationToken.None); } catch (Exception exception) { _logs.Warning("launcher", $"Falha ao encerrar Emulator: {exception.Message}"); }
        _gate.Dispose();
    }

    private string ResolveEmulatorPort()
    {
        var serial = _adb.Serial;
        return serial.StartsWith("emulator-", StringComparison.OrdinalIgnoreCase)
            ? serial["emulator-".Length..]
            : _context.Config.Android.Emulator.ValidationPort.ToString();
    }
}
