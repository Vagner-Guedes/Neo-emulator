using Forms = System.Windows.Forms;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class HotkeyService : IDisposable
{
    private const int WhKeyboardLl = 13;
    private const int WmHotKey = 0x0312;
    private const int WmKeyDown = 0x0100;
    private const int WmSysKeyDown = 0x0104;
    private const uint LlkhfUp = 0x0080;
    private readonly int _id;
    private IntPtr _windowHandle;
    private uint _key;
    private LowLevelKeyboardProc? _keyboardProc;
    private IntPtr _keyboardHook;
    private bool _registered;

    public HotkeyService(int id) => _id = id;

    public bool Register(IntPtr windowHandle, string specification)
    {
        Unregister();
        if (!TryParse(specification, out var modifiers, out var key)) return false;
        _windowHandle = windowHandle;
        _key = key;
        _registered = RegisterHotKey(_windowHandle, _id, modifiers, key);
        if (!_registered && modifiers == 0)
        {
            _keyboardProc = KeyboardHookCallback;
            _keyboardHook = SetWindowsHookEx(WhKeyboardLl, _keyboardProc, GetModuleHandle(null), 0);
            _registered = _keyboardHook != IntPtr.Zero;
        }
        return _registered;
    }

    public bool IsHotKeyMessage(int message, IntPtr wParam) =>
        _registered && (message == WmHotKey || message == CustomKeyboardMessage) && wParam.ToInt32() == _id;

    public void Unregister()
    {
        if (_registered) UnregisterHotKey(_windowHandle, _id);
        if (_keyboardHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_keyboardHook);
            _keyboardHook = IntPtr.Zero;
        }
        _keyboardProc = null;
        _registered = false;
        _windowHandle = IntPtr.Zero;
        _key = 0;
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
        return key != 0;
    }

    public void Dispose() => Unregister();

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int CustomKeyboardMessage = 0x8000 + 0x4E52;

    private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct KeyboardData
    {
        public uint VirtualKey;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    private IntPtr KeyboardHookCallback(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && (wParam.ToInt32() == WmKeyDown || wParam.ToInt32() == WmSysKeyDown))
        {
            var data = System.Runtime.InteropServices.Marshal.PtrToStructure<KeyboardData>(lParam);
            if ((data.Flags & LlkhfUp) == 0 && data.VirtualKey == _key)
                PostMessage(_windowHandle, CustomKeyboardMessage, new IntPtr(_id), IntPtr.Zero);
        }
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int hookType, LowLevelKeyboardProc callback, IntPtr moduleHandle, uint threadId);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? moduleName);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr hWnd, int message, IntPtr wParam, IntPtr lParam);
}
