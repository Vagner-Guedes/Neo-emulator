using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed record GuestConfigurationResult(
    bool Ready,
    bool NetworkConfigured,
    bool SuperuserConfigured,
    bool RebootPerformed,
    bool InitScriptChanged,
    string SuperuserStatus,
    string InitScriptSha256,
    string Detail);

/// <summary>
/// Applies only the project-owned guest settings that are required for the
/// NeoNews runtime. It deliberately does not install, remove, clear or alter
/// RHVoice, WebView, debloat policy or Native Bridge artifacts.
/// </summary>
public sealed class GuestConfigurationService
{
    private const string SettingsPackage = "com.android.settings";
    private readonly RuntimeContext _context;
    private readonly AdbService _adb;
    private readonly LogService _logs;

    public GuestConfigurationService(RuntimeContext context, AdbService adb, LogService logs)
    {
        _context = context;
        _adb = adb;
        _logs = logs;
    }

    public async Task<GuestConfigurationResult> EnsureAsync(
        IProgress<RuntimeProgress>? progress,
        bool requireNeoNewsSuperuser,
        CancellationToken cancellationToken = default)
    {
        var configuration = _context.Config.Android.GuestConfiguration;
        if (!configuration.Enabled)
        {
            return new GuestConfigurationResult(
                Ready: true,
                NetworkConfigured: true,
                SuperuserConfigured: true,
                RebootPerformed: false,
                InitScriptChanged: false,
                SuperuserStatus: "disabled-by-configuration",
                InitScriptSha256: string.Empty,
                Detail: "A configuração persistente do guest está desativada.");
        }

        ValidateConfiguration(configuration);
        await _adb.EnsureRootAsync(cancellationToken);

        progress?.Report(new RuntimeProgress(
            "Configurando Android",
            "Aplicando a rede Ethernet persistente do NeoNews...",
            72));
        var initResult = await EnsureInitScriptAsync(configuration, cancellationToken);
        var rebootPerformed = false;
        if (initResult.Changed)
        {
            await _adb.RebootGuestAsync(cancellationToken);
            rebootPerformed = true;
            await _adb.WaitForBootAsync(
                progress,
                TimeSpan.FromSeconds(Math.Max(15, _context.Config.Timeouts.BootSeconds)),
                cancellationToken);
        }

        var network = await ConfigureAndValidateLiveNetworkAsync(configuration.Network, cancellationToken);
        if (!network.Ready)
        {
            throw new RuntimeOperationException(
                "A rede persistente do guest não foi validada.",
                network.Detail);
        }

        var superuser = await EnsureSuperuserPolicyAsync(
            configuration.Superuser,
            requireNeoNewsSuperuser,
            cancellationToken);
        if (requireNeoNewsSuperuser && !superuser.Configured)
        {
            throw new RuntimeOperationException(
                "A política persistente do Superuser não foi validada.",
                superuser.Detail);
        }

        var ready = network.Ready && (!requireNeoNewsSuperuser || superuser.Configured);
        var detail = $"network={network.Detail}; superuser={superuser.Status}; initChanged={initResult.Changed}; reboot={rebootPerformed}";
        _logs.Info("provisioning", $"GUEST_CONFIGURATION_OK {detail}");
        return new GuestConfigurationResult(
            Ready: ready,
            NetworkConfigured: network.Ready,
            SuperuserConfigured: superuser.Configured,
            RebootPerformed: rebootPerformed,
            InitScriptChanged: initResult.Changed,
            SuperuserStatus: superuser.Status,
            InitScriptSha256: initResult.Sha256,
            Detail: detail);
    }

