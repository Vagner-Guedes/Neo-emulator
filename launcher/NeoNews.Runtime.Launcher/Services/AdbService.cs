using System.IO.Compression;
using System.Globalization;
using System.Diagnostics;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class AdbService
{
    private readonly RuntimeContext _context;
    private readonly ProcessRunnerService _runner;
    private readonly LogService _logs;
    private readonly SemaphoreSlim _serverGate = new(1, 1);
    private bool _serverOwned;
    private int? _serverProcessId;
    private AdbRuntimeState _state = AdbRuntimeState.Disconnected;
    private AdbRuntimeState _lastLoggedState = AdbRuntimeState.Disconnected;
    private string _lastTransportDetail = "ADB ainda não foi executado.";
    private int? _lastTransportExitCode;
    private DateTimeOffset? _lastDeviceSeenAt;

    public AdbService(RuntimeContext context, ProcessRunnerService runner, LogService logs)
    {
        _context = context;
        _runner = runner;
        _logs = logs;
    }

    public string Transport => _context.Config.Android.Adb.Transport;

    public string ServerEndpoint => $"{_context.Config.Android.Adb.ServerHost}:{_context.Config.Android.Adb.ServerPort}";

    public int ServerPort => _context.Config.Android.Adb.ServerPort;

    public bool IsServerRunning
    {
        get
        {
            return _serverOwned;
        }
    }

    public string Serial
    {
        get
        {
            if (Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase))
                return $"{_context.Config.Android.Adb.Host}:{_context.Config.Android.Adb.HostPort}";

            if (!string.IsNullOrWhiteSpace(_context.Config.Android.Adb.EmulatorSerial))
                return _context.Config.Android.Adb.EmulatorSerial;

            return $"emulator-{_context.Config.Android.Emulator.ValidationPort}";
        }
    }

    public string AdbPath => _context.ResolveAdbPath();
    public AdbRuntimeState State => _state;
    public string LastTransportDetail => _lastTransportDetail;
    public int? LastTransportExitCode => _lastTransportExitCode;
    public DateTimeOffset? LastDeviceSeenAt => _lastDeviceSeenAt;

    public async Task<ProcessResult> ExecuteAsync(
        IEnumerable<string> arguments,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default,
        bool logOutput = true)
    {
        await EnsureOwnedServerAsync(cancellationToken);
        var fullArguments = BuildArguments(new[] { "-s", Serial }.Concat(arguments));
        return await _runner.RunAsync(
            AdbPath,
            fullArguments,
            _context.RootDirectory,
            "adb",
            timeout ?? TimeSpan.FromSeconds(Math.Max(5, _context.Config.Timeouts.AdbSeconds)),
            cancellationToken,
            logOutput,
            BuildEnvironment(),
            _context.Config.HostIsolation.ClearHostToolEnvironment);
    }

    public async Task<ProcessResult> ExecuteHostAsync(
        IEnumerable<string> arguments,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default,
        bool logOutput = false)
    {
        await EnsureOwnedServerAsync(cancellationToken);
        return await _runner.RunAsync(
            AdbPath,
            BuildArguments(arguments),
            _context.RootDirectory,
            "adb",
            timeout ?? TimeSpan.FromSeconds(Math.Max(5, _context.Config.Timeouts.AdbSeconds)),
            cancellationToken,
            logOutput,
            BuildEnvironment(),
            _context.Config.HostIsolation.ClearHostToolEnvironment);
    }

    private async Task EnsureOwnedServerAsync(CancellationToken cancellationToken)
    {
        if (_serverOwned && await IsPrivateServerListeningAsync(cancellationToken)) return;
        _serverOwned = false;
        _serverProcessId = null;
        await StartServerAsync(cancellationToken);
    }

    public Task<ProcessResult> PushFileAsync(
        string localPath,
        string remotePath,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default) =>
        ExecuteAsync(
            ["push", localPath, remotePath],
            timeout ?? TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.AdbSeconds)),
            cancellationToken);

    public async Task StartServerAsync(CancellationToken cancellationToken = default)
    {
        await _serverGate.WaitAsync(cancellationToken);
        try
        {
        var result = await StartOwnedServerAsync(cancellationToken);
        RecordTransportResult($"start-server {ServerEndpoint}", result);
        if (result.Succeeded && Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase))
        {
            // Recreating the private host daemon clears its remembered TCP
            // transport. Reconnect the configured guest before the next
            // shell command, including a reboot requested during provisioning.
            var reconnect = await _runner.RunAsync(
                AdbPath,
                BuildArguments(["connect", Serial]),
                _context.RootDirectory,
                "adb",
                TimeSpan.FromSeconds(10),
                cancellationToken,
                logOutput: false,
                BuildEnvironment(),
                _context.Config.HostIsolation.ClearHostToolEnvironment);
            RecordTransportResult($"connect {Serial} (após iniciar servidor privado)", reconnect);
        }
        if (!result.Succeeded)
        {
            SetState(AdbRuntimeState.Disconnected);
            throw new RuntimeOperationException("Não foi possível iniciar o ADB.", $"ADB: {AdbPath}\n{result.StandardError}\n{result.StandardOutput}");
        }
        }
        finally
        {
            _serverGate.Release();
        }
    }

    private async Task<ProcessResult> StartOwnedServerAsync(CancellationToken cancellationToken)
    {
        if (_serverOwned && await IsPrivateServerListeningAsync(cancellationToken))
            return new ProcessResult(0, "servidor ADB privado já ativo", string.Empty, false, TimeSpan.Zero);

        _serverOwned = false;
        _serverProcessId = null;

        var executable = AdbPath;
        if (!File.Exists(executable))
            throw new RuntimeOperationException("ADB não foi encontrado.", $"Caminho configurado: {executable}");

        if (!_context.Config.Android.Adb.ServerHost.Equals("127.0.0.1", StringComparison.Ordinal))
            throw new RuntimeOperationException("O servidor ADB privado deve usar loopback.", $"Host configurado: {_context.Config.Android.Adb.ServerHost}; esperado: 127.0.0.1.");

        var previousOwner = await HostProcessOwnership.ReadAsync(_context.AdbServerStatePath, cancellationToken);
        if (previousOwner is not null &&
            previousOwner.AdbHostPort == ServerPort &&
            string.Equals(previousOwner.ExecutablePath, executable, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(previousOwner.WorkingDirectory, _context.RootDirectory, StringComparison.OrdinalIgnoreCase) &&
            await IsPrivateServerListeningAsync(cancellationToken))
        {
            // A new launcher instance must not inherit a stale transport from
            // a previous guest. Restart only the exact private server owned by
            // this bundle; the global ADB endpoint remains out of scope.
            _logs.Info("adb", $"Servidor ADB privado anterior encontrado por posse registrada: PID {previousOwner.ProcessId}; reiniciando endpoint={ServerEndpoint}.");
            var resetResult = await _runner.RunAsync(
                executable,
                BuildArguments(["kill-server"]),
                _context.RootDirectory,
                "adb-server",
                TimeSpan.FromSeconds(Math.Max(10, _context.Config.Timeouts.AdbSeconds)),
                cancellationToken,
                false,
                BuildEnvironment(),
                _context.Config.HostIsolation.ClearHostToolEnvironment);
            if (!resetResult.Succeeded)
                throw new RuntimeOperationException(
                    "Não foi possível reiniciar o servidor ADB privado.",
                    $"Endpoint: {ServerEndpoint}; exit={resetResult.ExitCode}; stderr={resetResult.StandardError}; stdout={resetResult.StandardOutput}");

            await HostProcessOwnership.ClearAsync(_context.AdbServerStatePath, previousOwner.ProcessId, cancellationToken);
            for (var attempt = 0; attempt < 20; attempt++)
            {
                if (!await IsPrivateServerListeningAsync(cancellationToken)) break;
                await Task.Delay(100, cancellationToken);
            }
        }

        HostPortGuard.EnsureAvailable(
            _context.Config.Android.Adb.ServerHost,
            ServerPort,
            "servidor ADB privado do NeoNews Runtime");

        try
        {
            // On Windows, `nodaemon server` forks a child and the process
            // returned by ProcessStartInfo exits. Track ownership through the
            // private endpoint so the child cannot look like a dead server.
            var beforeProcessIds = GetAdbProcessIds(executable);
            var result = await _runner.RunAsync(
                executable,
                ["-L", $"tcp:{ServerPort}", "start-server"],
                _context.RootDirectory,
                "adb-server",
                TimeSpan.FromSeconds(Math.Max(10, _context.Config.Timeouts.AdbSeconds)),
                cancellationToken,
                false,
                BuildEnvironment(),
                _context.Config.HostIsolation.ClearHostToolEnvironment);

            if (!result.Succeeded) return result;

            var listening = false;
            for (var attempt = 0; attempt < 20; attempt++)
            {
                if (await IsPrivateServerListeningAsync(cancellationToken))
                {
                    listening = true;
                    break;
                }
                await Task.Delay(100, cancellationToken);
            }
            if (!listening)
                throw new RuntimeOperationException(
                    "O servidor ADB privado não abriu a porta configurada.",
                    $"Executável: {executable}; endpoint: {ServerEndpoint}.");

            _serverOwned = true;
            _serverProcessId = FindNewAdbProcessId(executable, beforeProcessIds);
            var processId = _serverProcessId ?? 0;
            await HostProcessOwnership.WriteAsync(
                _context.AdbServerStatePath,
                new HostProcessRecord(
                    processId,
                    executable,
                    _context.RootDirectory,
                    DateTimeOffset.UtcNow,
                    "ADB private server",
                    ServerEndpoint,
                    0,
                    ServerPort),
                cancellationToken);

            return new ProcessResult(0, "servidor ADB privado ativo", string.Empty, false, TimeSpan.Zero);
        }
        catch
        {
            _serverOwned = false;
            _serverProcessId = null;
            SetState(AdbRuntimeState.Disconnected);
            throw;
        }
    }

    public async Task StopServerAsync(CancellationToken cancellationToken = default)
    {
        if (!_serverOwned) return;

        _serverOwned = false;
        var processId = _serverProcessId ?? 0;
        _serverProcessId = null;
        try
        {
            var result = await _runner.RunAsync(
                AdbPath,
                BuildArguments(["kill-server"]),
                _context.RootDirectory,
                "adb-server",
                TimeSpan.FromSeconds(Math.Max(5, _context.Config.Timeouts.AdbSeconds)),
                cancellationToken,
                false,
                BuildEnvironment(),
                _context.Config.HostIsolation.ClearHostToolEnvironment);
            if (!result.Succeeded)
                _logs.Warning("adb", $"O servidor ADB privado retornou falha ao encerrar: exit={result.ExitCode}; timeout={result.TimedOut}.");
        }
        finally
        {
            await HostProcessOwnership.ClearAsync(_context.AdbServerStatePath, processId, cancellationToken);
        }
    }

    private async Task<bool> IsPrivateServerListeningAsync(CancellationToken cancellationToken)
    {
        using var client = new TcpClient();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMilliseconds(600));
        try
        {
            await client.ConnectAsync("127.0.0.1", ServerPort, timeout.Token);
            return client.Connected;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return false; }
        catch (SocketException) { return false; }
        catch (IOException) { return false; }
    }

    private static HashSet<int> GetAdbProcessIds(string executable)
    {
        var ids = new HashSet<int>();
        foreach (var process in Process.GetProcesses().Where(candidate => candidate.ProcessName.Equals("adb", StringComparison.OrdinalIgnoreCase)))
        {
            try
            {
                if (string.Equals(process.MainModule?.FileName, executable, StringComparison.OrdinalIgnoreCase)) ids.Add(process.Id);
            }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
            finally { process.Dispose(); }
        }
        return ids;
    }

    private static int? FindNewAdbProcessId(string executable, HashSet<int> beforeProcessIds)
    {
        foreach (var process in Process.GetProcesses().Where(candidate => candidate.ProcessName.Equals("adb", StringComparison.OrdinalIgnoreCase)))
        {
            try
            {
                if (!beforeProcessIds.Contains(process.Id) &&
                    string.Equals(process.MainModule?.FileName, executable, StringComparison.OrdinalIgnoreCase))
                    return process.Id;
            }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
            finally { process.Dispose(); }
        }
        return null;
    }

    public async Task<bool> ConnectAsync(CancellationToken cancellationToken = default)
    {
        if (!Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase)) return true;

        var wasOffline = _state == AdbRuntimeState.Offline;
        SetState(AdbRuntimeState.Connecting);
        if (wasOffline)
        {
            var recovered = await RecoverTransportAsync(cancellationToken);
            if (recovered) return true;
        }

        var result = await ExecuteHostAsync(["connect", Serial], TimeSpan.FromSeconds(10), cancellationToken);
        RecordTransportResult($"connect {Serial}", result);
        var connected = result.Succeeded &&
                       !result.StandardOutput.Contains("unable", StringComparison.OrdinalIgnoreCase) &&
                       !result.StandardOutput.Contains("failed", StringComparison.OrdinalIgnoreCase) &&
                       !result.StandardError.Contains("unable", StringComparison.OrdinalIgnoreCase);
        if (!connected) SetState(AdbRuntimeState.Disconnected);
        return connected;
    }

    /// <summary>
    /// Recreates transports that the ADB server has retained as offline.
    /// `adb connect` alone is intentionally not enough here: when a stale
    /// endpoint is already registered it can answer "already connected"
    /// without restarting the transport. This method is only called by the
    /// bounded boot/reconnect loop, never in a tight background loop.
    /// </summary>
    public async Task<bool> ReconnectOfflineAsync(CancellationToken cancellationToken = default)
    {
        if (!Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase)) return true;

        var result = await ExecuteHostAsync(["reconnect", "offline"], TimeSpan.FromSeconds(10), cancellationToken);
        RecordTransportResult($"reconnect offline {Serial}", result);
        return result.Succeeded;
    }

    /// <summary>
    /// Bounded recovery for the private TCP transport. It deliberately uses
    /// only transport-scoped commands; it never kills or restarts an ADB
    /// server, so the global host endpoint remains outside this runtime's
    /// ownership boundary.
    /// </summary>
    public async Task<bool> RecoverTransportAsync(CancellationToken cancellationToken = default)
    {
        if (!Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase)) return true;

        SetState(AdbRuntimeState.Connecting);
        var reconnect = await ReconnectOfflineAsync(cancellationToken);
        var disconnect = await ExecuteHostAsync(["disconnect", Serial], TimeSpan.FromSeconds(10), cancellationToken);
        RecordTransportResult($"disconnect {Serial} (recovery)", disconnect);
        var connect = await ExecuteHostAsync(["connect", Serial], TimeSpan.FromSeconds(10), cancellationToken);
        RecordTransportResult($"connect {Serial} (recovery)", connect);
        var recovered = reconnect && disconnect.Succeeded && connect.Succeeded &&
                        !connect.StandardOutput.Contains("failed", StringComparison.OrdinalIgnoreCase) &&
                        !connect.StandardError.Contains("unable", StringComparison.OrdinalIgnoreCase);
        if (!recovered) SetState(AdbRuntimeState.Disconnected);
        return recovered;
    }

    public async Task DisconnectAsync(CancellationToken cancellationToken = default)
    {
        if (Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase))
        {
            var result = await ExecuteHostAsync(["disconnect", Serial], TimeSpan.FromSeconds(10), cancellationToken);
            RecordTransportResult($"disconnect {Serial}", result);
        }
        SetState(AdbRuntimeState.Disconnected);
    }

    public async Task<string> GetStateAsync(CancellationToken cancellationToken = default)
    {
        var result = await ExecuteAsync(["get-state"], TimeSpan.FromSeconds(8), cancellationToken, logOutput: false);
        RecordTransportResult($"get-state {Serial}", result);
        var combined = $"{result.StandardOutput}\n{result.StandardError}".Trim();
        var state = combined.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? string.Empty;
        if (combined.Contains("unauthorized", StringComparison.OrdinalIgnoreCase)) state = "unauthorized";
        else if (combined.Contains("offline", StringComparison.OrdinalIgnoreCase)) state = "offline";
        SetState(state.ToLowerInvariant() switch
        {
            "device" => AdbRuntimeState.Device,
            "offline" => AdbRuntimeState.Offline,
            "unauthorized" => AdbRuntimeState.Unauthorized,
            _ => AdbRuntimeState.Disconnected
        });
        return state;
    }

    public async Task<bool> IsDeviceOnlineAsync(CancellationToken cancellationToken = default) =>
        string.Equals(await GetStateAsync(cancellationToken), "device", StringComparison.OrdinalIgnoreCase);

    public Task<string> ShellAsync(IEnumerable<string> arguments, TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        return ExecuteShellAsync(arguments, timeout, cancellationToken);
    }

    public Task<ProcessResult> ShellResultAsync(
        IEnumerable<string> arguments,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default,
        bool logOutput = false) =>
        ExecuteAsync(new[] { "shell" }.Concat(arguments), timeout, cancellationToken, logOutput);

    public Task<ProcessResult> ShellCommandResultAsync(
        string command,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default,
        bool logOutput = false) =>
        ExecuteAsync(["shell", command], timeout, cancellationToken, logOutput);

    public async Task<string> ShellCommandAsync(
        string command,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        var result = await ShellCommandResultAsync(command, timeout, cancellationToken);
        return result.StandardOutput.Trim();
    }

    private async Task<string> ExecuteShellAsync(IEnumerable<string> arguments, TimeSpan? timeout, CancellationToken cancellationToken)
    {
        var result = await ExecuteAsync(new[] { "shell" }.Concat(arguments), timeout, cancellationToken, logOutput: false);
        return result.StandardOutput.Trim();
    }

    public Task<string> GetPropertyAsync(string property, CancellationToken cancellationToken = default) =>
        ShellAsync(["getprop", property], TimeSpan.FromSeconds(10), cancellationToken);

    public async Task<AndroidGuestValidationResult> ValidateGuestIdentityAsync(
        string expectedRelease,
        int expectedApiLevel,
        CancellationToken cancellationToken = default)
    {
        var release = await GetPropertyAsync("ro.build.version.release", cancellationToken);
        var api = await GetPropertyAsync("ro.build.version.sdk", cancellationToken);
        var bootCompleted = await GetPropertyAsync("sys.boot_completed", cancellationToken);
        var releaseMatches = string.IsNullOrWhiteSpace(expectedRelease) || release.Equals(expectedRelease, StringComparison.OrdinalIgnoreCase);
        var apiMatches = api.Equals(expectedApiLevel.ToString(), StringComparison.OrdinalIgnoreCase);
        var ready = bootCompleted == "1" && releaseMatches && apiMatches;
        var detail = ready
            ? $"Android {release} / API {api} com sys.boot_completed=1."
            : $"Guest incompatível: release={release}; esperado={expectedRelease}; api={api}; esperada={expectedApiLevel}; sys.boot_completed={bootCompleted}.";
        return new AndroidGuestValidationResult(release, api, bootCompleted, ready, detail);
    }

    public Task<string> GetSettingAsync(string scope, string name, CancellationToken cancellationToken = default) =>
        ShellAsync(["settings", "get", scope, name], TimeSpan.FromSeconds(15), cancellationToken);

    public async Task WaitForBootAsync(IProgress<RuntimeProgress>? progress, TimeSpan timeout, CancellationToken cancellationToken)
    {
        await StartServerAsync(cancellationToken);
        var deadline = DateTimeOffset.UtcNow + timeout;
        var nextConnect = DateTimeOffset.MinValue;
        var setupCompleteApplied = false;
        var nextRecovery = DateTimeOffset.MinValue;
        var recoveryAttempts = 0;
        var consecutiveDeviceProbes = 0;
        DateTimeOffset? lastDeviceProbe = null;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase) && DateTimeOffset.UtcNow >= nextConnect)
            {
                _ = await ConnectAsync(cancellationToken);
                nextConnect = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds));
            }

            var state = await GetStateAsync(cancellationToken);
            if (state.Equals("device", StringComparison.OrdinalIgnoreCase))
            {
                var now = DateTimeOffset.UtcNow;
                if (lastDeviceProbe is null || now - lastDeviceProbe.Value >= TimeSpan.FromSeconds(2))
                    consecutiveDeviceProbes++;
                lastDeviceProbe = now;
                _lastDeviceSeenAt = now;
                nextRecovery = now + TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds));
                // Android-x86 may launch SetupWizard before sys.boot_completed
                // becomes 1. Apply the idempotent setup flags on the first
                // device probe, while the three-probe readiness gate still
                // prevents an unstable transport from being accepted.
                if (!setupCompleteApplied)
                {
                    var earlySetup = await TryEnsureAndroidSetupCompleteAsync(cancellationToken);
                    if (earlySetup.Ready)
                    {
                        setupCompleteApplied = true;
                        _logs.Info("provisioning", $"ANDROID_SETUP_COMPLETE_EARLY {earlySetup.Detail}");
                    }
                }
                if (consecutiveDeviceProbes < 3)
                {
                    SetState(AdbRuntimeState.Booting);
                    ReportStateProgress(progress, "Aguardando transporte ADB", $"ADB device confirmado ({consecutiveDeviceProbes}/3); aguardando estabilidade...", 55);
                    await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
                    continue;
                }
                var boot = await GetPropertyAsync("sys.boot_completed", cancellationToken);
                if (boot == "1")
                {
                    recoveryAttempts = 0;
                    progress?.Report(new RuntimeProgress("Aguardando Package Manager", "Validando pm list packages e pm path android...", 62));
                    await WaitForPackageManagerAsync(TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.PackageManagerSeconds)), cancellationToken);
                    progress?.Report(new RuntimeProgress("Aguardando Settings Provider", "Validando settings antes do provisionamento...", 66));
                    await WaitForSettingsProviderAsync(TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.SettingsProviderSeconds)), cancellationToken);
                    var setup = await TryEnsureAndroidSetupCompleteAsync(cancellationToken);
                    if (!setup.Ready)
                    {
                        throw new RuntimeOperationException(
                            "O Android não confirmou o provisionamento inicial.",
                            setup.Detail);
                    }
                    SetState(AdbRuntimeState.Ready);
                    progress?.Report(new RuntimeProgress("Android pronto", "Android, Package Manager e Settings Provider prontos.", 70));
                    return;
                }

                SetState(AdbRuntimeState.Booting);
                ReportStateProgress(progress, "Aguardando inicialização", "ADB respondeu; verificando Android...", 55);
            }
            else
            {
                if (state.Equals("offline", StringComparison.OrdinalIgnoreCase))
                {
                    consecutiveDeviceProbes = 0;
                    lastDeviceProbe = null;
                    if (DateTimeOffset.UtcNow >= nextRecovery && recoveryAttempts < 5)
                    {
                        recoveryAttempts++;
                        _logs.Warning("adb", $"RECOVERY_PRIVATE_TRANSPORT attempt={recoveryAttempts}/5 serial={Serial}; reconnect offline + disconnect serial + connect serial.");
                        _ = await RecoverTransportAsync(cancellationToken);
                        nextRecovery = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds));
                    }
                }
                else if (state.Equals("disconnected", StringComparison.OrdinalIgnoreCase))
                {
                    consecutiveDeviceProbes = 0;
                    lastDeviceProbe = null;
                }
                ReportStateProgress(progress, "Aguardando ADB", $"Estado ADB: {DescribeState(State)}; tentando reconectar...", null);
            }

            await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds)), cancellationToken);
        }

        throw new RuntimeOperationException(
            "Não foi possível conectar ao Android.",
            $"ADB não confirmou o boot do transporte {Serial} em {timeout.TotalSeconds:0} segundos. Último estado: {State}.");
    }

    public async Task<(bool Ready, string Detail)> EnsureAndroidSetupCompleteAsync(CancellationToken cancellationToken = default)
    {
        var result = await TryEnsureAndroidSetupCompleteAsync(cancellationToken);
        if (!result.Ready)
        {
            throw new RuntimeOperationException(
                "O Android não confirmou o provisionamento inicial.",
                result.Detail);
        }
        return result;
    }

    private async Task<(bool Ready, string Detail)> TryEnsureAndroidSetupCompleteAsync(CancellationToken cancellationToken)
    {
        try
        {
            // Android-x86 can expose ADB as `device` a few seconds before the
            // Settings Provider is usable. In that window `settings` has
            // historically returned exit 0 while printing a provider NPE.
            // Retry the supported provisioning commands and accept success
            // only after their output is free of transient Android errors.
            var globalWrite = await ExecuteProvisioningCommandWithRetryAsync(["settings", "put", "global", "device_provisioned", "1"], cancellationToken);
            var secureWrite = await ExecuteProvisioningCommandWithRetryAsync(["settings", "put", "secure", "user_setup_complete", "1"], cancellationToken);
            var globalRead = await ExecuteProvisioningCommandWithRetryAsync(["settings", "get", "global", "device_provisioned"], cancellationToken);
            var secureRead = await ExecuteProvisioningCommandWithRetryAsync(["settings", "get", "secure", "user_setup_complete"], cancellationToken);
            // Android-x86 can have already launched SetupWizard before the
            // idempotent flags are written. Stop only that package instance;
            // the package remains installed and enabled for future diagnostics.
            var setupWizardStop = await ExecuteProvisioningCommandWithRetryAsync(["am", "force-stop", "com.google.android.setupwizard"], cancellationToken);
            var global = globalRead.StandardOutput.Trim();
            var secure = secureRead.StandardOutput.Trim();
            var ready = globalWrite.Succeeded && secureWrite.Succeeded && globalRead.Succeeded && secureRead.Succeeded && setupWizardStop.Succeeded && global == "1" && secure == "1";
            var detail = $"device_provisioned={global}; user_setup_complete={secure}; setupWizardStopExit={setupWizardStop.ExitCode}; globalWriteExit={globalWrite.ExitCode}; secureWriteExit={secureWrite.ExitCode}; globalReadExit={globalRead.ExitCode}; secureReadExit={secureRead.ExitCode}";
            return (ready, detail);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            return (false, $"settings indisponível durante o boot: {exception.Message}");
        }
    }

    private async Task<ProcessResult> ExecuteProvisioningCommandWithRetryAsync(
        IEnumerable<string> arguments,
        CancellationToken cancellationToken)
    {
        ProcessResult? last = null;
        for (var attempt = 0; attempt < 6; attempt++)
        {
            last = await ShellResultAsync(arguments, TimeSpan.FromSeconds(15), cancellationToken);
            var combined = $"{last.StandardOutput}\n{last.StandardError}";
            var transientFailure = Regex.IsMatch(
                combined,
                "(?i)Error while|NullPointerException|device offline|Can.t connect to activity manager|is the system running");
            if (last.Succeeded && !transientFailure) return last;
            if (attempt < 5) await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
        }
        return last!;
    }

    public async Task WaitForPackageManagerAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        ProcessResult? lastPackages = null;
        ProcessResult? lastAndroidPath = null;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lastPackages = await ShellResultAsync(["pm", "list", "packages"], TimeSpan.FromSeconds(20), cancellationToken);
            lastAndroidPath = await ShellResultAsync(["pm", "path", "android"], TimeSpan.FromSeconds(20), cancellationToken);
            var packagesReady = lastPackages.Succeeded && lastPackages.StandardOutput.Contains("package:", StringComparison.OrdinalIgnoreCase);
            var androidPathReady = lastAndroidPath.Succeeded && lastAndroidPath.StandardOutput.Contains("package:", StringComparison.OrdinalIgnoreCase);
            if (packagesReady && androidPathReady) return;
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds)), cancellationToken);
        }

        throw new RuntimeOperationException(
            "O Package Manager do Android não ficou pronto.",
            $"pm list packages: exit={lastPackages?.ExitCode}; {lastPackages?.StandardError}; pm path android: exit={lastAndroidPath?.ExitCode}; {lastAndroidPath?.StandardError}");
    }

    public async Task WaitForSettingsProviderAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        ProcessResult? lastGlobal = null;
        ProcessResult? lastSecure = null;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lastGlobal = await ShellResultAsync(["settings", "list", "global"], TimeSpan.FromSeconds(20), cancellationToken);
            lastSecure = await ShellResultAsync(["settings", "list", "secure"], TimeSpan.FromSeconds(20), cancellationToken);
            var globalReady = lastGlobal.Succeeded && !lastGlobal.StandardError.Contains("error", StringComparison.OrdinalIgnoreCase);
            var secureReady = lastSecure.Succeeded && !lastSecure.StandardError.Contains("error", StringComparison.OrdinalIgnoreCase);
            if (globalReady && secureReady) return;
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds)), cancellationToken);
        }

        throw new RuntimeOperationException(
            "O Settings Provider do Android não ficou pronto.",
            $"settings global: exit={lastGlobal?.ExitCode}; {lastGlobal?.StandardError}; settings secure: exit={lastSecure?.ExitCode}; {lastSecure?.StandardError}");
    }

    public async Task<LocaleValidationResult> ReadLocaleAsync(CancellationToken cancellationToken = default)
    {
        var locale = await GetPropertyAsync("persist.sys.locale", cancellationToken);
        var language = await GetPropertyAsync("persist.sys.language", cancellationToken);
        var country = await GetPropertyAsync("persist.sys.country", cancellationToken);
        var systemLocales = await GetSettingAsync("system", "system_locales", cancellationToken);
        var effective = FirstNonEmpty(locale, systemLocales, CombineLocale(language, country));
        return new LocaleValidationResult("pt-BR", effective, IsPtBr(effective), locale, language, country, systemLocales);
    }

    public async Task<LocaleValidationResult> EnsurePtBrLocaleAsync(CancellationToken cancellationToken = default)
    {
        var current = await ReadLocaleAsync(cancellationToken);
        if (current.IsPtBr) return current with { RebootRequired = false };

        var changed = false;
        var localeResult = await ShellResultAsync(["setprop", "persist.sys.locale", "pt-BR"], TimeSpan.FromSeconds(20), cancellationToken);
        if (localeResult.Succeeded) changed = true;
        var languageResult = await ShellResultAsync(["setprop", "persist.sys.language", "pt"], TimeSpan.FromSeconds(20), cancellationToken);
        var countryResult = await ShellResultAsync(["setprop", "persist.sys.country", "BR"], TimeSpan.FromSeconds(20), cancellationToken);
        changed = changed || languageResult.Succeeded || countryResult.Succeeded;
        var settingsResult = await ShellResultAsync(["settings", "put", "system", "system_locales", "pt-BR"], TimeSpan.FromSeconds(20), cancellationToken);
        changed = changed || settingsResult.Succeeded;
        if (!changed)
        {
            throw new RuntimeOperationException(
                "Não foi possível configurar o idioma do Android.",
                $"setprop locale: {localeResult.StandardError}; setprop language: {languageResult.StandardError}; setprop country: {countryResult.StandardError}; settings: {settingsResult.StandardError}");
        }

        var after = await ReadLocaleAsync(cancellationToken);
        return after with { RebootRequired = !after.IsPtBr };
    }

    public async Task<ClockValidationResult> EnsureHostClockAsync(
        string timezone,
        int maxSkewSeconds,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(timezone))
            throw new RuntimeOperationException("O fuso horário do Android não está configurado.", "runtime.timezone está vazio.");

        var configuredTimezone = timezone.Trim();
        await ExecuteClockCommandAsync(
            ["setprop", "persist.sys.timezone", configuredTimezone],
            TimeSpan.FromSeconds(20),
            cancellationToken,
            $"setprop persist.sys.timezone {configuredTimezone}");

        // The portable guest has no reason to let network time overwrite the
        // host-controlled clock. The launcher synchronizes it on every start.
        await ExecuteClockCommandAsync(
            ["settings", "put", "global", "auto_time", "0"],
            TimeSpan.FromSeconds(20),
            cancellationToken,
            "desabilitar ajuste automático do relógio");
        await ExecuteClockCommandAsync(
            ["settings", "put", "global", "auto_time_zone", "0"],
            TimeSpan.FromSeconds(20),
            cancellationToken,
            "desabilitar ajuste automático do fuso horário");

        var hostBeforeSet = DateTimeOffset.Now;
        // Android-x86's toolbox date parser treats the legacy numeric value as
        // local time in the configured guest timezone. Send the Windows local
        // wall-clock value so that the resulting epoch matches the host.
        var dateValue = hostBeforeSet.LocalDateTime.ToString("MMddHHmmyyyy.ss", CultureInfo.InvariantCulture);
        await ExecuteClockCommandAsync(
            ["date", dateValue],
            TimeSpan.FromSeconds(20),
            cancellationToken,
            $"date (ADB root) {dateValue}");

        var guestEpochResult = await ExecuteClockCommandAsync(
            ["date", "+%s"],
            TimeSpan.FromSeconds(10),
            cancellationToken,
            "date +%s");
        var guestEpochText = guestEpochResult.StandardOutput;
        if (!long.TryParse(guestEpochText.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var guestEpoch))
        {
            throw new RuntimeOperationException(
                "O relógio do Android não pôde ser validado.",
                $"date +%s retornou um valor inválido: '{guestEpochText}'.");
        }

        var hostAfterSet = DateTimeOffset.Now;
        var hostEpoch = hostAfterSet.ToUnixTimeSeconds();
        var skewSeconds = guestEpoch - hostEpoch;
        var guestTimezoneResult = await ExecuteClockCommandAsync(
            ["getprop", "persist.sys.timezone"],
            TimeSpan.FromSeconds(10),
            cancellationToken,
            "getprop persist.sys.timezone");
        var guestTimezone = guestTimezoneResult.StandardOutput.Trim();
        var allowedSkew = Math.Max(0, maxSkewSeconds);
        var validated = guestTimezone.Equals(configuredTimezone, StringComparison.OrdinalIgnoreCase) &&
                        Math.Abs(skewSeconds) <= allowedSkew;
        var detail = validated
            ? $"timezone={guestTimezone}; host={hostAfterSet:O}; guestEpoch={guestEpoch}; skewSeconds={skewSeconds}."
            : $"timezone={guestTimezone}; expectedTimezone={configuredTimezone}; host={hostAfterSet:O}; guestEpoch={guestEpoch}; skewSeconds={skewSeconds}; allowedSkewSeconds={allowedSkew}.";
        return new ClockValidationResult(
            configuredTimezone,
            guestTimezone,
            hostAfterSet,
            DateTimeOffset.FromUnixTimeSeconds(guestEpoch),
            skewSeconds,
            validated,
            detail);
    }

    private async Task<ProcessResult> ExecuteClockCommandAsync(
        IEnumerable<string> shellArguments,
        TimeSpan timeout,
        CancellationToken cancellationToken,
        string operation)
    {
        ProcessResult? lastResult = null;
        var lastDetail = "ADB não confirmou o estado device.";

        for (var attempt = 1; attempt <= 3; attempt++)
        {
            try
            {
                var ready = await WaitForStateAsync("device", TimeSpan.FromSeconds(30), cancellationToken);
                if (ready)
                {
                    lastResult = await ShellResultAsync(shellArguments, timeout, cancellationToken);
                    if (lastResult.Succeeded) return lastResult;

                    lastDetail = $"exit={lastResult.ExitCode}; stderr={lastResult.StandardError}; stdout={lastResult.StandardOutput}";
                }
                else
                {
                    lastDetail = "ADB permaneceu offline ou desconectado durante a espera.";
                }
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception exception)
            {
                lastDetail = exception.Message;
            }

            SetState(AdbRuntimeState.Offline);
            if (attempt < 3)
            {
                _logs.Warning("adb", $"Comando de relógio aguardará reconexão ({attempt}/3): {operation}; {lastDetail}");
                try { await ReconnectOfflineAsync(cancellationToken); } catch { }
                await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
            }
        }

        throw new RuntimeOperationException(
            "Não foi possível aplicar a configuração do Android.",
            $"Operação: {operation}; {lastDetail}; último resultado={lastResult?.ExitCode}");
    }

    public async Task RebootGuestAsync(CancellationToken cancellationToken = default)
    {
        var result = await ShellResultAsync(["reboot"], TimeSpan.FromSeconds(20), cancellationToken);
        var rebootOutput = $"{result.StandardError}\n{result.StandardOutput}";
        // ADB may report the transport as closed/offline immediately after
        // Android accepted the reboot request. Let WaitForBootAsync validate
        // the next boot instead of rejecting that expected hand-off.
        var expectedDisconnect = rebootOutput.Contains("closed", StringComparison.OrdinalIgnoreCase) ||
                                 rebootOutput.Contains("offline", StringComparison.OrdinalIgnoreCase) ||
                                 rebootOutput.Contains("read failed", StringComparison.OrdinalIgnoreCase) ||
                                 rebootOutput.Contains("connection terminated", StringComparison.OrdinalIgnoreCase) ||
                                 rebootOutput.Contains("no such device", StringComparison.OrdinalIgnoreCase) ||
                                 (rebootOutput.Contains("device", StringComparison.OrdinalIgnoreCase) &&
                                  rebootOutput.Contains("not found", StringComparison.OrdinalIgnoreCase));
        if (!result.Succeeded && !expectedDisconnect)
        {
            throw new RuntimeOperationException("Não foi possível reiniciar o Android.", $"adb shell reboot: exit={result.ExitCode}; {result.StandardError}; {result.StandardOutput}");
        }
        SetState(AdbRuntimeState.Booting);
    }

    public async Task<bool> IsPackageInstalledAsync(string packageName, CancellationToken cancellationToken = default)
    {
        var path = await ShellAsync(["pm", "path", packageName], TimeSpan.FromSeconds(15), cancellationToken);
        return path.StartsWith("package:", StringComparison.Ordinal);
    }

    public Task<bool> WaitForDeviceAsync(TimeSpan timeout, CancellationToken cancellationToken = default) =>
        WaitForStateAsync("device", timeout, cancellationToken);

    private async Task<bool> WaitForStateAsync(string expectedState, TimeSpan timeout, CancellationToken cancellationToken)
    {
        await StartServerAsync(cancellationToken);
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (Transport.Equals("tcp", StringComparison.OrdinalIgnoreCase)) _ = await ConnectAsync(cancellationToken);
            if (string.Equals(await GetStateAsync(cancellationToken), expectedState, StringComparison.OrdinalIgnoreCase)) return true;
            await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, _context.Config.Timeouts.AdbRetrySeconds)), cancellationToken);
        }
        return false;
    }

    public Task<string> GetPackageDumpAsync(string packageName, CancellationToken cancellationToken = default) =>
        ShellAsync(["dumpsys", "package", packageName], TimeSpan.FromSeconds(30), cancellationToken);

    public async Task<string?> GetPackageVersionAsync(string packageName, CancellationToken cancellationToken = default)
    {
        var dump = await GetPackageDumpAsync(packageName, cancellationToken);
        var match = Regex.Match(dump, @"versionName=([^\s]+)");
        return match.Success ? match.Groups[1].Value : null;
    }

    public async Task<string?> GetPrimaryCpuAbiAsync(string packageName, CancellationToken cancellationToken = default)
    {
        var dump = await GetPackageDumpAsync(packageName, cancellationToken);
        var match = Regex.Match(dump, @"primaryCpuAbi=([^\s]+)");
        return match.Success ? match.Groups[1].Value : null;
    }

    public async Task<int?> GetPackageVersionCodeAsync(string packageName, CancellationToken cancellationToken = default)
    {
        var dump = await GetPackageDumpAsync(packageName, cancellationToken);
        var match = Regex.Match(dump, @"versionCode=(\d+)");
        return match.Success && int.TryParse(match.Groups[1].Value, out var versionCode) ? versionCode : null;
    }

    public Task<string> GetActivityDumpAsync(CancellationToken cancellationToken = default) =>
        ShellAsync(["dumpsys", "activity", "activities"], TimeSpan.FromSeconds(20), cancellationToken);

    public async Task<bool> IsActivityRunningAsync(string packageName, string activityName, CancellationToken cancellationToken = default)
    {
        var dump = await GetActivityDumpAsync(cancellationToken);
        var normalizedActivity = activityName.Trim();
        if (normalizedActivity.StartsWith(packageName + ".", StringComparison.Ordinal))
            normalizedActivity = normalizedActivity[(packageName.Length + 1)..];
        if (normalizedActivity.StartsWith(".", StringComparison.Ordinal)) normalizedActivity = normalizedActivity[1..];

        var candidates = new[]
        {
            $"{packageName}/{normalizedActivity}",
            $"{packageName}/.{normalizedActivity}",
            $"{packageName}/{packageName}.{normalizedActivity}"
        };
        var foregroundMarkers = new[] { "mResumedActivity", "topResumedActivity", "ResumedActivity", "mFocusedActivity", "mCurrentFocus" };
        return dump.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries)
            .Any(line => foregroundMarkers.Any(marker => line.Contains(marker, StringComparison.OrdinalIgnoreCase)) &&
                         candidates.Any(candidate => line.Contains(candidate, StringComparison.OrdinalIgnoreCase)));
    }

    public async Task StartActivityAsync(string packageName, string activityName, CancellationToken cancellationToken = default)
    {
        var componentActivity = activityName.StartsWith(".", StringComparison.Ordinal) ||
                                activityName.StartsWith(packageName + ".", StringComparison.Ordinal)
            ? activityName
            : $".{activityName}";
        var component = $"{packageName}/{componentActivity}";
        var result = await ExecuteAsync(["shell", "am", "start", "-W", "-n", component], TimeSpan.FromSeconds(Math.Max(10, _context.Config.Timeouts.NeoNewsStartSeconds)), cancellationToken);
        if (!result.Succeeded)
        {
            throw new RuntimeOperationException(
                "Não foi possível abrir o NeoNews.",
                $"Comando: adb -s {Serial} shell am start -W -n {component}\nExit code: {result.ExitCode}\nstderr: {result.StandardError}");
        }

        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(Math.Max(10, _context.Config.Timeouts.NeoNewsStartSeconds));
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (await IsActivityRunningAsync(packageName, activityName, cancellationToken)) return;
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
        }

        throw new RuntimeOperationException("O NeoNews não confirmou a atividade em execução.", $"Activity esperada: {component}");
    }

    public Task ForceStopAsync(string packageName, CancellationToken cancellationToken = default) => StopPackageAsync(packageName, cancellationToken);

    public async Task StopPackageAsync(string packageName, CancellationToken cancellationToken = default) =>
        _ = await ExecuteAsync(["shell", "am", "force-stop", packageName], TimeSpan.FromSeconds(30), cancellationToken);

    public async Task InstallApkAsync(string apkPath, CancellationToken cancellationToken = default)
    {
        ValidateApkFile(apkPath);
        _logs.Info("launcher", $"Instalação autorizada do APK: {apkPath}");
        var result = await ExecuteAsync(["install", "-r", apkPath], TimeSpan.FromSeconds(Math.Max(30, _context.Config.Timeouts.InstallSeconds)), cancellationToken);
        if (!result.Succeeded || !result.StandardOutput.Contains("Success", StringComparison.OrdinalIgnoreCase))
        {
            throw new RuntimeOperationException(
                "Não foi possível instalar o NeoNews.",
                $"Exit code: {result.ExitCode}\n{result.StandardError}\n{result.StandardOutput}");
        }
    }

    public Task InstallAuthorizedApkAsync(string apkPath, CancellationToken cancellationToken = default) => InstallApkAsync(apkPath, cancellationToken);

    public Task PutSettingAsync(string scope, string name, string value, CancellationToken cancellationToken = default) =>
        ExecuteCheckedAsync(["shell", "settings", "put", scope, name, value], TimeSpan.FromSeconds(20), cancellationToken, $"settings put {scope}/{name}");

    public Task DeleteSettingAsync(string scope, string name, CancellationToken cancellationToken = default) =>
        ExecuteCheckedAsync(["shell", "settings", "delete", scope, name], TimeSpan.FromSeconds(20), cancellationToken, $"settings delete {scope}/{name}");

    public async Task SetDisplayAsync(string size, int density, CancellationToken cancellationToken = default)
    {
        await ExecuteCheckedAsync(["shell", "wm", "size", size], TimeSpan.FromSeconds(20), cancellationToken, "wm size");
        await ExecuteCheckedAsync(["shell", "wm", "density", density.ToString()], TimeSpan.FromSeconds(20), cancellationToken, "wm density");
    }

    public Task ResetDisplaySizeAsync(CancellationToken cancellationToken = default) =>
        ExecuteCheckedAsync(["shell", "wm", "size", "reset"], TimeSpan.FromSeconds(20), cancellationToken, "wm size reset");

    public Task ResetDisplayDensityAsync(CancellationToken cancellationToken = default) =>
        ExecuteCheckedAsync(["shell", "wm", "density", "reset"], TimeSpan.FromSeconds(20), cancellationToken, "wm density reset");

    public Task SetDisplaySizeAsync(string size, CancellationToken cancellationToken = default) =>
        ExecuteCheckedAsync(["shell", "wm", "size", size], TimeSpan.FromSeconds(20), cancellationToken, "wm size restore");

    public Task SetDisplayDensityAsync(string density, CancellationToken cancellationToken = default) =>
        ExecuteCheckedAsync(["shell", "wm", "density", density], TimeSpan.FromSeconds(20), cancellationToken, "wm density restore");

    public Task<string> GetDisplaySizeAsync(CancellationToken cancellationToken = default) => ShellAsync(["wm", "size"], TimeSpan.FromSeconds(20), cancellationToken);
    public Task<string> GetDisplayDensityAsync(CancellationToken cancellationToken = default) => ShellAsync(["wm", "density"], TimeSpan.FromSeconds(20), cancellationToken);
    public async Task<string> GetWebViewDumpAsync(CancellationToken cancellationToken = default)
    {
        var dump = await ShellAsync(["dumpsys", "webviewupdate"], TimeSpan.FromSeconds(20), cancellationToken);
        if (dump.Contains("Current WebView package", StringComparison.OrdinalIgnoreCase)) return dump;

        // Android-x86 7.1-r5 exposes a working WebViewUpdateService but its
        // dumpsys handler returns an empty payload. Preserve the same parser
        // contract with the persisted framework selection in that case.
        var selected = await ShellAsync(["settings", "get", "global", "webview_provider"], TimeSpan.FromSeconds(15), cancellationToken);
        return string.IsNullOrWhiteSpace(selected)
            ? dump
            : $"{dump}\nCurrent WebView package (Android-x86 setting): {selected.Trim()}";
    }
    public Task<string> GetTtsDefaultAsync(CancellationToken cancellationToken = default) => ShellAsync(["settings", "get", "secure", "tts_default_synth"], TimeSpan.FromSeconds(15), cancellationToken);
    public Task<string> CheckTtsDataAsync(string language, string country, CancellationToken cancellationToken = default) =>
        ShellAsync(["am", "broadcast", "-a", "android.speech.tts.engine.CHECK_TTS_DATA", "--es", "language", language, "--es", "country", country], TimeSpan.FromSeconds(20), cancellationToken);
    public Task<string> GetPackagesAsync(CancellationToken cancellationToken = default) => ShellAsync(["pm", "list", "packages"], TimeSpan.FromSeconds(30), cancellationToken);
    public Task<string> GetMemoryDumpAsync(CancellationToken cancellationToken = default) => ShellAsync(["dumpsys", "meminfo"], TimeSpan.FromSeconds(30), cancellationToken);
    public Task<string> GetGraphicsDumpAsync(CancellationToken cancellationToken = default) => ShellAsync(["dumpsys", "gfxinfo"], TimeSpan.FromSeconds(30), cancellationToken);
    public Task<string> GetLogcatAsync(int lines, CancellationToken cancellationToken = default) => ShellAsync(["logcat", "-d", "-b", "all", "-t", lines.ToString()], TimeSpan.FromMinutes(2), cancellationToken);

    public async Task EnsureRootAsync(CancellationToken cancellationToken = default)
    {
        var lastDetail = "Nenhuma tentativa foi concluída.";
        for (var attempt = 1; attempt <= 3; attempt++)
        {
            var identityResult = await ExecuteAsync(["shell", "id"], TimeSpan.FromSeconds(10), cancellationToken, logOutput: false);
            var identity = identityResult.StandardOutput.Trim();
            if (identity.Contains("uid=0(root)", StringComparison.OrdinalIgnoreCase)) return;

            var result = await ExecuteAsync(["root"], TimeSpan.FromSeconds(20), cancellationToken);
            var rootRequested = result.Succeeded || result.StandardOutput.Contains("already running as root", StringComparison.OrdinalIgnoreCase);
            if (rootRequested)
            {
                var ready = await WaitForStateAsync("device", TimeSpan.FromSeconds(30), cancellationToken);
                var rootIdentityResult = await ExecuteAsync(["shell", "id"], TimeSpan.FromSeconds(10), cancellationToken, logOutput: false);
                var rootIdentity = rootIdentityResult.StandardOutput.Trim();
                if (ready && rootIdentity.Contains("uid=0(root)", StringComparison.OrdinalIgnoreCase)) return;
                lastDetail = $"tentativa={attempt}; adb root solicitado; ready={ready}; identity={rootIdentity}; exit={rootIdentityResult.ExitCode}; stderr={rootIdentityResult.StandardError}";
            }
            else
            {
                lastDetail = $"tentativa={attempt}; adb root falhou; exit={result.ExitCode}; stdout={result.StandardOutput}; stderr={result.StandardError}; identity={identity}";
            }

            if (attempt < 3)
            {
                _logs.Warning("adb", $"ADB root ainda não foi confirmado ({attempt}/3); aguardando reconexão do guest.");
                SetState(AdbRuntimeState.Offline);
                await ConnectAsync(cancellationToken);
                await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
            }
        }

        throw new RuntimeOperationException(
            "O guest Android não confirmou ADB root.",
            $"A configuração persistente do guest exige uid=0 para alterar /system e a política local do Superuser. {lastDetail}");
    }

    private async Task ExecuteCheckedAsync(IEnumerable<string> arguments, TimeSpan timeout, CancellationToken cancellationToken, string operation)
    {
        var result = await ExecuteAsync(arguments, timeout, cancellationToken);
        if (!result.Succeeded)
        {
            throw new RuntimeOperationException(
                "Não foi possível aplicar a configuração do Android.",
                $"Operação: {operation}; exit code: {result.ExitCode}; stderr: {result.StandardError}; stdout: {result.StandardOutput}");
        }
    }

    private void ValidateApkFile(string apkPath)
    {
        if (!File.Exists(apkPath))
            throw new RuntimeOperationException("NeoNews.apk não encontrado.", $"Caminho esperado: {apkPath}");

        try
        {
            using var archive = ZipFile.OpenRead(apkPath);
            var abis = archive.Entries
                .Select(entry => Regex.Match(entry.FullName, @"^lib/([^/]+)/"))
                .Where(match => match.Success)
                .Select(match => match.Groups[1].Value)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            var preferred = _context.Config.Android.PreferredApkAbi;
            var supported = _context.Config.NeoNews.SupportedApkAbis;
            if (abis.Length == 0 || (supported.Count > 0 && !abis.Intersect(supported, StringComparer.OrdinalIgnoreCase).Any()))
                throw new RuntimeOperationException("O APK selecionado não é compatível com o NeoNews.", $"Nenhuma ABI esperada foi encontrada. ABIs do APK: {string.Join(", ", abis)}; esperadas: {string.Join(", ", supported)}.");
            if (!string.IsNullOrWhiteSpace(preferred) && !abis.Contains(preferred, StringComparer.OrdinalIgnoreCase))
                throw new RuntimeOperationException("O APK não contém a ABI ARM32 homologada.", $"ABI preferencial ausente: {preferred}; ABIs do APK: {string.Join(", ", abis)}.");
        }
        catch (InvalidDataException exception)
        {
            throw new RuntimeOperationException("O arquivo APK é inválido.", $"Não foi possível ler o APK como ZIP: {exception.Message}", exception);
        }
    }

    private IEnumerable<string> BuildArguments(IEnumerable<string> arguments)
    {
        var port = ServerPort;
        if (port is < 1 or > 65535)
            throw new RuntimeOperationException("A porta do servidor ADB privado é inválida.", $"Porta configurada: {port}. Esperada: 1..65535.");
        return new[] { "-P", port.ToString(CultureInfo.InvariantCulture) }.Concat(arguments);
    }

    private IReadOnlyDictionary<string, string?> BuildEnvironment() => new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
    {
        // Defense in depth: the CLI flag above selects the server, while this
        // variable keeps the daemon spawned by adb on the same private port.
        ["ANDROID_ADB_SERVER_PORT"] = ServerPort.ToString(CultureInfo.InvariantCulture)
    };

    private void SetState(AdbRuntimeState state)
    {
        _state = state;
        if (state == _lastLoggedState) return;
        _lastLoggedState = state;
        _logs.Info("adb", $"Estado ADB: {DescribeState(state)} ({Serial}).");
    }

    private void RecordTransportResult(string operation, ProcessResult result)
    {
        _lastTransportExitCode = result.ExitCode;
        var output = string.Join(" | ", new[] { result.StandardOutput.Trim(), result.StandardError.Trim() }
            .Where(value => !string.IsNullOrWhiteSpace(value)));
        if (output.Length > 1200) output = output[..1200];
        _lastTransportDetail = string.IsNullOrWhiteSpace(output)
            ? $"{operation}: exit={result.ExitCode}; timeout={result.TimedOut}."
            : $"{operation}: exit={result.ExitCode}; timeout={result.TimedOut}; {output}";
    }

    private static string DescribeState(AdbRuntimeState state) => state switch
    {
        AdbRuntimeState.Device => "device",
        AdbRuntimeState.Offline => "offline",
        AdbRuntimeState.Unauthorized => "unauthorized",
        AdbRuntimeState.Booting => "booting",
        AdbRuntimeState.Ready => "ready",
        AdbRuntimeState.Connecting => "connecting",
        _ => "disconnected"
    };

    private static void ReportStateProgress(IProgress<RuntimeProgress>? progress, string phase, string detail, double? percent) =>
        progress?.Report(new RuntimeProgress(phase, detail, percent));

    private static string FirstNonEmpty(params string[] values) => values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim() ?? string.Empty;

    private static string CombineLocale(string language, string country) =>
        string.IsNullOrWhiteSpace(language) ? string.Empty : string.IsNullOrWhiteSpace(country) ? language : $"{language}-{country}";

    private static bool IsPtBr(string value) =>
        Regex.IsMatch(value ?? string.Empty, @"^(pt[-_]?(BR|rBR)|pt_BR)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}

public sealed record AndroidGuestValidationResult(
    string Release,
    string ApiLevel,
    string BootCompleted,
    bool Ready,
    string Detail);

public sealed record LocaleValidationResult(
    string Requested,
    string Effective,
    bool IsPtBr,
    string PersistedLocale,
    string PersistedLanguage,
    string PersistedCountry,
    string SystemLocales,
    bool RebootRequired = false);

public sealed record ClockValidationResult(
    string ConfiguredTimezone,
    string GuestTimezone,
    DateTimeOffset HostTime,
    DateTimeOffset GuestTime,
    long SkewSeconds,
    bool Validated,
    string Detail);
