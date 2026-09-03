using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class SingleInstanceService : IDisposable
{
    private readonly string _mutexName;
    private readonly string _pipeName;
    private Mutex? _mutex;

    public SingleInstanceService(string distributionRoot)
    {
        var canonicalRoot = Path.GetFullPath(distributionRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var identity = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonicalRoot)))[..24];
        _mutexName = $"NeoNewsRuntime.SingleInstance.{identity}";
        _pipeName = $"NeoNewsRuntime.Control.{identity}";
    }

    public bool TryAcquire()
    {
        _mutex = new Mutex(true, _mutexName, out var createdNew);
        if (!createdNew)
        {
            _mutex.Dispose();
            _mutex = null;
        }
        return createdNew;
    }

    public async Task<bool> SendCommandAsync(string command, CancellationToken cancellationToken = default)
    {
        try
        {
            await using var client = new NamedPipeClientStream(".", _pipeName, PipeDirection.Out, PipeOptions.Asynchronous);
            await client.ConnectAsync(1200, cancellationToken).ConfigureAwait(false);
            await using var writer = new StreamWriter(client, Encoding.UTF8, 1024, leaveOpen: true);
            await writer.WriteLineAsync(command.AsMemory(), cancellationToken).ConfigureAwait(false);
            await writer.FlushAsync(cancellationToken).ConfigureAwait(false);
            return true;
        }
        catch (IOException) { return false; }
        catch (TimeoutException) { return false; }
    }

    public async Task RunServerAsync(Func<string, Task> handler, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(
                    _pipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous, 0, 0);
                await server.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                using var reader = new StreamReader(server, Encoding.UTF8, false, 1024, leaveOpen: true);
                var command = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                if (!string.IsNullOrWhiteSpace(command)) await handler(command).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (IOException) when (!cancellationToken.IsCancellationRequested) { }
        }
    }

    public void Dispose()
    {
        if (_mutex is not null)
        {
            try { _mutex.ReleaseMutex(); } catch (ApplicationException) { }
            _mutex.Dispose();
            _mutex = null;
        }
    }
}
