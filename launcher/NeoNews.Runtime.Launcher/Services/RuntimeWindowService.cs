using System.Runtime.InteropServices;
using System.Text;

namespace NeoNews.Runtime.Launcher.Services;

internal static class RuntimeWindowService
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public static IntPtr FindForProcess(int processId, string title)
    {
        var result = IntPtr.Zero;
        EnumWindows((hWnd, _) =>
        {
            if (!IsWindowVisible(hWnd)) return true;
            GetWindowThreadProcessId(hWnd, out var ownerProcessId);
            if (ownerProcessId != (uint)processId) return true;

            var length = GetWindowTextLength(hWnd);
            var text = new StringBuilder(Math.Max(1, length + 1));
            _ = GetWindowText(hWnd, text, text.Capacity);
            if (length == 0 || text.ToString().Contains(title, StringComparison.OrdinalIgnoreCase))
            {
                result = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr hWnd);
}
