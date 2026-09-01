using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Forms = System.Windows.Forms;

namespace NeoNews.Runtime.Launcher.Services;

public sealed class TrayService : IDisposable
{
    private readonly Forms.NotifyIcon _notifyIcon;
    private Icon? _icon;

    public TrayService(
        Action open,
        Func<Task> start,
        Func<Task> stop,
        Func<Task> restart,
        Func<Task> kiosk,
        Func<Task> exitKiosk,
        Func<Task> diagnostics,
        Func<Task> exit)
    {
        _notifyIcon = new Forms.NotifyIcon
        {
            Text = "NeoNews Runtime",
            Icon = CreateIcon(),
            Visible = true,
            ContextMenuStrip = BuildMenu(open, start, stop, restart, kiosk, exitKiosk, diagnostics, exit)
        };
        _notifyIcon.DoubleClick += (_, _) => open();
    }

    private static Forms.ContextMenuStrip BuildMenu(
        Action open, Func<Task> start, Func<Task> stop, Func<Task> restart,
        Func<Task> kiosk, Func<Task> exitKiosk, Func<Task> diagnostics, Func<Task> exit)
    {
        var menu = new Forms.ContextMenuStrip();
        Add(menu, "Abrir painel", open);
        menu.Items.Add(new Forms.ToolStripSeparator());
        AddAsync(menu, "Iniciar Android", start);
        AddAsync(menu, "Parar Android", stop);
        AddAsync(menu, "Reiniciar Android", restart);
        menu.Items.Add(new Forms.ToolStripSeparator());
        AddAsync(menu, "Ativar kiosk", kiosk);
        AddAsync(menu, "Sair do kiosk", exitKiosk);
        AddAsync(menu, "Diagnóstico", diagnostics);
        menu.Items.Add(new Forms.ToolStripSeparator());
        AddAsync(menu, "Encerrar runtime", exit);
        return menu;
    }

    private static void Add(Forms.ContextMenuStrip menu, string text, Action action)
    {
        var item = new Forms.ToolStripMenuItem(text);
        item.Click += (_, _) => action();
        menu.Items.Add(item);
    }

    private static void AddAsync(Forms.ContextMenuStrip menu, string text, Func<Task> action)
    {
        var item = new Forms.ToolStripMenuItem(text);
        item.Click += async (_, _) => await action();
        menu.Items.Add(item);
    }

    private Icon CreateIcon()
    {
        using var bitmap = new Bitmap(32, 32);
        using (var graphics = Graphics.FromImage(bitmap))
        using (var brush = new SolidBrush(Color.FromArgb(15, 23, 32)))
        using (var accent = new SolidBrush(Color.FromArgb(34, 211, 238)))
        using (var font = new Font("Segoe UI", 19, FontStyle.Bold, GraphicsUnit.Pixel))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.FillRectangle(brush, 0, 0, 32, 32);
            graphics.DrawString("N", font, accent, new PointF(5, 2));
        }

        var handle = bitmap.GetHicon();
        try
        {
            _icon = (Icon)Icon.FromHandle(handle).Clone();
            return _icon;
        }
        finally { DestroyIcon(handle); }
    }

    public void Dispose()
    {
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _icon?.Dispose();
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);
}
