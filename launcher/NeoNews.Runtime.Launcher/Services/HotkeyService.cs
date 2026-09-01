using Forms = System.Windows.Forms;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class HotkeyService : IDisposable
{
    private readonly int _id;
    private IntPtr _windowHandle;
    private bool _registered;

    public HotkeyService(int id) => _id = id;

    public bool Register(IntPtr windowHandle, string specification)
    {
        Unregister();
        if (!TryParse(specification, out var modifiers, out var key)) return false;
        _windowHandle = windowHandle;
        _registered = RegisterHotKey(_windowHandle, _id, modifiers, key);
        return _registered;
    }

    public bool IsHotKeyMessage(int message, IntPtr wParam) =>
        _registered && message == 0x0312 && wParam.ToInt32() == _id;

    public void Unregister()
    {
        if (_registered) UnregisterHotKey(_windowHandle, _id);
        _registered = false;
        _windowHandle = IntPtr.Zero;
    }

    public static bool TryParse(string specification, out uint modifiers, out uint key)
    {
        modifiers = 0;
        key = 0;
        if (string.IsNullOrWhiteSpace(specification)) return false;
        var tokens = specification.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length < 2) return false;

        foreach (var token in tokens[..^1])
        {
            switch (token.ToLowerInvariant())
            {
                case "ctrl":
                case "control": modifiers |= 0x0002; break;
                case "alt": modifiers |= 0x0001; break;
                case "shift": modifiers |= 0x0004; break;
                case "win":
                case "windows": modifiers |= 0x0008; break;
                default: return false;
            }
        }

        if (!Enum.TryParse<Forms.Keys>(tokens[^1], true, out var parsedKey)) return false;
        key = (uint)parsedKey & 0xFFFF;
        return modifiers != 0 && key != 0;
    }

    public void Dispose() => Unregister();

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