    private async Task<(bool Changed, string Sha256)> EnsureInitScriptAsync(
        GuestConfigurationConfig configuration,
        CancellationToken cancellationToken)
    {
        var path = configuration.InitScriptPath;
        var original = await _adb.ShellAsync(["cat", path], TimeSpan.FromSeconds(30), cancellationToken);
        if (string.IsNullOrWhiteSpace(original))
        {
            throw new RuntimeOperationException(
                "O init.sh do Android-x86 não pôde ser lido.",
                $"Arquivo esperado: {path}. Nenhuma configuração de voz, WebView ou pacote será alterada.");
        }

        var expected = ApplyNetworkPatch(original, configuration);
        var changed = !string.Equals(NormalizeScript(original), NormalizeScript(expected), StringComparison.Ordinal);
        if (changed)
        {
            var temporaryDirectory = Directory.CreateTempSubdirectory("neonews-guest-");
            var temporaryFile = Path.Combine(temporaryDirectory.FullName, "init.sh");
            try
            {
                await File.WriteAllTextAsync(temporaryFile, NormalizeScript(expected), new UTF8Encoding(false), cancellationToken);
                await RequireShellSuccessAsync(
                    ["mount", "-o", "remount,rw", "/system"],
                    "remontar /system como gravável",
                    cancellationToken);
                try
                {
                    var push = await _adb.PushFileAsync(temporaryFile, path, TimeSpan.FromSeconds(30), cancellationToken);
                    if (!push.Succeeded)
                    {
                        throw new RuntimeOperationException(
                            "O init.sh não pôde ser persistido.",
                            $"adb push falhou: exit={push.ExitCode}; stdout={push.StandardOutput}; stderr={push.StandardError}");
                    }
                    await RequireShellSuccessAsync(["chmod", "755", path], "preservar permissão executável do init.sh", cancellationToken);
                    var written = await _adb.ShellAsync(["cat", path], TimeSpan.FromSeconds(30), cancellationToken);
                    if (!HasExpectedNetworkPatch(written, configuration))
                    {
                        throw new RuntimeOperationException(
                            "O init.sh persistido não contém a configuração esperada.",
                            $"Arquivo verificado: {path}; marcador ausente ou comandos divergentes.");
                    }
                }
                catch
                {
                    // Restore the exact content read before attempting the
                    // project patch. This protects the guest if a partial
                    // push or post-write verification fails.
                    try
                    {
                        await File.WriteAllTextAsync(temporaryFile, NormalizeScript(original), new UTF8Encoding(false), CancellationToken.None);
                        _ = await _adb.PushFileAsync(temporaryFile, path, TimeSpan.FromSeconds(30), CancellationToken.None);
                        _ = await _adb.ShellResultAsync(["chmod", "755", path], TimeSpan.FromSeconds(15), CancellationToken.None);
                    }
                    catch (Exception rollbackException)
                    {
                        _logs.Error("provisioning", "Falha ao restaurar init.sh após erro de configuração.", rollbackException);
                    }
                    throw;
                }
            }
            finally
            {
                try { _ = await _adb.ShellResultAsync(["mount", "-o", "remount,ro", "/system"], TimeSpan.FromSeconds(15), CancellationToken.None); }
                catch (Exception exception) { _logs.Warning("provisioning", $"Não foi possível remontar /system como somente leitura: {exception.Message}"); }
                try { Directory.Delete(temporaryDirectory.FullName, recursive: true); } catch { }
            }

            original = await _adb.ShellAsync(["cat", path], TimeSpan.FromSeconds(30), cancellationToken);
        }

        if (!HasExpectedNetworkPatch(original, configuration))
        {
            throw new RuntimeOperationException(
                "A configuração persistente da rede não foi confirmada no init.sh.",
                $"Arquivo esperado: {path}; marcador={BuildMarker(configuration, "NETWORK")}; verifique a imagem Android-x86 aprovada.");
        }

        return (changed, ComputeSha256(NormalizeScript(original)));
    }

