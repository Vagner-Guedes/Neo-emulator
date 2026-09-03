using System.Net.Sockets;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed record WhpxStatus(bool Available, string Details);

public sealed class QemuAndroidRuntimeBackend : IAndroidRuntimeBackend
{
    private const int WhvCapabilityCodeHypervisorPresent = 0;
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
            var androidImage = _context.ResolveAndroidImagePath();
            var qemuShareDirectory = Path.Combine(Path.GetDirectoryName(executable) ?? _context.RootDirectory, "share");
            if (!HasContent(executable))
                throw new RuntimeOperationException("QEMU não foi encontrado.", $"Caminho configurado: {executable}");
            if (!HasContent(Path.Combine(qemuShareDirectory, "bios-256k.bin")))
                throw new RuntimeOperationException("O firmware portátil do QEMU não foi encontrado.", $"Diretório esperado: {qemuShareDirectory}. A distribuição precisa preservar o diretório share ao lado do executável.");
            if (!HasContent(disk))
                throw new RuntimeOperationException("O disco persistente do Android não foi encontrado.", $"Caminho configurado: {disk}");
            if (!HasContent(androidImage))
                throw new RuntimeOperationException("A imagem Android-x86 não foi encontrada.", $"Caminho configurado: {androidImage}; o disco persistente deve ter sido provisionado a partir da imagem aprovada.");

            var host = _context.Config.Android.Adb.Host;
            var hostPort = _context.Config.Android.Adb.HostPort;
            var guestPort = _context.Config.Android.Adb.GuestPort;
            var networkId = RequireQemuToken(qemu.NetworkId, "NetworkId");
            var networkCidr = RequireIpv4Cidr(qemu.NetworkCidr, "NetworkCidr");
            var guestAddress = RequireIpv4Address(qemu.GuestAddress, "GuestAddress");
            var nicModel = RequireQemuToken(qemu.NicModel, "NicModel");
            var qmpPort = qemu.QmpPort;
            HostPortGuard.EnsureDistinct(
                ("ADB transport", hostPort),
                ("QMP", qmpPort),
                ("ADB server", _context.Config.Android.Adb.ServerPort));
            if (_context.Config.HostIsolation.RefusePortConflicts)
            {
                HostPortGuard.EnsureAvailable(host, hostPort, "ADB transport do NeoNews Runtime");
                HostPortGuard.EnsureAvailable("127.0.0.1", qmpPort, "QMP do NeoNews Runtime");
            }
            var requestedMemoryMb = Math.Max(512, qemu.MemoryMb);
            var availableMemoryMb = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / (1024L * 1024L);
            var memoryLimitMb = availableMemoryMb > 0
                ? Math.Max(512L, availableMemoryMb * 3 / 4)
                : requestedMemoryMb;
            var effectiveMemoryMb = Math.Min((long)requestedMemoryMb, memoryLimitMb);
            var arguments = new List<string>
            {
                "-name", qemu.WindowTitle,
                "-machine", string.IsNullOrWhiteSpace(qemu.Machine) ? "pc" : qemu.Machine,
                "-accel", acceleration,
                // Android-x86/Linux interprets the virtual RTC as UTC. Using
                // localtime here makes the guest fall back by the configured
                // UTC offset after the time service refreshes the clock.
                "-rtc", "base=utc",
                "-L", qemuShareDirectory,
                "-m", effectiveMemoryMb.ToString(),
                "-smp", Math.Max(1, Math.Min(qemu.CpuCores, Environment.ProcessorCount)).ToString(),
                "-drive", $"file={disk},if=ide,format=qcow2",
                "-boot", "order=c",
                "-netdev", $"user,id={networkId},net={networkCidr},dhcpstart={guestAddress},hostfwd=tcp:{host}:{hostPort}-{guestAddress}:{guestPort}",
                "-device", $"{nicModel},netdev={networkId},id=neonewsnic",
                "-qmp", $"tcp:127.0.0.1:{qmpPort},server=on,wait=off",
                "-monitor", "none",
                "-serial", "none",
                "-no-reboot",
                "-vga", string.IsNullOrWhiteSpace(qemu.Gpu) ? "std" : qemu.Gpu,
                "-display", qemu.ShowWindow ? "default" : "none"
            };

