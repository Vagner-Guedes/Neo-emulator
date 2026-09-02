using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed record WhpxStatus(bool Available, string Details);

public sealed class QemuAndroidRuntimeBackend : IAndroidRuntimeBackend
{
    private readonly RuntimeContext _context;
    private readonly ProcessRunnerService _runner;
    private readonly LogService _logs;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private ManagedProcess? _process;

    public QemuAndroidRuntimeBackend(RuntimeContext context, ProcessRunnerService runner, LogService logs)
    {
        _context = context;
        _runner = runner;
        _logs = logs;
    }

    public string Name => "QEMU Android-x86";

    public int? ProcessId => _process is { HasExited: false } process ? process.ProcessId : null;

    public IntPtr WindowHandle
    {
        get
        {
            if (ProcessId is not int processId) return IntPtr.Zero;
            try
            {
                var process = System.Diagnostics.Process.GetProcessById(processId);
                if (process.MainWindowHandle != IntPtr.Zero) return process.MainWindowHandle;
                return RuntimeWindowService.FindForProcess(processId, _context.Config.Android.Qemu.WindowTitle);
            }
            catch (ArgumentException) { return IntPtr.Zero; }
            catch (InvalidOperationException) { return IntPtr.Zero; }
        }
    }

    public Task<bool> IsRunningAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(_process is { HasExited: false });

    public async Task StartAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (_process is { HasExited: false })
            {
                progress?.Report(new RuntimeProgress("Android já iniciado", "QEMU detectado; reutilizando processo.", 25));
                return;
            }

            if (_process is not null)
            {
                await _process.DisposeAsync();
                _process = null;
            }

            var whpx = CheckWhpx();
            var qemu = _context.Config.Android.Qemu;
            var acceleration = string.IsNullOrWhiteSpace(qemu.Acceleration) ? "whpx" : qemu.Acceleration.Trim();
            if (acceleration.Equals("whpx", StringComparison.OrdinalIgnoreCase) && !whpx.Available)
            {
                throw new RuntimeOperationException(
                    "A aceleração de virtualização não está disponível.",
                    $"WHPX indisponível: {whpx.Details} Verifique se a virtualização está habilitada no firmware e se o recurso Windows Hypervisor Platform está instalado.");
            }
            if (!acceleration.Equals("whpx", StringComparison.OrdinalIgnoreCase) && !qemu.AllowTcgForDiagnostics)
            {
                throw new RuntimeOperationException(
                    "O runtime exige aceleração WHPX.",
                    $"A configuração selecionou '{acceleration}'. TCG só pode ser usado em modo de diagnóstico explícito.");
            }

            var executable = _context.ResolveQemuPath();
            var disk = _context.ResolveAndroidDiskPath();
            if (!File.Exists(executable))
                throw new RuntimeOperationException("QEMU não foi encontrado.", $"Caminho configurado: {executable}");
            if (!File.Exists(disk))
                throw new RuntimeOperationException("O disco persistente do Android não foi encontrado.", $"Caminho configurado: {disk}");

            var host = _context.Config.Android.Adb.Host;
            var hostPort = _context.Config.Android.Adb.HostPort;
            var guestPort = _context.Config.Android.Adb.GuestPort;
            var qmpPort = qemu.QmpPort;
            var arguments = new List<string>
            {
                "-name", qemu.WindowTitle,
                "-machine", string.IsNullOrWhiteSpace(qemu.Machine) ? "q35" : qemu.Machine,
                "-accel", acceleration,
                "-m", Math.Max(512, qemu.MemoryMb).ToString(),
                "-smp", Math.Max(1, Math.Min(qemu.CpuCores, Environment.ProcessorCount)).ToString(),
                "-drive", $"file={disk},if=virtio,format=qcow2",
                "-boot", "order=c",
                "-netdev", $"user,id=neonewsnet,hostfwd=tcp:{host}:{hostPort}-:{guestPort}",
                "-device", "virtio-net-pci,netdev=neonewsnet",
                "-qmp", $"tcp:127.0.0.1:{qmpPort},server=on,wait=off",
                "-no-reboot",
                "-vga", string.IsNullOrWhiteSpace(qemu.Gpu) ? "std" : qemu.Gpu,
                "-display", qemu.ShowWindow ? $"gtk,window-title={qemu.WindowTitle}" : "none"
            };

