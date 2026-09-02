using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using NeoNews.Runtime.Launcher.Models;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class KioskService
{
    private const int GwlStyle = -16;
    private const long WsCaption = 0x00C00000L;
    private const long WsThickFrame = 0x00040000L;
    private const long WsMinimizeBox = 0x00020000L;
    private const long WsMaximizeBox = 0x00010000L;
    private const uint SwShow = 5;
    private const uint SwRestore = 9;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpShowWindow = 0x0040;
    private static readonly IntPtr HwndTopmost = new(-1);
    private static readonly IntPtr HwndNoTopmost = new(-2);

    private readonly RuntimeContext _context;
    private readonly AdbService _adb;
    private readonly IAndroidRuntimeBackend _backend;
    private IntPtr _windowHandle;
    private IntPtr _originalStyle;
    private RECT _originalRect;
    private bool _windowCaptured;
    private GuestState? _originalGuestState;

    public KioskService(RuntimeContext context, AdbService adb, IAndroidRuntimeBackend backend)
    {
        _context = context;
        _adb = adb;
        _backend = backend;
    }

    public bool IsActive { get; private set; }

    public async Task EnterAsync(IProgress<RuntimeProgress>? progress, CancellationToken cancellationToken)
    {
        var kiosk = _context.Config.Android.Kiosk;
        if (_originalGuestState is null) _originalGuestState = await CaptureGuestStateAsync(cancellationToken);
        progress?.Report(new RuntimeProgress("Ativando kiosk", "Aplicando fullscreen no Android...", 88));
        await _adb.PutSettingAsync("global", "policy_control", kiosk.ImmersivePolicy, cancellationToken);
        await _adb.PutSettingAsync("system", "screen_off_timeout", kiosk.ScreenOffTimeoutMs.ToString(), cancellationToken);
        await _adb.PutSettingAsync("global", "stay_on_while_plugged_in", kiosk.StayAwakePluggedIn.ToString(), cancellationToken);
        await _adb.PutSettingAsync("secure", "screensaver_enabled", "0", cancellationToken);
        await _adb.PutSettingAsync("system", "accelerometer_rotation", "0", cancellationToken);
        await _adb.PutSettingAsync("system", "user_rotation", ResolveRotation(kiosk.Orientation).ToString(), cancellationToken);
        await _adb.SetDisplayAsync(kiosk.DisplaySize, kiosk.DisplayDensity, cancellationToken);

        CaptureAndMaximizeEmulatorWindow();
        IsActive = true;
        progress?.Report(new RuntimeProgress("Kiosk ativo", "Android em modo imersivo.", 100));
    }

    public async Task ExitAsync(CancellationToken cancellationToken)
    {
        var original = _originalGuestState;
        if (original is null)
        {
            await _adb.DeleteSettingAsync("global", "policy_control", cancellationToken);
            await ResetDisplayAsync(cancellationToken);
        }
        else
        {
            await RestoreSettingAsync("global", "policy_control", original.PolicyControl, cancellationToken);
            await RestoreSettingAsync("system", "screen_off_timeout", original.ScreenOffTimeout, cancellationToken);
            await RestoreSettingAsync("global", "stay_on_while_plugged_in", original.StayAwakePluggedIn, cancellationToken);
            await RestoreSettingAsync("secure", "screensaver_enabled", original.ScreensaverEnabled, cancellationToken);
            await RestoreSettingAsync("system", "accelerometer_rotation", original.AccelerometerRotation, cancellationToken);
            await RestoreSettingAsync("system", "user_rotation", original.UserRotation, cancellationToken);
            await RestoreDisplayAsync(original.DisplaySize, original.DisplayDensity, cancellationToken);
        }
        RestoreEmulatorWindow();
        IsActive = false;
        _originalGuestState = null;
    }

    private async Task<GuestState> CaptureGuestStateAsync(CancellationToken cancellationToken)
    {
        var size = await _adb.GetDisplaySizeAsync(cancellationToken);
        var density = await _adb.GetDisplayDensityAsync(cancellationToken);
        return new GuestState(
            await _adb.GetSettingAsync("global", "policy_control", cancellationToken),
            await _adb.GetSettingAsync("system", "screen_off_timeout", cancellationToken),
            await _adb.GetSettingAsync("global", "stay_on_while_plugged_in", cancellationToken),
            await _adb.GetSettingAsync("secure", "screensaver_enabled", cancellationToken),
            await _adb.GetSettingAsync("system", "accelerometer_rotation", cancellationToken),
            await _adb.GetSettingAsync("system", "user_rotation", cancellationToken),
            ExtractOverride(size, "Override size"),
            ExtractOverride(density, "Override density"));
    }

    private async Task RestoreSettingAsync(string scope, string name, string value, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Equals("null", StringComparison.OrdinalIgnoreCase))
            await _adb.DeleteSettingAsync(scope, name, cancellationToken);
        else
            await _adb.PutSettingAsync(scope, name, value, cancellationToken);
    }

    private async Task RestoreDisplayAsync(string? size, string? density, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(size))
            await _adb.ExecuteAsync(["shell", "wm", "size", "reset"], TimeSpan.FromSeconds(20), cancellationToken);
        else
            await _adb.ExecuteAsync(["shell", "wm", "size", size], TimeSpan.FromSeconds(20), cancellationToken);

        if (string.IsNullOrWhiteSpace(density))
            await _adb.ExecuteAsync(["shell", "wm", "density", "reset"], TimeSpan.FromSeconds(20), cancellationToken);
        else
            await _adb.ExecuteAsync(["shell", "wm", "density", density], TimeSpan.FromSeconds(20), cancellationToken);
    }

    private Task ResetDisplayAsync(CancellationToken cancellationToken) =>
        RestoreDisplayAsync(null, null, cancellationToken);

    private static string? ExtractOverride(string text, string label)
    {
        var match = Regex.Match(text, $"(?m)^{Regex.Escape(label)}:\\s*(\\S+)");
        return match.Success ? match.Groups[1].Value : null;
    }

    private static int ResolveRotation(string orientation) => orientation.Trim().ToLowerInvariant() switch
    {
        "portrait" => 0,
        "reverse-portrait" => 2,
        "reverse-landscape" => 3,
        _ => 1
    };

    private sealed record GuestState(
        string PolicyControl,
        string ScreenOffTimeout,
        string StayAwakePluggedIn,
        string ScreensaverEnabled,
        string AccelerometerRotation,
        string UserRotation,
        string? DisplaySize,
        string? DisplayDensity);

    private void CaptureAndMaximizeEmulatorWindow()
    {
        var handle = _backend.WindowHandle;
        if (handle == IntPtr.Zero) return;

        _windowHandle = handle;
        _originalStyle = GetWindowLongPtr(handle, GwlStyle);
        GetWindowRect(handle, out _originalRect);
        _windowCaptured = true;

        var screens = Screen.AllScreens;
        var index = Math.Clamp(_context.Config.Android.Kiosk.MonitorIndex, 0, Math.Max(0, screens.Length - 1));
        var bounds = screens[index].Bounds;
        var style = _originalStyle.ToInt64() & ~(WsCaption | WsThickFrame | WsMinimizeBox | WsMaximizeBox);
        SetWindowLongPtr(handle, GwlStyle, new IntPtr(style));
        SetWindowPos(handle, HwndTopmost, bounds.Left, bounds.Top, bounds.Width, bounds.Height, SwpShowWindow);
        ShowWindow(handle, SwShow);
        SetForegroundWindow(handle);
    }

    private void RestoreEmulatorWindow()
    {
        if (!_windowCaptured || _windowHandle == IntPtr.Zero) return;
        SetWindowLongPtr(_windowHandle, GwlStyle, _originalStyle);
        SetWindowPos(_windowHandle, HwndNoTopmost, _originalRect.Left, _originalRect.Top, _originalRect.Right - _originalRect.Left, _originalRect.Bottom - _originalRect.Top, SwpNoActivate | SwpShowWindow);
        ShowWindow(_windowHandle, SwRestore);
        _windowCaptured = false;
        _windowHandle = IntPtr.Zero;
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, uint command);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