            if (_context.Config.Android.Optimization.AudioOutput)
            {
                arguments.Add("-audiodev");
                arguments.Add("driver=dsound,id=neonewsaudio");
                arguments.Add("-device");
                arguments.Add("AC97,audiodev=neonewsaudio");
            }

            progress?.Report(new RuntimeProgress("Iniciando Android", $"QEMU x86_64 com WHPX; ADB {host}:{hostPort} → guest:{guestPort}", 20));
            _process = _runner.StartLongRunning(
                executable,
                arguments,
                _context.RootDirectory,
                "qemu",
                isolateEnvironment: _context.Config.HostIsolation.ClearHostToolEnvironment);
            await HostProcessOwnership.WriteAsync(
                _context.HostProcessStatePath,
                new HostProcessRecord(
                    _process.ProcessId,
                    executable,
                    _context.RootDirectory,
                    DateTimeOffset.UtcNow,
                    Name,
                    $"{host}:{hostPort}",
                    qmpPort,
                    hostPort),
                cancellationToken);
            await Task.Delay(300, cancellationToken);
            if (_process.HasExited)
                throw new RuntimeOperationException("QEMU encerrou durante a inicialização.", $"O processo QEMU terminou antes do ADB ficar disponível. Executável: {executable}");
        }
        catch
        {
            if (_process is not null)
            {
                var processId = _process.ProcessId;
                try { await _process.DisposeAsync(); } catch { }
                try { await HostProcessOwnership.ClearAsync(_context.HostProcessStatePath, processId); } catch { }
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
            var processId = _process.ProcessId;
            await RequestQmpShutdownAsync(cancellationToken);
            await _process.StopAsync(TimeSpan.FromSeconds(Math.Max(5, _context.Config.Timeouts.QemuShutdownSeconds)), cancellationToken);
            await _process.DisposeAsync();
            await HostProcessOwnership.ClearAsync(_context.HostProcessStatePath, processId, cancellationToken);
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
        try
        {
            var hresult = WHvGetCapability(
                WhvCapabilityCodeHypervisorPresent,
                out var hypervisorPresent,
                sizeof(uint),
                out var writtenSize);
            if (hresult != 0 || writtenSize < sizeof(uint) || hypervisorPresent == 0)
            {
                return new WhpxStatus(
                    false,
                    $"WHvGetCapability(HypervisorPresent) falhou ou retornou ausente; HRESULT=0x{hresult:X8}; escrito={writtenSize}; hypervisorPresent={hypervisorPresent}. Virtualização pode estar desabilitada no firmware ou o recurso Windows Hypervisor Platform pode estar ausente.");
            }

            return new WhpxStatus(true, "WHvGetCapability confirmou HypervisorPresent; o QEMU será iniciado com -accel whpx.");
        }
        catch (DllNotFoundException exception)
        {
            return new WhpxStatus(false, $"A API WHPX não pôde ser carregada: {exception.Message}");
        }
        catch (EntryPointNotFoundException exception)
        {
            return new WhpxStatus(false, $"A API WHvGetCapability não está disponível: {exception.Message}");
        }
        finally
        {
            NativeLibrary.Free(handle);
        }
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
            using var reader = new StreamReader(stream, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: false, bufferSize: 4096, leaveOpen: true);
            var greeting = await ReadQmpMessageAsync(reader, timeout.Token);
            if (!IsQmpGreeting(greeting)) throw new InvalidDataException("O servidor QMP não retornou um greeting válido.");
            await SendQmpCommandAsync(stream, "qmp_capabilities", timeout.Token);
            var capabilitiesResponse = await ReadQmpResponseAsync(reader, timeout.Token);
            if (!IsQmpSuccess(capabilitiesResponse)) throw new InvalidDataException("QMP rejeitou qmp_capabilities.");
            await SendQmpCommandAsync(stream, "quit", timeout.Token);
            var quitResponse = await ReadQmpResponseAsync(reader, timeout.Token);
            if (!IsQmpSuccess(quitResponse)) throw new InvalidDataException("QMP rejeitou quit.");
            _logs.Info("qemu", "Desligamento solicitado via QMP.");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            _logs.Warning("qemu", "QMP não confirmou o desligamento dentro do timeout; usando encerramento controlado do processo.");
        }
        catch (Exception exception) when (exception is IOException or SocketException or JsonException or InvalidDataException)
        {
            _logs.Warning("qemu", $"QMP indisponível; usando encerramento controlado do processo: {exception.Message}");
        }
    }

    private static async Task<string> ReadQmpMessageAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        while (true)
        {
            var line = await reader.ReadLineAsync(cancellationToken);
            if (line is null) throw new IOException("A conexão QMP foi encerrada antes de retornar uma mensagem.");
            if (!string.IsNullOrWhiteSpace(line)) return line;
        }
    }

    private static async Task<string> ReadQmpResponseAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < 32; attempt++)
        {
            var message = await ReadQmpMessageAsync(reader, cancellationToken);
            using var document = JsonDocument.Parse(message);
            if (document.RootElement.TryGetProperty("return", out _) || document.RootElement.TryGetProperty("error", out _))
                return message;
        }

        throw new InvalidDataException("O servidor QMP não retornou uma resposta de comando.");
    }

    private static bool IsQmpGreeting(string message)
    {
        using var document = JsonDocument.Parse(message);
        return document.RootElement.TryGetProperty("QMP", out _);
    }

    private static bool IsQmpSuccess(string message)
    {
        using var document = JsonDocument.Parse(message);
        return document.RootElement.TryGetProperty("return", out _) && !document.RootElement.TryGetProperty("error", out _);
    }

    private static async Task SendQmpCommandAsync(NetworkStream stream, string command, CancellationToken cancellationToken)
    {
        var payload = Encoding.UTF8.GetBytes($"{{\"execute\":\"{command}\"}}\r\n");
        await stream.WriteAsync(payload.AsMemory(), cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    private static bool HasContent(string path)
    {
        try { return File.Exists(path) && new FileInfo(path).Length > 0; }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    private static string RequireQemuToken(string value, string name)
    {
        var trimmed = value?.Trim() ?? string.Empty;
        if (string.IsNullOrWhiteSpace(trimmed) || trimmed.Any(char.IsWhiteSpace) || trimmed.Contains(',', StringComparison.Ordinal))
            throw new RuntimeOperationException("A configuração de rede do QEMU é inválida.", $"{name} precisa ser um token QEMU sem espaços ou vírgulas.");
        return trimmed;
    }

    private static string RequireIpv4Address(string value, string name)
    {
        var trimmed = RequireQemuToken(value, name);
        if (!IPAddress.TryParse(trimmed, out var address) || address.AddressFamily != AddressFamily.InterNetwork)
            throw new RuntimeOperationException("A configuração de rede do QEMU é inválida.", $"{name} precisa ser um endereço IPv4: '{value}'.");
        return trimmed;
    }

    private static string RequireIpv4Cidr(string value, string name)
    {
        var trimmed = RequireQemuToken(value, name);
        var parts = trimmed.Split('/', 2, StringSplitOptions.None);
        if (parts.Length != 2 || !IPAddress.TryParse(parts[0], out var address) || address.AddressFamily != AddressFamily.InterNetwork ||
            !int.TryParse(parts[1], out var prefixLength) || prefixLength is < 0 or > 32)
            throw new RuntimeOperationException("A configuração de rede do QEMU é inválida.", $"{name} precisa ser um CIDR IPv4, por exemplo 10.0.2.0/24: '{value}'.");
        return trimmed;
    }

    [DllImport("WinHvPlatform.dll", ExactSpelling = true)]
    private static extern int WHvGetCapability(int capabilityCode, out uint capabilityBuffer, uint capabilityBufferSizeInBytes, out uint writtenSizeInBytes);
}