            if (_context.Config.Android.Optimization.AudioOutput)
            {
                arguments.Add("-audiodev");
                arguments.Add("driver=dsound,id=neonewsaudio");
                arguments.Add("-device");
                arguments.Add("AC97,audiodev=neonewsaudio");
            }

            var image = _context.ResolveAndroidImagePath();
            if (File.Exists(image))
            {
                arguments.Insert(10, image);
                arguments.Insert(10, "-cdrom");
            }
            else
            {
                _logs.Warning("qemu", $"Imagem de instalação opcional não encontrada; usando somente o disco persistente: {image}");
            }

            progress?.Report(new RuntimeProgress("Iniciando Android", $"QEMU x86_64 com WHPX; ADB {host}:{hostPort} → guest:{guestPort}", 20));
            _process = _runner.StartLongRunning(executable, arguments, _context.RootDirectory, "qemu");
            await Task.Delay(300, cancellationToken);
            if (_process.HasExited)
                throw new RuntimeOperationException("QEMU encerrou durante a inicialização.", $"O processo QEMU terminou antes do ADB ficar disponível. Executável: {executable}");
        }
        catch
        {
            if (_process is not null)
            {
                try { await _process.DisposeAsync(); } catch { }
                _process = null;
            }
            throw;
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
            if (_process is null) return;
            await RequestQmpShutdownAsync(cancellationToken);
            await _process.StopAsync(TimeSpan.FromSeconds(Math.Max(5, _context.Config.Timeouts.QemuShutdownSeconds)), cancellationToken);
            await _process.DisposeAsync();
            _process = null;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task RestartAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        progress?.Report(new RuntimeProgress("Reiniciando Android", "Encerrando o QEMU atual...", 15));
        await StopAsync(cancellationToken);
        await StartAsync(progress, cancellationToken);
    }

    public async ValueTask DisposeAsync()
    {
        try { await StopAsync(CancellationToken.None); }
        catch (Exception exception) { _logs.Warning("qemu", $"Falha ao encerrar QEMU: {exception.Message}"); }
        _gate.Dispose();
    }

    public static WhpxStatus CheckWhpx()
    {
        if (!OperatingSystem.IsWindows()) return new WhpxStatus(false, "O WHPX só está disponível no Windows.");
        if (!Environment.Is64BitOperatingSystem) return new WhpxStatus(false, "O sistema operacional não é x64.");
        if (!NativeLibrary.TryLoad("WinHvPlatform.dll", out var handle))
            return new WhpxStatus(false, "WinHvPlatform.dll não pôde ser carregada; o recurso Windows Hypervisor Platform pode estar ausente.");
        NativeLibrary.Free(handle);
        return new WhpxStatus(true, "WinHvPlatform.dll carregada; o QEMU será iniciado com -accel whpx.");
    }

    private async Task RequestQmpShutdownAsync(CancellationToken cancellationToken)
    {
        var port = _context.Config.Android.Qemu.QmpPort;
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(2));
            using var client = new TcpClient();
            await client.ConnectAsync("127.0.0.1", port, timeout.Token);
            await using var stream = client.GetStream();
            var greeting = new byte[4096];
            _ = await stream.ReadAsync(greeting.AsMemory(), timeout.Token);
            await SendQmpCommandAsync(stream, "qmp_capabilities", timeout.Token);
            await SendQmpCommandAsync(stream, "quit", timeout.Token);
            _logs.Info("qemu", "Desligamento solicitado via QMP.");
        }
        catch (Exception exception) when (exception is IOException or SocketException or OperationCanceledException)
        {
            _logs.Warning("qemu", $"QMP indisponível; usando encerramento controlado do processo: {exception.Message}");
        }
    }

    private static async Task SendQmpCommandAsync(NetworkStream stream, string command, CancellationToken cancellationToken)
    {
        var payload = Encoding.UTF8.GetBytes($"{{\"execute\":\"{command}\"}}\r\n");
        await stream.WriteAsync(payload.AsMemory(), cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }
}
