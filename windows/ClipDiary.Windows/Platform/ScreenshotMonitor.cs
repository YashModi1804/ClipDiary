using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ClipDiary.Windows.Platform;

public sealed class ScreenshotMonitor : IDisposable, IAsyncDisposable
{
    private readonly CaptureSession session;
    private readonly Func<ClipboardPayload, CancellationToken, Task<bool>> callback;
    private readonly string statePath;
    private readonly object gate = new();
    private readonly SemaphoreSlim scans = new(1, 1);
    private readonly List<FileSystemWatcher> watchers = [];
    private readonly Dictionary<string, string> roots = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Pending> pending = [];
    private readonly HashSet<string> inFlight = [];
    private Ledger ledger = new();
    private Timer? timer;
    private CancellationTokenSource? debounce;
    private CancellationTokenSource captureCancellation = new();
    private long configurationGeneration;
    private bool enabled = true, started, disposed, automatic = true;
    private string? explicitFolder;
    private string status = "Screenshot capture stopped";
    private string? configurationError;
    private string? ledgerError;
    private int ticks;
    public event Action? StatusChanged;
    public string Status { get { lock (gate) return status; } }
    public string? Folder { get { lock (gate) return explicitFolder ?? roots.Keys.FirstOrDefault(); } }
    public bool Enabled
    {
        get { lock (gate) return enabled; }
        set { lock (gate) { if (enabled == value) return; enabled = value; CancelPending(); BaselineNow(); RefreshStatus(); } Schedule(); }
    }
    private sealed record Pending(string Signature, DateTimeOffset Next, int Attempts, string? Error);
    public sealed class Ledger
    {
        public int Version { get; set; } = 1;
        public HashSet<string> Consumed { get; set; } = [];
        public Dictionary<string, DateTimeOffset> Baselines { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, string> ApprovedRoots { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    }
    public ScreenshotMonitor(CaptureSession session, Func<ClipboardPayload, CancellationToken, Task<bool>> onCapture, string stateDirectory, string? folder = null, bool enabled = true)
    {
        this.session = session; callback = onCapture; this.enabled = enabled;
        statePath = Path.Combine(stateDirectory, "screenshot-ledger.json");
        try
        {
            LocalFiles.ValidatePath(stateDirectory); Directory.CreateDirectory(stateDirectory); LocalFiles.ValidatePath(stateDirectory);
            if (File.Exists(statePath))
            {
                if ((File.GetAttributes(statePath) & FileAttributes.ReparsePoint) != 0 || new FileInfo(statePath).Length > 24 * 1024 * 1024) throw new IOException("Screenshot ledger is linked or too large.");
                ledger = JsonSerializer.Deserialize<Ledger>(File.ReadAllBytes(statePath)) ?? throw new InvalidDataException("Empty screenshot ledger.");
                if (ledger.Version != 1 || ledger.Consumed is null || ledger.Baselines is null || ledger.ApprovedRoots is null || ledger.Consumed.Count > 100_000) throw new InvalidDataException("Unsupported screenshot ledger.");
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or ArgumentException)
        {
            ledgerError = "Screenshot capture blocked: preserve and recover the existing screenshot ledger. " + ex.Message;
            status = ledgerError;
            ledger = new Ledger();
        }
        explicitFolder = folder; automatic = folder is null;
        session.Changed += SessionChanged;
    }
    public void Start()
    {
        lock (gate) { if (started || disposed) return; started = true; ConfigureRoots(); }
        timer = new Timer(_ => Tick(), null, TimeSpan.FromMilliseconds(200), TimeSpan.FromMilliseconds(300));
        Schedule();
    }
    // null means automatic OS screenshot locations; Enabled=false is the explicit off switch.
    public void ConfigureFolder(string? folder, bool automatic = false)
    {
        string? validated = folder is null ? null : LocalFiles.ValidatePath(folder);
        if (validated is not null && !Directory.Exists(validated)) throw new DirectoryNotFoundException("Choose an existing local screenshot folder.");
        lock (gate)
        {
            CancelPending(); explicitFolder = validated; this.automatic = folder is null || automatic;
            pending.Clear(); configurationError = null;
            if (started) { ledger.ApprovedRoots.Clear(); ConfigureRoots(); }
        }
        Schedule();
    }
    public void ImportNow() => Schedule();
    private void ConfigureRoots()
    {
        if (ledgerError is not null) { SetStatus(ledgerError); return; }
        configurationError = null;
        foreach (var watcher in watchers) watcher.Dispose(); watchers.Clear(); roots.Clear();
        var candidates = explicitFolder is not null ? new[] { explicitFolder } : AutomaticFolders();
        foreach (var candidate in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                string folder = LocalFiles.ValidatePath(candidate);
                if (!Directory.Exists(folder)) continue;
                string identity = LocalFiles.DirectoryIdentity(folder).Key;
                if (ledger.ApprovedRoots.TryGetValue(folder, out string? approved) && approved != identity) throw new IOException("Screenshot folder was replaced. Select it again in Settings.");
                ledger.ApprovedRoots[folder] = identity;
                roots[folder] = identity;
                if (!ledger.Baselines.ContainsKey(identity)) ledger.Baselines[identity] = automatic ? DateTimeOffset.UtcNow - CapturePolicy.Retention : DateTimeOffset.UtcNow;
                var watcher = new FileSystemWatcher(folder) { IncludeSubdirectories = false, NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime, InternalBufferSize = 16 * 1024 };
                watcher.Created += (_, _) => Schedule(); watcher.Changed += (_, _) => Schedule(); watcher.Renamed += (_, _) => Schedule(); watcher.Deleted += (_, _) => Schedule();
                watcher.Error += (_, _) => { SetStatus("Screenshot events were interrupted; reconciling local files"); Schedule(); };
                watcher.EnableRaisingEvents = true; watchers.Add(watcher);
            }
            catch (Exception ex) { configurationError = "Screenshot folder: " + ex.Message; }
        }
        if (automatic && roots.Count == 0)
        {
            foreach (string parent in candidates.Select(Path.GetDirectoryName).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase))
            {
                try
                {
                    LocalFiles.ValidatePath(parent);
                    if (!Directory.Exists(parent)) continue;
                    var watcher = new FileSystemWatcher(parent) { IncludeSubdirectories = false, NotifyFilter = NotifyFilters.DirectoryName };
                    FileSystemEventHandler created = (_, _) => _ = Task.Run(() => { lock (gate) { if (disposed) return; ConfigureRoots(); } Schedule(); });
                    watcher.Created += created;
                    watcher.Renamed += (_, _) => created(this, null!);
                    watcher.EnableRaisingEvents = true; watchers.Add(watcher);
                }
                catch (Exception ex) { configurationError = ex.Message; }
            }
        }
        SaveLedger();
        SetStatus(configurationError ?? (roots.Count > 0 ? "Watching local screenshot folder" : "Waiting for Windows to create its Screenshots folder"));
    }
    private static IEnumerable<string> AutomaticFolders()
    {
        nint pointer = 0;
        var id = new Guid("b7bede81-df94-4682-a7d8-57a52620b86f");
        try
        {
            if (SHGetKnownFolderPath(ref id, 0x4000, 0, out pointer) == 0 && pointer != 0)
            {
                string? known = Marshal.PtrToStringUni(pointer); if (!string.IsNullOrEmpty(known)) yield return known;
            }
        }
        finally { if (pointer != 0) Marshal.FreeCoTaskMem(pointer); }
        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Screenshots");
        foreach (string name in new[] { "OneDrive", "OneDriveConsumer", "OneDriveCommercial" })
        {
            string? oneDrive = Environment.GetEnvironmentVariable(name);
            if (!string.IsNullOrWhiteSpace(oneDrive)) yield return Path.Combine(oneDrive, "Pictures", "Screenshots");
        }
    }
    private void SessionChanged()
    {
        lock (gate) { if (disposed) return; CancelPending(); BaselineNow(); pending.Clear(); }
        Schedule();
    }
    private void CancelPending()
    {
        configurationGeneration++;
        captureCancellation.Cancel(); captureCancellation.Dispose(); captureCancellation = new CancellationTokenSource();
    }
    private void BaselineNow()
    {
        foreach (var root in roots.Values) ledger.Baselines[root] = DateTimeOffset.UtcNow;
        if (started) SaveLedger();
    }
    private void Tick()
    {
        lock (gate)
        {
            if (disposed || !started) return;
            if (++ticks >= 100)
            {
                ticks = 0;
                if (automatic) { try { ConfigureRoots(); } catch (Exception ex) { configurationError = ex.Message; } }
                Schedule(); return;
            }
            if (pending.Values.Any(p => p.Next <= DateTimeOffset.UtcNow)) _ = Task.Run(async () => { try { await Scan(CancellationToken.None).ConfigureAwait(false); } catch (OperationCanceledException) { } catch (Exception ex) { SetStatus("Screenshot import: " + ex.Message); } });
        }
    }
    private void Schedule()
    {
        CancellationToken token;
        lock (gate)
        {
            if (disposed || !started) return;
            debounce?.Cancel(); debounce?.Dispose(); debounce = new CancellationTokenSource(); token = debounce.Token;
        }
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(180, token).ConfigureAwait(false); await Scan(token).ConfigureAwait(false); }
            catch (OperationCanceledException) { }
            catch (Exception ex) { SetStatus("Screenshot import: " + ex.Message); }
        });
    }
    private async Task Scan(CancellationToken scheduled)
    {
        if (disposed || ledgerError is not null || !enabled || !session.CanCapture || !await scans.WaitAsync(0, scheduled).ConfigureAwait(false)) return;
        try
        {
            KeyValuePair<string, string>[] locations; long generation = session.Generation; long configuration;
            CancellationToken localToken;
            lock (gate) { locations = roots.ToArray(); configuration = configurationGeneration; localToken = captureCancellation.Token; }
            using var scanCancellation = CancellationTokenSource.CreateLinkedTokenSource(session.Token, localToken);
            var token = scanCancellation.Token;
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var root in locations)
            {
                scheduled.ThrowIfCancellationRequested(); token.ThrowIfCancellationRequested();
                if (LocalFiles.DirectoryIdentity(root.Key).Key != root.Value) throw new IOException("Screenshot directory was moved or replaced; select it again.");
                int count = 0;
                foreach (var file in Directory.EnumerateFiles(root.Key, "*", SearchOption.TopDirectoryOnly))
                {
                    if (++count > 10_000) throw new IOException("Screenshot folder has more than10000 entries; choose a dedicated folder.");
                    if (!CapturePolicy.IsImagePath(file)) continue;
                    LocalFiles.Identity identity;
                    try { identity = LocalFiles.FileIdentity(file); } catch { continue; }
                    seen.Add(identity.Key);
                    string key = identity.Key, signature = identity.Length + ":" + identity.Modified.UtcTicks;
                    DateTimeOffset baseline;
                    lock (gate)
                    {
                        if (disposed || !enabled || generation != session.Generation || configuration != configurationGeneration || ledger.Consumed.Contains(key) || inFlight.Contains(key)) continue;
                        baseline = ledger.Baselines[root.Value];
                        if (!CapturePolicy.EligibleScreenshot(identity.Created, baseline, DateTimeOffset.UtcNow)) { ledger.Consumed.Add(key); continue; }
                        if (pending.TryGetValue(key, out var old) && old.Signature == signature)
                        {
                            if (old.Next > DateTimeOffset.UtcNow) continue;
                        }
                        else { pending[key] = new Pending(signature, DateTimeOffset.UtcNow.AddMilliseconds(180), 0, null); continue; }
                        if (DateTimeOffset.UtcNow - identity.Modified < TimeSpan.FromMilliseconds(150)) continue;
                        if (identity.Length == 0) { Defer(key, signature, "Waiting for screenshot write to complete"); continue; }
                        if (identity.Length > CapturePolicy.MaximumImageBytes) { Defer(key, signature, "Screenshot skipped: image exceeds25 MB", permanent: true); continue; }
                        if (ledger.Consumed.Count >= 100_000) throw new IOException("Screenshot ledger limit reached; choose a fresh state directory.");
                        inFlight.Add(key);
                    }
                    var workCancellation = CancellationTokenSource.CreateLinkedTokenSource(session.Token, localToken);
                    bool accepted = session.Pipeline.Queue(session, async cancellation =>
                    {
                        try
                        {
                            cancellation.ThrowIfCancellationRequested();
                            var bytes = LocalFiles.ReadStable(file, identity, root.Value);
                            var payload = ImageCodec.Prepare(bytes, Path.GetFileName(file), "Screenshot folder", identity.Created) with { IsFileScreenshot = true };
                            cancellation.ThrowIfCancellationRequested();
                            if (!await session.Pipeline.Deliver(session, payload, true, callback, cancellation).ConfigureAwait(false)) throw new IOException("Local storage rejected the screenshot; retrying later.");
                            lock (gate)
                            {
                                if (disposed || !enabled || cancellation.IsCancellationRequested || generation != session.Generation || configuration != configurationGeneration) return;
                                ledger.Consumed.Add(key); pending.Remove(key); SaveLedger(); RefreshStatus();
                            }
                        }
                        catch (OperationCanceledException) { }
                        catch (Exception ex) { lock (gate) { if (!disposed) Defer(key, signature, "Screenshot import: " + ex.Message); } }
                        finally { workCancellation.Dispose(); lock (gate) inFlight.Remove(key); }
                    }, workCancellation.Token);
                    if (!accepted) { workCancellation.Dispose(); lock (gate) inFlight.Remove(key); }
                }
                if (LocalFiles.DirectoryIdentity(root.Key).Key != root.Value) throw new IOException("Screenshot directory changed while scanning.");
            }
            lock (gate) { if (!disposed) { foreach (string key in pending.Keys.Where(k => !seen.Contains(k) && !inFlight.Contains(k)).ToArray()) pending.Remove(key); SaveLedger(); RefreshStatus(); } }
        }
        finally { scans.Release(); }
    }
    private void Defer(string key, string signature, string error, bool permanent = false)
    {
        int attempts = pending.TryGetValue(key, out var old) && old.Signature == signature ? old.Attempts + 1 : 1;
        pending[key] = new Pending(signature, permanent ? DateTimeOffset.MaxValue : DateTimeOffset.UtcNow + CapturePolicy.RetryDelay(attempts), attempts, error);
        SetStatus(error);
    }
    private void RefreshStatus()
    {
        string? error = pending.Values.Select(p => p.Error).FirstOrDefault(p => p is not null);
        SetStatus(ledgerError ?? configurationError ?? error ?? (enabled ? "Watching local screenshot folder" : "Screenshot capture paused"));
    }
    private void SaveLedger()
    {
        if (ledgerError is not null) return;
        if (ledger.Consumed.Count > 100_000) throw new IOException("Screenshot ledger exceeds its safety limit.");
        if (File.Exists(statePath) && (File.GetAttributes(statePath) & FileAttributes.ReparsePoint) != 0) throw new IOException("Screenshot ledger was replaced by a link.");
        string temporary = statePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(ledger);
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) { stream.Write(bytes); stream.Flush(true); }
            File.Move(temporary, statePath, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private void SetStatus(string value) { lock (gate) { if (status == value) return; status = value; } _ = Task.Run(() => StatusChanged?.Invoke()); }
    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return; disposed = true; session.Changed -= SessionChanged;
            timer?.Dispose(); captureCancellation.Cancel(); captureCancellation.Dispose(); debounce?.Cancel(); debounce?.Dispose(); foreach (var watcher in watchers) watcher.Dispose(); watchers.Clear();
        }
    }
    public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern int SHGetKnownFolderPath(ref Guid id, uint flags, nint token, out nint path);
}
