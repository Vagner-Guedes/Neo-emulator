namespace NeoNews.Runtime.Launcher.Models;

public enum RuntimeCommand
{
    Show,
    Start,
    Stop,
    Restart,
    Kiosk,
    ExitKiosk,
    Autostart,
    Diagnostics,
    Install,
    Exit
}

public static class RuntimeCommandParser
{
    public static RuntimeCommand Parse(IEnumerable<string> args)
    {
        foreach (var argument in args)
        {
            switch (argument.Trim().ToLowerInvariant())
            {
                case "--autostart": return RuntimeCommand.Autostart;
                case "--start": return RuntimeCommand.Start;
                case "--stop": return RuntimeCommand.Stop;
                case "--restart": return RuntimeCommand.Restart;
                case "--kiosk": return RuntimeCommand.Kiosk;
                case "--exit-kiosk": return RuntimeCommand.ExitKiosk;
                case "--diagnostics": return RuntimeCommand.Diagnostics;
                case "--install": return RuntimeCommand.Install;
                case "--exit": return RuntimeCommand.Exit;
                case "--show": return RuntimeCommand.Show;
            }
        }
        return RuntimeCommand.Show;
    }

    public static string ToArgument(this RuntimeCommand command) => command switch
    {
        RuntimeCommand.Autostart => "--autostart",
        RuntimeCommand.Start => "--start",
        RuntimeCommand.Stop => "--stop",
        RuntimeCommand.Restart => "--restart",
        RuntimeCommand.Kiosk => "--kiosk",
        RuntimeCommand.ExitKiosk => "--exit-kiosk",
        RuntimeCommand.Diagnostics => "--diagnostics",
        RuntimeCommand.Install => "--install",
        RuntimeCommand.Exit => "--exit",
        _ => "--show"
    };
}
