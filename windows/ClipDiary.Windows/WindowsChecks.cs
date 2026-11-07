using System;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ClipDiary.Windows.Platform;

namespace ClipDiary.Windows;

// Only the explicit --windows-checks entry point may touch a synthetic OS clipboard.
public static class WindowsChecks
{
    public static async Task<int> RunAsync()
    {
        if (!OperatingSystem.IsWindows() || Thread.CurrentThread.GetApartmentState() != ApartmentState.STA) { Console.Error.WriteLine("Windows checks require an interactive Windows STA desktop."); return 2; }
        string user = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
        if (Mutex.TryOpenExisting(@"Local\ClipDiary-" + user, out var running))
        {
            running.Dispose(); Console.Error.WriteLine("Close the running ClipDiary application before synthetic clipboard checks."); return 2;
        }
        string root = Path.Combine(Path.GetTempPath(), "ClipDiary-WindowsChecks-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        int count = 0;
        void Check(bool valid, string label) { if (!valid) throw new InvalidOperationException(label); count++; Console.WriteLine("PASS: " + label); }
        async Task Wait(Func<bool> condition, int milliseconds = 5000)
        {
            var deadline = DateTime.UtcNow.AddMilliseconds(milliseconds);
            while (!condition() && DateTime.UtcNow < deadline) await Task.Delay(20);
            Check(condition(), "async condition completed within its deadline");
        }
        try
        {
            Check(!CapturePolicy.ValidDimensions(0, 10) && CapturePolicy.ValidDimensions(10000, 5000) && !CapturePolicy.ValidDimensions(int.MaxValue, int.MaxValue), "Pixel limits reject zero and overflow dimensions");
            Check(!CapturePolicy.IsPngComplete([137, 80, 78, 71, 13, 10, 26, 10]), "Truncated PNG is rejected");
            var now = DateTimeOffset.UtcNow;
            Check(!CapturePolicy.EligibleScreenshot(now - CapturePolicy.Retention, now - CapturePolicy.Retention - TimeSpan.FromSeconds(1), now), "96-hour boundary is expired");
            var bitmap = new WriteableBitmap(2, 2, 96, 96, PixelFormats.Bgra32, null);
            bitmap.WritePixels(new Int32Rect(0, 0, 2, 2), new byte[] { 5, 30, 200, 255, 10, 30, 200, 255, 15, 30, 200, 255, 20, 30, 200, 255 }, 8, 0);
            bitmap.Freeze();
            byte[] png = ImageCodec.EncodePng(bitmap);
            var prepared = await Task.Run(() => ImageCodec.Prepare(png, "Synthetic image", "Synthetic source", now));
            Check(prepared.ThumbnailData is { Length: > 0 } && prepared.ImageData!.SequenceEqual(png) && prepared.Extension == ".png", "Native codec preserves full image and creates PNG thumbnail");
            bool invalid = false; try { ImageCodec.Prepare([1, 2, 3], "Bad image", "test", now); } catch { invalid = true; }
            Check(invalid, "Corrupt image never reaches persistence callback");
            ClipboardWriter.CopyImage(new PreparedClipboardImage(bitmap, null));
            Check(System.Windows.Clipboard.ContainsImage(), "Lossless bitmap copy works when optional PNG encoding exceeds the encoded limit");

            var accepted = new ConcurrentQueue<ClipboardPayload>();
            using var session = new CaptureSession();
            if (!session.CanCapture) { Console.Error.WriteLine("Unlock an interactive Windows user session before native platform checks."); return 2; }
            // This is test-owned content; previous user clipboard contents are never read.
            System.Windows.Clipboard.SetText("Synthetic startup clipboard", TextDataFormat.UnicodeText);
            using var monitor = new ClipboardMonitor(session, (payload, token) => { token.ThrowIfCancellationRequested(); accepted.Enqueue(payload); return Task.FromResult(true); });
            monitor.Start(); await Task.Delay(250);
            Check(accepted.IsEmpty, "Starting listener does not ingest preexisting clipboard");
            void ExternalText(string text, string? marker = null)
            {
                var data = new DataObject(); data.SetText(text, TextDataFormat.UnicodeText);
                if (marker is not null) data.SetData(marker, new MemoryStream([0, 0, 0, 0]), false);
                System.Windows.Clipboard.SetDataObject(data, true);
            }
            ExternalText("Synthetic Unicode 😀\nsecond line");
            await Wait(() => accepted.Count == 1);
            Check(accepted.TryPeek(out var first) && first.Text == "Synthetic Unicode 😀\nsecond line", "Clipboard listener preserves Unicode text");
            ClipboardWriter.CopyText("Synthetic own copy"); await Task.Delay(300);
            Check(accepted.Count == 1, "Own clipboard marker suppresses monitor loop");
            ExternalText("Synthetic private copy", "ExcludeClipboardContentFromMonitorProcessing"); await Task.Delay(250);
            Check(accepted.Count == 1, "Windows history exclusion marker suppresses capture");
            ExternalText("Synthetic private history", "CanIncludeInClipboardHistory"); await Task.Delay(250);
            Check(accepted.Count == 1, "CanIncludeInClipboardHistory zero suppresses capture");
            session.Paused = true; await Task.Delay(40); ExternalText("Synthetic paused content"); await Task.Delay(200); session.Paused = false; await Task.Delay(200);
            Check(accepted.Count == 1, "Pause and resume rebaseline without importing paused contents");
            session.ExcludedProcesses = [System.Diagnostics.Process.GetCurrentProcess().ProcessName]; await Task.Delay(50); ExternalText("Synthetic excluded content"); await Task.Delay(250);
            Check(accepted.Count == 1, "Excluded source process is not ingested");
            session.ExcludedProcesses = []; await Task.Delay(50);
            session.Suspend("check-lock", true); session.Suspend("check-sleep", true); session.Suspend("check-sleep", false);
            Check(!session.CanCapture, "Wake cannot release an independent session lock"); session.Suspend("check-lock", false); await Task.Delay(50);

            var imageData = new DataObject(); imageData.SetImage(bitmap); imageData.SetData("PNG", new MemoryStream(png, false), false); System.Windows.Clipboard.SetDataObject(imageData, true);
            await Wait(() => accepted.Any(p => p.IsImage));
            Check(accepted.Last().ImageData!.SequenceEqual(png), "Clipboard PNG reaches callback with encoded original");
            string folder = Path.Combine(root, "Screenshots"); Directory.CreateDirectory(folder);
            File.WriteAllBytes(Path.Combine(folder, "existing.png"), png);
            using var screenshots = new ScreenshotMonitor(session, (payload, token) => { token.ThrowIfCancellationRequested(); accepted.Enqueue(payload); return Task.FromResult(true); }, Path.Combine(root, "State"), folder);
            int baseline = accepted.Count;
            screenshots.Start(); await Task.Delay(550);
            Check(accepted.Count == baseline, "Explicit screenshot folder baseline ignores existing files");
            session.ForgetRecentImages();
            string newFile = Path.Combine(folder, "new.png"); File.WriteAllBytes(newFile, png);
            await Wait(() => accepted.Count == baseline + 1);
            Check(File.ReadAllBytes(newFile).SequenceEqual(png), "Screenshot file imports without altering its original");
            screenshots.Enabled = false; File.WriteAllBytes(Path.Combine(folder, "disabled.png"), png); await Task.Delay(400); screenshots.Enabled = true; await Task.Delay(500);
            Check(accepted.Count == baseline + 1, "Disabled screenshots do not backfill after resume");
            screenshots.Dispose();
            using var restored = new ScreenshotMonitor(session, (payload, token) => { accepted.Enqueue(payload); return Task.FromResult(true); }, Path.Combine(root, "State"), folder);
            restored.Start(); await Task.Delay(700);
            Check(accepted.Count == baseline + 1, "Durable screenshot ledger prevents reimport after restart");
            string moved = Path.Combine(root, "Moved"); Directory.Move(folder, moved); Directory.CreateDirectory(folder); File.WriteAllBytes(Path.Combine(folder, "unrequested.png"), png); restored.ImportNow(); await Task.Delay(700);
            Check(accepted.Count == baseline + 1, "Replaced directory cannot redirect screenshot capture");
            string brokenState = Path.Combine(root, "BrokenState"); Directory.CreateDirectory(brokenState);
            string brokenLedger = Path.Combine(brokenState, "screenshot-ledger.json"); const string damaged = "{invalid ledger"; File.WriteAllText(brokenLedger, damaged);
            int beforeBroken = accepted.Count;
            using var blocked = new ScreenshotMonitor(session, (payload, token) => { accepted.Enqueue(payload); return Task.FromResult(true); }, brokenState, folder);
            blocked.Start(); blocked.Enabled = false; blocked.Enabled = true; blocked.ConfigureFolder(folder); await Task.Delay(300);
            Check(blocked.Status.Contains("blocked", StringComparison.OrdinalIgnoreCase) && File.ReadAllText(brokenLedger) == damaged && accepted.Count == beforeBroken, "Corrupt screenshot ledger blocks only screenshot capture and is never overwritten");
            ExternalText("Synthetic clipboard still usable after ledger failure");
            await Wait(() => accepted.Count == beforeBroken + 1);
            Check(accepted.Last().Text == "Synthetic clipboard still usable after ledger failure", "Clipboard capture remains available when screenshot ledger recovery is required");

            using (var firstHotkey = new GlobalHotKey(() => { }))
            using (var retainedHotkey = new GlobalHotKey(() => { }))
            using (var probeHotkey = new GlobalHotKey(() => { }))
            {
                firstHotkey.Register(0x87, GlobalHotKey.ModControl | GlobalHotKey.ModAlt | GlobalHotKey.ModShift);
                retainedHotkey.Register(0x86, GlobalHotKey.ModControl | GlobalHotKey.ModAlt | GlobalHotKey.ModShift);
                bool conflict = false, oldRetained = false;
                try { retainedHotkey.Register(0x87, GlobalHotKey.ModControl | GlobalHotKey.ModAlt | GlobalHotKey.ModShift); } catch (System.ComponentModel.Win32Exception) { conflict = true; }
                try { probeHotkey.Register(0x86, GlobalHotKey.ModControl | GlobalHotKey.ModAlt | GlobalHotKey.ModShift); } catch (System.ComponentModel.Win32Exception) { oldRetained = true; }
                Check(conflict && oldRetained, "Failed hotkey replacement retains the previous native registration");
            }
            int finishedWork = 0;
            var workToken = session.Token;
            int queuedWork = 0;
            for (int index = 0; index < 8; index++)
            {
                if (session.Pipeline.Queue(session, async token => { await Task.Delay(2000, token); Interlocked.Increment(ref finishedWork); }, workToken)) queuedWork++;
            }
            Check(queuedWork == 3 && session.QueuedImagePreparations <= 3, "The shared image preparation queue has a hard three-item bound");
            session.Paused = true;
            await Wait(() => session.QueuedImagePreparations == 0);
            Check(finishedWork == 0, "Pause cancels both running and queued image work before persistence");
            session.Paused = false;
            Console.WriteLine($"Windows platform checks passed: {count}");
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine($"Windows checks failed after {count}: {ex.Message}"); return 1; }
        finally { try { Directory.Delete(root, true); } catch { } }
    }
}
