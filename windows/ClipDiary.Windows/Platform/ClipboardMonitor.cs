using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using WpfClipboard = System.Windows.Clipboard;

namespace ClipDiary.Windows.Platform;

public sealed class ClipboardMonitor : IDisposable
{
    internal const string OwnFormat = "ClipDiary.OwnWrite";
    internal static readonly string OwnValue = Guid.NewGuid().ToString("N");
    private readonly CaptureSession session;
    private readonly Func<ClipboardPayload, CancellationToken, Task<bool>> callback;
    private readonly Dispatcher dispatcher;
    private HwndSource? window;
    private readonly DispatcherTimer retry;
    private uint baseline;
    private uint pending;
    private int retries;
    private bool disposed;
    private string status = "Clipboard capture stopped";
    public string Status => status;
    public event Action? StatusChanged;
    public ClipboardMonitor(CaptureSession session, Func<ClipboardPayload, CancellationToken, Task<bool>> onCapture)
    {
        this.session = session; callback = onCapture; dispatcher = Dispatcher.CurrentDispatcher;
        retry = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromMilliseconds(60) };
        retry.Tick += RetryTick;
        session.Changed += SessionChanged;
    }
    public void Start()
    {
        dispatcher.VerifyAccess();
        if (window is not null || disposed) return;
        baseline = NativeClipboard.GetClipboardSequenceNumber();
        window = new HwndSource(new HwndSourceParameters("ClipDiary clipboard observer") { ParentWindow = new nint(-3), WindowStyle = 0, Width = 0, Height = 0 });
        window.AddHook(Hook);
        if (!NativeClipboard.AddClipboardFormatListener(window.Handle)) { window.Dispose(); window = null; throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
        SetStatus(session.CanCapture ? "Capture active" : "Capture paused or locked");
    }
    public void MarkOwnWrite()
    {
        dispatcher.VerifyAccess(); baseline = NativeClipboard.GetClipboardSequenceNumber(); pending = baseline; retry.Stop();
    }
    private nint Hook(nint hwnd, int message, nint wparam, nint lparam, ref bool handled)
    {
        if (message == 0x031D)
        {
            var sequence = NativeClipboard.GetClipboardSequenceNumber();
            if (sequence != baseline) { pending = sequence; retries = 0; ReadPending(); }
        }
        return 0;
    }
    private void SessionChanged() => dispatcher.BeginInvoke(() =>
    {
        baseline = NativeClipboard.GetClipboardSequenceNumber(); pending = baseline; retry.Stop();
        SetStatus(session.CanCapture ? "Capture active" : "Capture paused or locked");
    });
    private void RetryTick(object? sender, EventArgs e) { retry.Stop(); ReadPending(); }
    private void ReadPending()
    {
        if (disposed || window is null) return;
        var sequence = NativeClipboard.GetClipboardSequenceNumber();
        if (!session.CanCapture) { baseline = sequence; return; }
        if (pending != sequence) { pending = sequence; retries = 0; }
        if (sequence == baseline) return;
        var generation = session.Generation;
        var token = session.Token;
        try
        {
            // Check registered privacy formats before asking for any content.
            if (WpfClipboard.ContainsData(OwnFormat)) NativeClipboard.EnsureFormatSize(NativeClipboard.RegisterClipboardFormat(OwnFormat), 4096);
            if (Sensitive() || (WpfClipboard.ContainsData(OwnFormat) && Equals(WpfClipboard.GetData(OwnFormat), OwnValue))) { baseline = sequence; return; }
            string source = SourceProcess();
            if (session.IsExcluded(source)) { baseline = sequence; return; }
            byte[]? encoded = null;
            BitmapSource? bitmap = null;
            if (WpfClipboard.ContainsData("PNG"))
            {
                NativeClipboard.EnsureFormatSize(NativeClipboard.RegisterClipboardFormat("PNG"), CapturePolicy.MaximumImageBytes + 64);
                encoded = ReadPng(WpfClipboard.GetData("PNG"));
            }
            else if (WpfClipboard.ContainsImage())
            {
                NativeClipboard.ValidateBitmapDimensions();
                bitmap = WpfClipboard.GetImage();
                if (bitmap is not null)
                {
                    if (!CapturePolicy.ValidDimensions(bitmap.PixelWidth, bitmap.PixelHeight)) throw new InvalidDataException("Image exceeds the 50-megapixel limit.");
                    bitmap.Freeze();
                }
            }
            if (NativeClipboard.GetClipboardSequenceNumber() != sequence || generation != session.Generation || token.IsCancellationRequested) { ScheduleRetry(); return; }
            var capturedAt = DateTimeOffset.UtcNow;
            if (encoded is not null || bitmap is not null)
            {
                var frozen = bitmap;
                var queued = session.Pipeline.Queue(session, async cancellation =>
                {
                    try
                    {
                        cancellation.ThrowIfCancellationRequested();
                        var bytes = encoded ?? ImageCodec.EncodePng(frozen!);
                        var payload = ImageCodec.Prepare(bytes, "Image", source, capturedAt);
                        cancellation.ThrowIfCancellationRequested();
                        if (!await session.Pipeline.Deliver(session, payload, false, callback, cancellation).ConfigureAwait(false)) SetStatus("Could not save clipboard image");
                        else SetStatus("Capture active");
                    }
                    catch (OperationCanceledException) { }
                    catch (Exception ex) { SetStatus("Image capture: " + ex.Message); }
                }, token);
                if (!queued) SetStatus("Image capture busy; copy the image again");
                baseline = sequence;
                return;
            }
            if (WpfClipboard.ContainsText(TextDataFormat.UnicodeText))
            {
                NativeClipboard.EnsureFormatSize(13, CapturePolicy.MaximumTextBytes * 2 + 64);
                string text = WpfClipboard.GetText(TextDataFormat.UnicodeText);
                if (NativeClipboard.GetClipboardSequenceNumber() != sequence || generation != session.Generation) { ScheduleRetry(); return; }
                baseline = sequence;
                if (!CapturePolicy.ValidText(text)) { SetStatus("Text skipped: empty or larger than1 MB"); return; }
                int newline = text.IndexOf('\n');
                int titleLength = Math.Min(120, newline < 0 ? text.Length : newline);
                if (titleLength > 0 && char.IsHighSurrogate(text[titleLength - 1])) titleLength--;
                var payload = new ClipboardPayload { Text = text, Title = text[..titleLength], Source = source, CapturedAt = capturedAt, Digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))) };
                bool accepted = session.Pipeline.QueueText(async () =>
                {
                    try { if (await session.Pipeline.Deliver(session, payload, false, callback, token).ConfigureAwait(false)) SetStatus("Capture active"); else SetStatus("Could not save clipboard text"); }
                    catch (OperationCanceledException) { }
                    catch (Exception ex) { SetStatus("Clipboard save: " + ex.Message); }
                }, token);
                if (!accepted) SetStatus("Text capture busy; copy the item again");
            }
            else baseline = sequence;
        }
        catch (ExternalException) { ScheduleRetry(); }
        catch (Exception ex) { baseline = sequence; SetStatus("Clipboard capture: " + ex.Message); }
    }
    private void ScheduleRetry()
    {
        if (++retries > 12) { baseline = NativeClipboard.GetClipboardSequenceNumber(); SetStatus("Clipboard is busy; copy the item again"); return; }
        retry.Interval = TimeSpan.FromMilliseconds(Math.Min(500, retries * 50)); retry.Start();
    }
    private static bool Sensitive()
    {
        foreach (var name in new[] { "ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore", "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "application/x-keepassx", "Password" })
            if (NativeClipboard.IsClipboardFormatAvailable(NativeClipboard.RegisterClipboardFormat(name))) return true;
        if (WpfClipboard.ContainsData("CanIncludeInClipboardHistory"))
        {
            NativeClipboard.EnsureFormatSize(NativeClipboard.RegisterClipboardFormat("CanIncludeInClipboardHistory"), 4096);
            var value = WpfClipboard.GetData("CanIncludeInClipboardHistory");
            return value switch { int number => number == 0, uint number => number == 0, byte[] bytes when bytes.Length >= 4 => BitConverter.ToUInt32(bytes) == 0, MemoryStream stream when stream.Length >= 4 => ReadDword(stream) == 0, _ => true };
        }
        return false;
    }
    private static uint ReadDword(MemoryStream stream) { var position = stream.Position; try { stream.Position = 0; Span<byte> bytes = stackalloc byte[4]; stream.ReadExactly(bytes); return BitConverter.ToUInt32(bytes); } finally { stream.Position = position; } }
    private static byte[]? ReadPng(object? value)
    {
        if (value is byte[] bytes) return NormalizePng(bytes);
        if (value is Stream stream)
        {
            if (stream.CanSeek && stream.Length > CapturePolicy.MaximumImageBytes + 64) throw new InvalidDataException("Image exceeds25 MB");
            var position = stream.CanSeek ? stream.Position : 0;
            try
            {
                if (stream.CanSeek) stream.Position = 0;
                using var output = new MemoryStream(); var buffer = new byte[16 * 1024]; int read;
                while ((read = stream.Read(buffer, 0, buffer.Length)) > 0) { if (output.Length + read > CapturePolicy.MaximumImageBytes + 64) throw new InvalidDataException("Image exceeds25 MB"); output.Write(buffer, 0, read); }
                return NormalizePng(output.ToArray());
            }
            finally { if (stream.CanSeek) stream.Position = position; }
        }
        return null;
    }
    private static byte[] NormalizePng(byte[] bytes)
    {
        ReadOnlySpan<byte> end = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
        int length = bytes.Length;
        // HGLOBAL allocations may include zero alignment padding, not image content.
        for (int padding = 0; padding <= 64 && length >= end.Length; padding++)
        {
            if (bytes.AsSpan(0, length).EndsWith(end)) return length <= CapturePolicy.MaximumImageBytes ? bytes.AsSpan(0, length).ToArray() : throw new InvalidDataException("Image exceeds25 MB");
            if (length == 0 || bytes[length - 1] != 0) break;
            length--;
        }
        throw new InvalidDataException("Clipboard PNG is incomplete.");
    }
    private static string SourceProcess()
    {
        var owner = NativeClipboard.GetClipboardOwner();
        if (owner == 0) return "Unknown application"; // Foreground attribution would invent an original source.
        NativeClipboard.GetWindowThreadProcessId(owner, out var pid);
        try { return Process.GetProcessById((int)pid).ProcessName; } catch { return "Unknown application"; }
    }
    private void SetStatus(string value)
    {
        if (!dispatcher.CheckAccess()) { dispatcher.BeginInvoke(() => SetStatus(value)); return; }
        if (disposed || status == value) return;
        status = value; StatusChanged?.Invoke();
    }
    public void Dispose()
    {
        dispatcher.VerifyAccess(); if (disposed) return; disposed = true; retry.Stop(); session.Changed -= SessionChanged;
        if (window is not null) { NativeClipboard.RemoveClipboardFormatListener(window.Handle); window.RemoveHook(Hook); window.Dispose(); window = null; }
    }
}

internal static class NativeClipboard
{
    internal static void EnsureFormatSize(uint format, int maximum)
    {
        if (!OpenClipboard(0)) throw new ExternalException("Clipboard is busy.");
        try
        {
            var handle = GetClipboardData(format);
            if (handle == 0) throw new ExternalException("Clipboard data is temporarily unavailable.");
            nuint size = GlobalSize(handle);
            if (size == 0 || size > (nuint)maximum) throw new InvalidDataException("Clipboard item exceeds its capture size limit.");
        }
        finally { CloseClipboard(); }
    }
    internal static void ValidateBitmapDimensions()
    {
        if (!OpenClipboard(0)) throw new ExternalException("Clipboard is busy.");
        try
        {
            if (IsClipboardFormatAvailable(2))
            {
                var handle = GetClipboardData(2);
                if (handle == 0 || GetObject(handle, Marshal.SizeOf<BitmapHeader>(), out var bitmap) == 0) throw new ExternalException("Bitmap is temporarily unavailable.");
                if (!CapturePolicy.ValidDimensions(bitmap.Width, bitmap.Height)) throw new InvalidDataException("Image exceeds the 50-megapixel limit.");
            }
            else
            {
                var handle = GetClipboardData(IsClipboardFormatAvailable(17) ? 17u : 8u);
                nuint size = handle == 0 ? 0 : GlobalSize(handle);
                if (size < 12 || size > 256 * 1024 * 1024) throw new InvalidDataException("Bitmap data exceeds its capture limit.");
                var pointer = GlobalLock(handle);
                if (pointer == 0) throw new ExternalException("Bitmap is temporarily unavailable.");
                try
                {
                    int header = Marshal.ReadInt32(pointer);
                    int width = header == 12 ? (ushort)Marshal.ReadInt16(pointer, 4) : Marshal.ReadInt32(pointer, 4);
                    long rawHeight = header == 12 ? (ushort)Marshal.ReadInt16(pointer, 6) : Marshal.ReadInt32(pointer, 8);
                    long height = Math.Abs(rawHeight);
                    if (header < 12 || (header != 12 && size < 40) || height > int.MaxValue || !CapturePolicy.ValidDimensions(width, (int)height)) throw new InvalidDataException("Image exceeds the 50-megapixel limit.");
                }
                finally { GlobalUnlock(handle); }
            }
        }
        finally { CloseClipboard(); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct BitmapHeader { public int Type, Width, Height, WidthBytes; public ushort Planes, BitsPixel; public nint Bits; }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool OpenClipboard(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)] private static extern nint GetClipboardData(uint format);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern nuint GlobalSize(nint handle);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern nint GlobalLock(nint handle);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GlobalUnlock(nint handle);
    [DllImport("gdi32.dll", EntryPoint = "GetObjectW")] private static extern int GetObject(nint handle, int size, out BitmapHeader bitmap);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool AddClipboardFormatListener(nint hwnd);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool RemoveClipboardFormatListener(nint hwnd);
    [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] internal static extern nint GetClipboardOwner();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern uint RegisterClipboardFormat(string name);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsClipboardFormatAvailable(uint format);
}
