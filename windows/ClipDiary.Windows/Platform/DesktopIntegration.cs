using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace ClipDiary.Windows.Platform;

public sealed record PreparedClipboardImage(System.Windows.Media.Imaging.BitmapSource Image, byte[]? Png);

public static class ClipboardWriter
{
    public static void CopyText(string text)
    {
        if (!CapturePolicy.ValidText(text)) throw new ArgumentException("Text is empty or exceeds1 MB.");
        var data = new DataObject(); data.SetText(text, TextDataFormat.UnicodeText); AddMarker(data); Set(data);
    }
    public static PreparedClipboardImage PrepareImage(byte[] encoded)
    {
        var image = ImageCodec.DecodeForCopy(encoded);
        byte[]? png;
        try { png = ImageCodec.EncodePng(image); }
        catch (Exception ex) when (ex is IOException or InvalidDataException or NotSupportedException or ExternalException) { png = null; }
        // Bitmap clipboard transfer remains lossless even when PNG would exceed the encoded cap.
        return new PreparedClipboardImage(image, png);
    }
    public static void CopyImage(byte[] encoded) => CopyImage(PrepareImage(encoded));
    public static void CopyImage(PreparedClipboardImage prepared)
    {
        var data = new DataObject(); data.SetImage(prepared.Image);
        if (prepared.Png is not null) data.SetData("PNG", new MemoryStream(prepared.Png, false), false);
        AddMarker(data); Set(data);
    }
    private static void AddMarker(DataObject data) => data.SetData(ClipboardMonitor.OwnFormat, ClipboardMonitor.OwnValue, false);
    private static void Set(DataObject data)
    {
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA) throw new InvalidOperationException("Clipboard copy must run on the UI thread.");
        for (int attempt = 0; ; attempt++)
        {
            try { System.Windows.Clipboard.SetDataObject(data, true); return; }
            catch (ExternalException) when (attempt < 5) { Thread.Sleep(20 * (attempt + 1)); }
        }
    }
}

public sealed class GlobalHotKey : IDisposable
{
    public const uint ModAlt = 1, ModControl = 2, ModShift = 4, ModWin = 8;
    private readonly Action invoke;
    private readonly HwndSource window;
    private int currentId;
    private int nextId = 10;
    private uint key;
    private uint modifiers;
    private nint previousForeground;
    public GlobalHotKey(Action onInvoke)
    {
        invoke = onInvoke;
        window = new HwndSource(new HwndSourceParameters("ClipDiary hotkey") { ParentWindow = new nint(-3), WindowStyle = 0, Width = 0, Height = 0 });
        window.AddHook(Hook);
    }
    public void Register(uint key = 0x44, uint modifiers = ModControl | ModAlt)
    {
        if (key is < 1 or > 254 || (modifiers & ~15u) != 0 || modifiers == 0) throw new ArgumentException("Choose a key with Ctrl, Alt, Shift or Windows.");
        if (currentId != 0 && this.key == key && this.modifiers == modifiers) return;
        int candidate = ++nextId;
        if (!RegisterHotKey(window.Handle, candidate, modifiers | 0x4000, key)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Shortcut is unavailable. The previous shortcut remains active.");
        if (currentId != 0) UnregisterHotKey(window.Handle, currentId);
        currentId = candidate; this.key = key; this.modifiers = modifiers;
    }
    public void RememberForeground()
    {
        var foreground = GetForegroundWindow();
        if (foreground != 0) { GetWindowThreadProcessId(foreground, out var process); if (process != Environment.ProcessId) previousForeground = foreground; }
    }
    public bool RestoreForeground()
    {
        if (previousForeground == 0 || !IsWindow(previousForeground)) return false;
        return SetForegroundWindow(previousForeground); // Windows may refuse focus; never inject input to override it.
    }
    private nint Hook(nint hwnd, int message, nint wparam, nint lparam, ref bool handled)
    {
        if (message == 0x0312 && wparam == currentId) { handled = true; RememberForeground(); invoke(); }
        return 0;
    }
    public void Dispose() { if (currentId != 0) UnregisterHotKey(window.Handle, currentId); currentId = 0; window.RemoveHook(Hook); window.Dispose(); }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterHotKey(nint hwnd, int id);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint hwnd, out uint process);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(nint hwnd);
}

public sealed class TrayService : IDisposable
{
    private readonly Forms.NotifyIcon icon;
    private readonly Forms.ToolStripMenuItem pauseItem;
    private readonly System.Drawing.Icon? ownedIcon;
    public TrayService(Action open, Action settings, Action pause, Action quit)
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open ClipDiary", null, (_, _) => open());
        menu.Items.Add("Settings", null, (_, _) => settings());
        pauseItem = new Forms.ToolStripMenuItem("Pause capture", null, (_, _) => pause()); menu.Items.Add(pauseItem);
        menu.Items.Add(new Forms.ToolStripSeparator()); menu.Items.Add("Quit", null, (_, _) => quit());
        try { if (Environment.ProcessPath is { } executable) ownedIcon = System.Drawing.Icon.ExtractAssociatedIcon(executable); } catch (Exception ex) when (ex is ArgumentException or System.ComponentModel.Win32Exception or IOException) { }
        icon = new Forms.NotifyIcon { Text = "ClipDiary", Icon = ownedIcon ?? System.Drawing.SystemIcons.Application, ContextMenuStrip = menu, Visible = true };
        icon.DoubleClick += (_, _) => open();
    }
    public void SetPaused(bool paused) { pauseItem.Text = paused ? "Resume capture" : "Pause capture"; pauseItem.Checked = paused; }
    public void Dispose() { icon.Visible = false; var menu = icon.ContextMenuStrip; icon.Dispose(); menu?.Dispose(); ownedIcon?.Dispose(); }
}

public static class StartupService
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public static bool IsEnabled
    {
        get { using var key = Registry.CurrentUser.OpenSubKey(RunKey); return string.Equals(key?.GetValue("ClipDiary") as string, Command(), StringComparison.OrdinalIgnoreCase); }
    }
    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, true);
        if (enabled) key.SetValue("ClipDiary", Command(), RegistryValueKind.String);
        else key.DeleteValue("ClipDiary", false);
    }
    private static string Command()
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Cannot locate the application executable.");
        if (executable.Contains('"') || !Path.IsPathFullyQualified(executable)) throw new InvalidOperationException("Invalid application path.");
        return "\"" + executable + "\" --background";
    }
}
