using System.Text.RegularExpressions;

namespace NeoNews.Runtime.Launcher.Services;

internal static class AndroidRuntimeParsing
{
    public static string? ReadVersionName(string dump)
    {
        var match = Regex.Match(dump, @"versionName=([^\s]+)", RegexOptions.IgnoreCase);
        return match.Success ? match.Groups[1].Value : null;
    }

    public static string? ReadPrimaryCpuAbi(string dump)
    {
        var match = Regex.Match(dump, @"primaryCpuAbi=([^\s]+)", RegexOptions.IgnoreCase);
        return match.Success ? match.Groups[1].Value : null;
    }

    public static bool IsX86Abi(string? abi) =>
        abi is not null && (abi.Equals("x86", StringComparison.OrdinalIgnoreCase) || abi.Equals("x86_64", StringComparison.OrdinalIgnoreCase));

    public static bool IsActiveWebViewProvider(string dump, string provider)
    {
        if (string.IsNullOrWhiteSpace(dump) || string.IsNullOrWhiteSpace(provider)) return false;
        var currentLine = dump.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries)
            .FirstOrDefault(line => line.Contains("Current WebView package", StringComparison.OrdinalIgnoreCase));
        return currentLine?.Contains(provider, StringComparison.OrdinalIgnoreCase) == true;
    }
}
