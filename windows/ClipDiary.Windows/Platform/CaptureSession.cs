using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32;

namespace ClipDiary.Windows.Platform;

public sealed class CaptureSession : IDisposable
{
    private readonly object gate = new();
    private readonly HashSet<string> suspensions = new(StringComparer.Ordinal);
    private string[] excluded = [];
    private bool paused;
    private bool disposed;
    private long generation;
    private CancellationTokenSource cancellation = new();
    internal CapturePipeline Pipeline { get; } = new();
    public int QueuedImagePreparations => Pipeline.Queued;
    public event Action? Changed;
    public void ForgetRecentImages() => Pipeline.Forget();
    public bool Paused { get { lock (gate) return paused; } set { lock (gate) { if (disposed || paused == value) return; paused = value; Advance(); } Changed?.Invoke(); } }
    public string[] ExcludedProcesses
    {
        get { lock (gate) return (string[])excluded.Clone(); }
        set
        {
            var normalized = (value ?? []).Select(CapturePolicy.NormalizeProcess).Where(s => s.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            lock (gate) { if (disposed || excluded.SequenceEqual(normalized, StringComparer.OrdinalIgnoreCase)) return; excluded = normalized; Advance(); }
            Changed?.Invoke();
        }
    }
    public bool CanCapture { get { lock (gate) return !disposed && !paused && suspensions.Count == 0; } }
    public CancellationToken Token { get { lock (gate) return disposed ? new CancellationToken(true) : cancellation.Token; } }
    public long Generation { get { lock (gate) return generation; } }
    public bool IsExcluded(string process) { lock (gate) return excluded.Contains(CapturePolicy.NormalizeProcess(process), StringComparer.OrdinalIgnoreCase); }
    public CaptureSession()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        var initial = InitialSessionState();
        if (initial.Locked) suspensions.Add("lock");
        if (initial.Inactive) suspensions.Add("inactive");
        SystemEvents.SessionSwitch += SessionChanged;
        SystemEvents.PowerModeChanged += PowerChanged;
    }
    // Explicit history clearing must also invalidate pending platform work.
    public void InvalidatePending() { lock (gate) { if (disposed) return; Advance(); } Changed?.Invoke(); }
    internal void Suspend(string reason, bool value)
    {
        lock (gate)
        {
            if (disposed || suspensions.Contains(reason) == value) return;
            if (value) suspensions.Add(reason); else suspensions.Remove(reason);
            Advance();
        }
        Changed?.Invoke();
    }
    private void Advance()
    {
        generation++;
        Pipeline.Forget();
        var old = cancellation;
        cancellation = new CancellationTokenSource();
        old.Cancel();
        // Consumers may still hold the old token. CTS is disposed only after cancellation.
        old.Dispose();
    }
    private void SessionChanged(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionLock) Suspend("lock", true);
        if (e.Reason == SessionSwitchReason.SessionUnlock) Suspend("lock", false);
        if (e.Reason is SessionSwitchReason.RemoteDisconnect or SessionSwitchReason.ConsoleDisconnect or SessionSwitchReason.SessionLogoff) Suspend("inactive", true);
        if (e.Reason is SessionSwitchReason.RemoteConnect or SessionSwitchReason.ConsoleConnect or SessionSwitchReason.SessionLogon) Suspend("inactive", false);
    }
    private void PowerChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend) Suspend("sleep", true);
        if (e.Mode == PowerModes.Resume) Suspend("sleep", false);
    }
    private static (bool Locked, bool Inactive) InitialSessionState()
    {
        nint pointer = 0;
        try
        {
            if (!WTSQuerySessionInformation(0, (uint)Process.GetCurrentProcess().SessionId, 25, out pointer, out var size) || size < 20 || Marshal.ReadInt32(pointer) != 1) return (false, false);
            return (Marshal.ReadInt32(pointer, 16) == 0, Marshal.ReadInt32(pointer, 12) != 0);
        }
        finally { if (pointer != 0) WTSFreeMemory(pointer); }
    }
    public void Dispose()
    {
        SystemEvents.SessionSwitch -= SessionChanged;
        SystemEvents.PowerModeChanged -= PowerChanged;
        lock (gate) { if (disposed) return; disposed = true; cancellation.Cancel(); Pipeline.Dispose(); cancellation.Dispose(); }
    }
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "WTSQuerySessionInformationW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WTSQuerySessionInformation(nint server, uint session, int info, out nint buffer, out uint size);
    [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(nint buffer);
}
