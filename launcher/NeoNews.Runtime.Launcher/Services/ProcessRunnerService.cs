using System.Diagnostics;
using System.IO;

namespace NeoNews.Runtime.Launcher.Services;

public sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError, bool TimedOut, TimeSpan Duration)
{
    public bool Succeeded => ExitCode == 0 && !TimedOut;
}

public sealed class ManagedProcess : IAsyncDisposable
{
    private readonly Process _process;
    private readonly Task _standardOutputTask;
    private readonly Task _standardErrorTask;

    internal ManagedProcess(Process process, Task standardOutputTask, Task standardErrorTask)
    {
        _process = process;
        _standardOutputTask = standardOutputTask;
        _standardErrorTask = standardErrorTask;
    }

    public int ProcessId => _process.Id;
    public bool HasExited => _process.HasExited;

    public async Task StopAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        if (!_process.HasExited)
        {
            try { _process.CloseMainWindow(); } catch { }

            var waitTask = _process.WaitForExitAsync(cancellationToken);
            if (await Task.WhenAny(waitTask, Task.Delay(timeout, cancellationToken)) != waitTask)
            {
                try { _process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                await _process.WaitForExitAsync(CancellationToken.None);
            }
        }

        // QMP can make QEMU exit before StopAsync is called. Even in that
        // case, wait for both redirected streams before disposing Process so
        // no reader task or native pipe remains attached to the runtime.
        await Task.WhenAll(_standardOutputTask, _standardErrorTask);
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync(TimeSpan.FromSeconds(5));
        _process.Dispose();
    }
}

public sealed class ProcessRunnerService
{
    private readonly LogService _logs;

    public ProcessRunnerService(LogService logs)
    {
        _logs = logs;
    }

    public async Task<ProcessResult> RunAsync(
        string executable,
        IEnumerable<string> arguments,
        string workingDirectory,
        string category,
        TimeSpan timeout,
        CancellationToken cancellationToken = default,
        bool logOutput = true,
        IReadOnlyDictionary<string, string?>? environment = null,
        bool isolateEnvironment = true)
    {
        var started = Stopwatch.StartNew();
        using var process = CreateProcess(executable, arguments, workingDirectory, environment, isolateEnvironment);
        var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
        var waitTask = process.WaitForExitAsync(cancellationToken);
        var timedOut = false;
        try
        {
            if (await Task.WhenAny(waitTask, Task.Delay(timeout, cancellationToken)) != waitTask)
            {
                timedOut = true;
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                await process.WaitForExitAsync(CancellationToken.None);
            }
            else
            {
                await waitTask;
            }
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw;
        }

        var standardOutput = await outputTask;
        var standardError = await errorTask;
        started.Stop();
        LogOutput(category, logOutput ? standardOutput : string.Empty, standardError);
        return new ProcessResult(process.ExitCode, standardOutput, standardError, timedOut, started.Elapsed);
    }

    public ManagedProcess StartLongRunning(
        string executable,
        IEnumerable<string> arguments,
        string workingDirectory,
        string category,
        IReadOnlyDictionary<string, string?>? environment = null,
        bool isolateEnvironment = true,
        bool showWindow = false)
    {
        var process = CreateProcess(executable, arguments, workingDirectory, environment, isolateEnvironment, showWindow);
        var outputTask = ConsumeAsync(process.StandardOutput, category, false);
        var errorTask = ConsumeAsync(process.StandardError, category, true);
        _logs.Info("launcher", $"Processo iniciado: {executable} (PID {process.Id})");
        return new ManagedProcess(process, outputTask, errorTask);
    }

    public async Task<ProcessResult> RunElevatedAsync(
        string executable,
        IEnumerable<string> arguments,
        string workingDirectory,
        string category,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        var started = Stopwatch.StartNew();
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = workingDirectory,
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden
        };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        try
        {
            if (!process.Start()) throw new InvalidOperationException($"Não foi possível iniciar {executable} elevado.");
        }
        catch (Exception exception)
        {
            process.Dispose();
            _logs.Error("process", $"Falha ao iniciar {executable} elevado", exception);
            throw;
        }

        var waitTask = process.WaitForExitAsync(cancellationToken);
        var timedOut = false;
        try
        {
            if (await Task.WhenAny(waitTask, Task.Delay(timeout, cancellationToken)) != waitTask)
            {
                timedOut = true;
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                await process.WaitForExitAsync(CancellationToken.None);
            }
            else await waitTask;
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw;
        }

        started.Stop();
        _logs.Info(category, $"Processo elevado concluído: {executable} (exit code {process.ExitCode})");
        return new ProcessResult(process.ExitCode, string.Empty, string.Empty, timedOut, started.Elapsed);
    }

    private Process CreateProcess(
        string executable,
        IEnumerable<string> arguments,
        string workingDirectory,
        IReadOnlyDictionary<string, string?>? environment,
        bool isolateEnvironment,
        bool showWindow = false)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            // `showWindow` controls only the intended graphical window (for
            // example QEMU/GTK). It must never opt the child into a console
            // window; stdout/stderr are redirected to the structured log.
            CreateNoWindow = true,
            WindowStyle = showWindow ? ProcessWindowStyle.Normal : ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        if (isolateEnvironment) ApplyIsolatedEnvironment(startInfo, executable);
        if (environment is not null)
        {
            foreach (var (name, value) in environment)
            {
                if (string.IsNullOrEmpty(value)) startInfo.Environment.Remove(name);
                else startInfo.Environment[name] = value;
            }
        }
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        try
        {
            if (!process.Start()) throw new InvalidOperationException($"Não foi possível iniciar {executable}.");
            return process;
        }
        catch (Exception exception)
        {
            process.Dispose();
            _logs.Error("process", $"Falha ao iniciar {executable}", exception);
            throw;
        }
    }

    private static void ApplyIsolatedEnvironment(ProcessStartInfo startInfo, string executable)
    {
        // These variables are common sources of accidental coupling to an
        // Android Studio, Java, Gradle, QEMU, or ADB installation on the host.
        foreach (var name in new[]
        {
            "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME", "ANDROID_SDK_HOME",
            "ANDROID_USER_HOME", "ANDROID_EMULATOR_HOME", "ANDROID_ADB_SERVER_PORT",
            "ADB_SERVER_SOCKET", "ADB_VENDOR_KEYS", "JAVA_HOME", "JDK_HOME", "GRADLE_HOME",
            "QEMU_AUDIO_DRV", "QEMU_AUDIO_DLL", "QEMU_LOG", "QEMU_LOG_FILENAME"
        }) startInfo.Environment.Remove(name);

        var executableDirectory = Path.GetDirectoryName(Path.GetFullPath(executable));
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        var system32 = string.IsNullOrWhiteSpace(systemRoot) ? null : Path.Combine(systemRoot, "System32");
        var system = string.IsNullOrWhiteSpace(systemRoot) ? null : Path.Combine(systemRoot, "System");
        startInfo.Environment["PATH"] = string.Join(
            Path.PathSeparator,
            new[] { executableDirectory, system32, system }.Where(path => !string.IsNullOrWhiteSpace(path)));
    }

    private async Task ConsumeAsync(StreamReader reader, string category, bool isError)
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            if (isError) _logs.Error(category, line);
            else _logs.Info(category, line);
        }
    }

    private void LogOutput(string category, string standardOutput, string standardError)
    {
        foreach (var line in standardOutput.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries)) _logs.Info(category, line);
        foreach (var line in standardError.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries)) _logs.Error(category, line);
    }
}
