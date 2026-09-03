using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed record HostProcessRecord(
    int ProcessId,
    string ExecutablePath,
    string WorkingDirectory,
    DateTimeOffset StartedUtc,
    string Backend,
    string ADBTransport,
    int QmpPort,
    int AdbHostPort);

public static class HostPortGuard
{
    public static void EnsureAvailable(string host, int port, string purpose)
    {
        if (port is < 1 or > 65535)
            throw new RuntimeOperationException("A configuração de portas do runtime é inválida.", $"{purpose}: porta {port}; esperado 1..65535.");

        if (!IPAddress.TryParse(host, out var address) || address.AddressFamily != AddressFamily.InterNetwork)
            throw new RuntimeOperationException("A configuração de rede do runtime é inválida.", $"{purpose}: host IPv4 inválido '{host}'.");

        try
        {
            using var listener = new TcpListener(address, port);
            listener.Start();
            listener.Stop();
        }
        catch (SocketException exception)
        {
            throw new RuntimeOperationException(
                $"A porta privada do runtime está em uso: {purpose}.",
                $"Endpoint={host}:{port}. Nenhum processo externo será encerrado. Feche/reconfigure apenas o proprietário dessa porta (outro NeoNews Runtime, Android Studio, QEMU ou serviço ADB). SocketError={exception.SocketErrorCode}.",
                exception);
        }
    }

    public static void EnsureDistinct(params (string Name, int Port)[] ports)
    {
        var duplicate = ports.GroupBy(item => item.Port).FirstOrDefault(group => group.Count() > 1);
        if (duplicate is not null)
            throw new RuntimeOperationException(
                "A configuração de portas privadas do runtime é inválida.",
                $"A porta {duplicate.Key} foi atribuída a: {string.Join(", ", duplicate.Select(item => item.Name))}.");
    }
}

public static class HostProcessOwnership
{
    public static async Task WriteAsync(string path, HostProcessRecord record, CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporaryPath = path + ".tmp";
        await File.WriteAllTextAsync(temporaryPath, JsonSerializer.Serialize(record, RuntimeContext.JsonOptions), cancellationToken);
        File.Move(temporaryPath, path, true);
    }

    public static async Task ClearAsync(string path, int processId, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(path)) return;
        try
        {
            await using var stream = File.OpenRead(path);
            var record = await JsonSerializer.DeserializeAsync<HostProcessRecord>(stream, RuntimeContext.JsonOptions, cancellationToken);
            if (record is null || record.ProcessId != processId) return;
            File.Delete(path);
        }
        catch (FileNotFoundException) { }
        catch (DirectoryNotFoundException) { }
    }
}