    private async Task<(bool Ready, string Detail)> ConfigureAndValidateLiveNetworkAsync(
        GuestNetworkConfig network,
        CancellationToken cancellationToken)
    {
        if (network.ForceEthernet && network.VirtWifi)
        {
            throw new RuntimeOperationException(
                "A configuração de rede é contraditória.",
                "ForceEthernet=true exige VirtWifi=false para o NeoNews.");
        }

        await RequireShellSuccessAsync(
            ["ifconfig", network.InterfaceName, network.GuestAddress, "netmask", network.Netmask, "up"],
            $"configurar {network.InterfaceName}",
            cancellationToken);
        await RequireShellSuccessAsync(
            ["ip", "route", "replace", "default", "via", network.Gateway, "dev", network.InterfaceName],
            "configurar rota padrão do guest",
            cancellationToken);
        await RequireShellSuccessAsync(["setprop", "net.dns1", network.Dns], "configurar DNS primário do guest", cancellationToken);
        await RequireShellSuccessAsync(["setprop", "net.dns2", network.Dns], "configurar DNS secundário do guest", cancellationToken);

        var address = await _adb.ShellAsync(["ip", "addr", "show", "dev", network.InterfaceName], TimeSpan.FromSeconds(20), cancellationToken);
        var route = await _adb.ShellAsync(["ip", "route"], TimeSpan.FromSeconds(20), cancellationToken);
        var dns = await _adb.GetPropertyAsync("net.dns1", cancellationToken);
        var addressReady = Regex.IsMatch(address, $@"\binet\s+{Regex.Escape(network.GuestAddress)}/\d+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        var routeReady = route.Contains($"default via {network.Gateway}", StringComparison.OrdinalIgnoreCase) && route.Contains($"dev {network.InterfaceName}", StringComparison.OrdinalIgnoreCase);
        var dnsReady = dns.Equals(network.Dns, StringComparison.OrdinalIgnoreCase);
        var ready = addressReady && routeReady && dnsReady;
        return (ready, $"interface={network.InterfaceName}; address={network.GuestAddress}; route={network.Gateway}; dns={dns}; addressReady={addressReady}; routeReady={routeReady}; dnsReady={dnsReady}");
    }

    private async Task<(bool Configured, string Status, string Detail)> EnsureSuperuserPolicyAsync(
        GuestSuperuserConfig superuser,
        bool required,
        CancellationToken cancellationToken)
    {
        if (!superuser.Enabled)
            return (true, "disabled-by-configuration", "A política do Superuser está desativada.");

        var installed = await _adb.IsPackageInstalledAsync(superuser.PackageName, cancellationToken);
        if (!installed)
        {
            var status = "pending-neonews-package";
            if (required) return (false, status, $"Pacote esperado não instalado: {superuser.PackageName}.");
            return (true, status, $"Pacote ainda não instalado; a política será aplicada antes do primeiro start: {superuser.PackageName}.");
        }

        var uid = await ResolvePackageUidAsync(superuser.PackageName, cancellationToken);
        await _adb.ForceStopAsync(SettingsPackage, cancellationToken);
        var sql = $"BEGIN; INSERT OR REPLACE INTO uid_policy (logging, desired_name, username, policy, until, command, uid, desired_uid, package_name, name, notification) VALUES ({(superuser.Logging ? 1 : 0)}, {SqlLiteral(superuser.ApplicationLabel)}, {SqlLiteral(string.Empty)}, {SqlLiteral(superuser.Policy)}, {superuser.Until}, {SqlLiteral(string.Empty)}, {uid}, 0, {SqlLiteral(superuser.PackageName)}, {SqlLiteral(superuser.ApplicationLabel)}, {(superuser.Notification ? 1 : 0)}); COMMIT; PRAGMA wal_checkpoint(FULL);";
        var command = BuildSqliteCommand(superuser.DatabasePath, sql);
        var result = await _adb.ShellCommandResultAsync(command, TimeSpan.FromSeconds(30), cancellationToken, logOutput: false);
        if (!result.Succeeded)
        {
            return (false, "database-write-failed", $"sqlite3 falhou: exit={result.ExitCode}; stderr={result.StandardError}; stdout={result.StandardOutput}");
        }

        var query = $"SELECT policy,until,notification,package_name FROM uid_policy WHERE uid={uid} AND desired_uid=0 AND length(command)=0;";
        var verification = await _adb.ShellCommandAsync(BuildSqliteCommand(superuser.DatabasePath, query), TimeSpan.FromSeconds(20), cancellationToken);
        var expected = $"{superuser.Policy}|{superuser.Until}|{(superuser.Notification ? 1 : 0)}|{superuser.PackageName}";
        if (!verification.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Any(line => line.Equals(expected, StringComparison.Ordinal)))
        {
            return (false, "database-verification-failed", $"A linha persistida diverge do esperado: recebido='{verification}'; esperado='{expected}'.");
        }

        return (true, "allow-forever-notification-off", $"uid={uid}; policy={superuser.Policy}; until={superuser.Until}; notification={superuser.Notification}; package={superuser.PackageName}");
    }

    private async Task<int> ResolvePackageUidAsync(string packageName, CancellationToken cancellationToken)
    {
        var packages = await _adb.ShellAsync(["pm", "list", "packages", "-U"], TimeSpan.FromSeconds(30), cancellationToken);
        var packageMatch = Regex.Match(packages, $@"(?m)^package:{Regex.Escape(packageName)}\s+uid:(?<uid>\d+)\s*$");
        if (!packageMatch.Success)
        {
            var dump = await _adb.GetPackageDumpAsync(packageName, cancellationToken);
            packageMatch = Regex.Match(dump, @"(?m)\buserId=(?<uid>\d+)");
        }
        if (!packageMatch.Success || !int.TryParse(packageMatch.Groups["uid"].Value, out var uid) || uid <= 0)
            throw new RuntimeOperationException("Não foi possível descobrir o UID do NeoNews.", $"Pacote={packageName}; pm list packages -U não retornou UID.");
        return uid;
    }

    private async Task RequireShellSuccessAsync(
        IEnumerable<string> arguments,
        string operation,
        CancellationToken cancellationToken)
    {
        var result = await _adb.ShellResultAsync(arguments, TimeSpan.FromSeconds(20), cancellationToken);
        if (!result.Succeeded)
            throw new RuntimeOperationException(
                "Não foi possível aplicar a configuração persistente do guest.",
                $"Operação={operation}; exit={result.ExitCode}; stdout={result.StandardOutput}; stderr={result.StandardError}");
    }

    private static string ApplyNetworkPatch(string original, GuestConfigurationConfig configuration)
    {
        var normalized = NormalizeScript(original);
        var functionStart = normalized.IndexOf("function init_misc()", StringComparison.Ordinal);
        var nextFunction = normalized.IndexOf("function init_hal_audio()", functionStart, StringComparison.Ordinal);
        if (functionStart < 0 || nextFunction <= functionStart)
        {
            throw new RuntimeOperationException(
                "O init.sh não possui a estrutura esperada do Android-x86.",
                "A configuração só aceita a função init_misc() da imagem Android-x86 aprovada; nenhum arquivo alternativo será baixado.");
        }

        var prefix = normalized[..functionStart];
        var function = normalized[functionStart..nextFunction];
        var suffix = normalized[nextFunction..];
        function = RemoveMarkerBlock(function, BuildMarker(configuration, "FORCE"), BuildEndMarker(configuration, "FORCE"));
        function = RemoveMarkerBlock(function, BuildMarker(configuration, "NETWORK"), BuildEndMarker(configuration, "NETWORK"));

        var openBrace = function.IndexOf('{');
        var closeBrace = function.LastIndexOf('}');
        if (openBrace < 0 || closeBrace <= openBrace)
            throw new RuntimeOperationException("O init.sh possui uma init_misc() inválida.", "Não foi possível localizar os limites seguros da função init_misc().");

        var forceBlock = $"\n    {BuildMarker(configuration, "FORCE")}\n    VIRT_WIFI={(configuration.Network.VirtWifi ? 1 : 0)}\n    {BuildEndMarker(configuration, "FORCE")}\n";
        function = function.Insert(openBrace + 1, forceBlock);
        closeBrace = function.LastIndexOf('}');
        var network = configuration.Network;
        var networkBlock = $"\n    {BuildMarker(configuration, "NETWORK")}\n    if [ -d /sys/class/net/{network.InterfaceName} ]; then\n        ifconfig {network.InterfaceName} {network.GuestAddress} netmask {network.Netmask} up\n        ip route replace default via {network.Gateway} dev {network.InterfaceName}\n        setprop net.dns1 {network.Dns}\n        setprop net.dns2 {network.Dns}\n    fi\n    {BuildEndMarker(configuration, "NETWORK")}\n";
        function = function.Insert(closeBrace, networkBlock);
        return prefix + function + suffix;
    }

    private static bool HasExpectedNetworkPatch(string script, GuestConfigurationConfig configuration)
    {
        var normalized = NormalizeScript(script);
        var network = configuration.Network;
        return normalized.Contains(BuildMarker(configuration, "FORCE"), StringComparison.Ordinal) &&
               normalized.Contains("VIRT_WIFI=0", StringComparison.Ordinal) &&
               normalized.Contains(BuildMarker(configuration, "NETWORK"), StringComparison.Ordinal) &&
               normalized.Contains($"ifconfig {network.InterfaceName} {network.GuestAddress} netmask {network.Netmask} up", StringComparison.Ordinal) &&
               normalized.Contains($"ip route replace default via {network.Gateway} dev {network.InterfaceName}", StringComparison.Ordinal) &&
               normalized.Contains($"setprop net.dns1 {network.Dns}", StringComparison.Ordinal);
    }

    private static string RemoveMarkerBlock(string content, string begin, string end)
    {
        var pattern = $@"(?ms)^[ \t]*{Regex.Escape(begin)}[ \t]*\n.*?^[ \t]*{Regex.Escape(end)}[ \t]*\n?";
        return Regex.Replace(content, pattern, string.Empty);
    }

    private static string BuildMarker(GuestConfigurationConfig configuration, string section) => $"# BEGIN {configuration.InitScriptMarker} {section}";
    private static string BuildEndMarker(GuestConfigurationConfig configuration, string section) => $"# END {configuration.InitScriptMarker} {section}";

    private static string NormalizeScript(string value) => value.Replace("\r\n", "\n").TrimEnd() + "\n";

    private static string ComputeSha256(string value) => Convert.ToHexString(SHA256.HashData(new UTF8Encoding(false).GetBytes(value)));

    private static string SqlLiteral(string value) => value.Length == 0
        ? "char()"
        : $"char({string.Join(',', value.Select(character => ((int)character).ToString(System.Globalization.CultureInfo.InvariantCulture)))})";

    private static string BuildSqliteCommand(string databasePath, string sql) =>
        $"sqlite3 {databasePath} '{sql.Replace("'", "'\\''", StringComparison.Ordinal)}'";

    private static void ValidateConfiguration(GuestConfigurationConfig configuration)
    {
        if (!string.Equals(configuration.InitScriptPath, "/system/etc/init.sh", StringComparison.Ordinal))
            throw new RuntimeOperationException("O caminho do init.sh não é autorizado.", $"Esperado=/system/etc/init.sh; recebido={configuration.InitScriptPath}.");
        if (!configuration.Network.ForceEthernet || configuration.Network.VirtWifi)
            throw new RuntimeOperationException("A política de rede do NeoNews é inválida.", "ForceEthernet=true e VirtWifi=false são obrigatórios.");
        RequireSafeToken(configuration.Network.InterfaceName, "interfaceName");
        RequireIpv4(configuration.Network.GuestAddress, "guestAddress");
        RequireIpv4(configuration.Network.Netmask, "netmask");
        RequireIpv4(configuration.Network.Gateway, "gateway");
        RequireIpv4(configuration.Network.Dns, "dns");
        if (!string.Equals(configuration.Superuser.PackageName, "com.in9midia.neonews.player", StringComparison.Ordinal))
            throw new RuntimeOperationException("A política do Superuser aponta para pacote incorreto.", $"Pacote autorizado=com.in9midia.neonews.player; recebido={configuration.Superuser.PackageName}.");
        if (!string.Equals(configuration.Superuser.Policy, "allow", StringComparison.OrdinalIgnoreCase) || configuration.Superuser.Until != 0 || configuration.Superuser.Notification)
            throw new RuntimeOperationException("A política do Superuser não corresponde à homologação.", "O NeoNews exige policy=allow, until=0 (permanente) e notification=false.");
        RequireSafeToken(configuration.Superuser.PackageName, "packageName");
        if (string.IsNullOrWhiteSpace(configuration.Superuser.ApplicationLabel))
            throw new RuntimeOperationException("O nome exibido do NeoNews no Superuser não foi configurado.", "ApplicationLabel não pode ser vazio.");
        if (!Regex.IsMatch(configuration.Superuser.ApplicationLabel, @"^[A-Za-z0-9 ._-]+$", RegexOptions.CultureInvariant))
            throw new RuntimeOperationException("O nome exibido do NeoNews no Superuser contém caracteres não autorizados.", $"ApplicationLabel={configuration.Superuser.ApplicationLabel}");
        if (!configuration.Superuser.DatabasePath.Equals("/data/user_de/0/com.android.settings/databases/su.sqlite", StringComparison.Ordinal))
            throw new RuntimeOperationException("O banco do Superuser não é autorizado.", "Apenas o banco nativo /data/user_de/0/com.android.settings/databases/su.sqlite pode ser usado.");
    }

    private static void RequireSafeToken(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value) || !Regex.IsMatch(value, @"^[A-Za-z0-9._:-]+$", RegexOptions.CultureInvariant))
            throw new RuntimeOperationException("A configuração do guest contém um token inválido.", $"{name}={value}");
    }

    private static void RequireIpv4(string value, string name)
    {
        if (!IPAddress.TryParse(value, out var address) || address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
            throw new RuntimeOperationException("A configuração de rede do guest contém IPv4 inválido.", $"{name}={value}");
    }
}
