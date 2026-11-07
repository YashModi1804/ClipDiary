using System.Windows;
using System.Windows.Threading;
using ClipDiary.Core;
using ClipDiary.Windows.Platform;
using ClipDiary.Windows.UI;

namespace ClipDiary.Windows;

/// <summary>Native UI/clipboard work stays on the dispatcher; persistence runs on the serialized store worker.</summary>
internal sealed class AppController : IClipDiaryActions, IAsyncDisposable
{
    private readonly ClipStore store;
    private readonly Dispatcher dispatcher;
    private readonly LocalSettings persistence;
    private readonly CaptureSession session;
    private readonly ClipboardMonitor clipboard;
    private readonly ScreenshotMonitor screenshots;
    private readonly GlobalHotKey hotkey;
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim copying = new(1, 1);
    private readonly object copyCancellationGate = new();
    private CancellationTokenSource pendingCopies = new();
    private readonly Func<ClipRecord, CancellationToken, Task<PreparedClipboardImage>> prepareCopyImage;
    private readonly Action<PreparedClipboardImage?, string> writeClipboard;
    private readonly SemaphoreSlim changingSettings = new(1, 1);
    private readonly DispatcherTimer maintenance;
    private TrayService? tray;
    private UiSettings settings;
    private string? backgroundError;
    private string? shortcutError;
    private bool stopping;
    internal MainWindow Window { get; }
    public event Action? Changed;

    internal AppController(ClipStore store, string dataDirectory,
        Func<ClipRecord, CancellationToken, Task<PreparedClipboardImage>>? prepareCopyImage = null,
        Action<PreparedClipboardImage?, string>? writeClipboard = null)
    {
        this.store = store;
        this.prepareCopyImage = prepareCopyImage ?? ((item, token) => Task.Run(() => ClipboardWriter.PrepareImage(ReadImage(item)), token));
        this.writeClipboard = writeClipboard ?? ((image, text) =>
        {
            if (image is not null) ClipboardWriter.CopyImage(image); else ClipboardWriter.CopyText(text);
        });
        dispatcher = Dispatcher.CurrentDispatcher;
        persistence = new LocalSettings(dataDirectory);
        settings = persistence.Load();
        session = new CaptureSession { Paused = settings.Paused, ExcludedProcesses = settings.ExcludedApplications };
        Window = new MainWindow(this);
        hotkey = new GlobalHotKey(ShowHistory);
        clipboard = new ClipboardMonitor(session, CaptureAsync);
        screenshots = new ScreenshotMonitor(session, CaptureAsync, dataDirectory);
        maintenance = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        maintenance.Tick += Maintain;
    }

    internal void Start()
    {
        dispatcher.VerifyAccess();
        try { hotkey.Register((uint)settings.HotKeyVirtualKey, (uint)settings.HotKeyModifiers); }
        catch (Exception error) { shortcutError = "Shortcut unavailable. Choose another in Settings. " + error.Message; }
        screenshots.Enabled = settings.ScreenshotsEnabled;
        try { screenshots.ConfigureFolder(settings.ScreenshotFolder); screenshots.Start(); }
        catch (Exception error) { backgroundError = "Screenshot capture: " + error.Message; }
        clipboard.StatusChanged += Notify;
        screenshots.StatusChanged += Notify;
        session.Changed += Notify;
        clipboard.Start();
        tray = new TrayService(ShowHistory, OpenSettings, TogglePause, RequestQuit);
        tray.SetPaused(settings.Paused);
        maintenance.Start();
        try { StartupService.SetEnabled(settings.StartAtLogin); persistence.Save(settings); }
        catch (Exception error) { backgroundError = "Startup settings: " + error.Message; Notify(); }
    }

    public string CaptureStatus
    {
        get
        {
            if (shortcutError is not null) return shortcutError;
            if (backgroundError is not null) return backgroundError;
            if (settings.Paused) return "Paused";
            string screenshot = screenshots.Status;
            if (settings.ScreenshotsEnabled && screenshot.Length > 0 &&
                !screenshot.StartsWith("Watching", StringComparison.OrdinalIgnoreCase) &&
                !screenshot.Contains("off", StringComparison.OrdinalIgnoreCase)) return screenshot;
            return clipboard.Status;
        }
    }

    internal void ShowHistory()
    {
        if (stopping) return;
        if (!dispatcher.CheckAccess()) { dispatcher.BeginInvoke(ShowHistory); return; }
        hotkey.RememberForeground();
        if (Window.IsVisible && Window.IsActive) Window.HideHistory(true);
        else Window.ShowHistory();
    }

    private void OpenSettings() { hotkey.RememberForeground(); Window.OpenSettings(); }
    private async void TogglePause()
    {
        try { await ChangeSettingsAsync(current => current with { Paused = !current.Paused }); }
        catch (Exception error) { MessageBox.Show(error.Message, "ClipDiary", MessageBoxButton.OK, MessageBoxImage.Warning); }
    }
    internal async void RequestQuit()
    {
        if (stopping) return;
        await DisposeAsync();
        Application.Current.Shutdown();
    }

    private void Notify()
    {
        if (stopping || dispatcher.HasShutdownStarted) return;
        if (!dispatcher.CheckAccess()) { dispatcher.BeginInvoke(Notify); return; }
        Changed?.Invoke();
    }

    private async void Maintain(object? sender, EventArgs args)
    {
        try { await store.RunAsync(s => s.Purge(), lifetime.Token); Notify(); }
        catch (OperationCanceledException) when (stopping) { }
        catch (Exception error) { backgroundError = "History cleanup: " + error.Message; Notify(); }
    }

    private async Task<bool> CaptureAsync(ClipboardPayload item, CancellationToken cancellationToken)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lifetime.Token);
        var saved = await store.RunAsync(s => item.IsImage
            ? s.AddImage(item.ImageData!, item.ThumbnailData ?? throw new InvalidDataException("Image preview is missing."),
                item.Extension, item.Title, item.Source, item.CapturedAt, deduplicate: !item.IsFileScreenshot)
            : s.AddText(item.Text ?? "", item.Source, item.CapturedAt), linked.Token).ConfigureAwait(false);
        if (saved is not null) { backgroundError = null; Notify(); return true; }
        return false;
    }

    public async Task<IReadOnlyList<ClipRecord>> GetRecordsAsync(string query, bool snippets, ClipKind? kind,
        CancellationToken cancellationToken = default)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lifetime.Token);
        return await store.RunAsync(s => s.Records(query, snippets, kind, 4096, linked.Token).Reverse().ToArray(), linked.Token);
    }

    public Task<ClipRecord?> GetRecordAsync(string id) => store.RunAsync(s => s.Record(id), lifetime.Token);

    private CancellationTokenSource BeginCopy()
    {
        lock (copyCancellationGate)
        {
            if (stopping) throw new OperationCanceledException("ClipDiary is shutting down.");
            return CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, pendingCopies.Token);
        }
    }
    private void InvalidatePendingCopies()
    {
        CancellationTokenSource old;
        lock (copyCancellationGate)
        {
            old = pendingCopies;
            pendingCopies = new CancellationTokenSource();
        }
        old.Cancel(); old.Dispose();
    }
    private static bool SameCopySource(ClipRecord expected, ClipRecord? current) => current is not null &&
        current.Kind == expected.Kind && current.Text == expected.Text && current.Source == expected.Source &&
        current.IsParameterized == expected.IsParameterized && current.IsSnippet == expected.IsSnippet &&
        current.AssetPath == expected.AssetPath && current.ThumbnailPath == expected.ThumbnailPath;

    public async Task CopyAsync(string id, IReadOnlyDictionary<string, string>? values = null)
    {
        // Capture the epoch before waiting: deletion/clear must invalidate queued copies too.
        using var operation = BeginCopy();
        var token = operation.Token;
        await copying.WaitAsync(token);
        try
        {
            var item = await store.RunAsync(s => s.Record(id), token) ?? throw new ClipStoreException("This item has expired or was removed.");
            var text = item.Kind == ClipKind.Text && item.IsSnippet && item.IsParameterized
                ? SnippetParameters.Render(item.Text ?? "", values) : item.Text ?? "";
            PreparedClipboardImage? image = item.Kind == ClipKind.Image
                ? await prepareCopyImage(item, token) : null;
            token.ThrowIfCancellationRequested();
            var current = await store.RunAsync(s => s.Record(item.Id), token);
            if (!SameCopySource(item, current)) throw new ClipStoreException("The original item changed or was removed during copying.");
            await dispatcher.InvokeAsync(() =>
            {
                token.ThrowIfCancellationRequested();
                if (item.ExpiresAt is { } expiry && expiry <= DateTimeOffset.UtcNow)
                    throw new ClipStoreException("This item expired while its copy was being prepared.");
                session.InvalidatePending();
                writeClipboard(image, text);
                clipboard.MarkOwnWrite();
            }, DispatcherPriority.Normal, token);
            try
            {
                await store.RunAsync(s =>
                {
                    if (!SameCopySource(item, s.Record(item.Id)))
                        throw new ClipStoreException("The original item changed or was removed during copying.");
                    return s.Recopy(item.Id, values);
                }, token);
            }
            catch (Exception error)
            { throw new ClipStoreException("Copied successfully, but its history update could not be saved. You can still paste it. " + error.Message, error); }
            backgroundError = null; Notify();
        }
        finally { copying.Release(); }
    }

    private byte[] ReadImage(ClipRecord item)
    {
        string? path = item.AssetPath;
        if (path is null) throw new ClipStoreException("The saved image is missing.");
        if (!string.Equals(Path.GetFullPath(Path.GetDirectoryName(path)!), Path.Combine(store.DirectoryPath, "Assets"), StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(Path.GetFileNameWithoutExtension(path), item.Id, StringComparison.OrdinalIgnoreCase))
            throw new ClipStoreException("The saved image is outside ClipDiary's owned assets.");
        LocalFiles.ValidatePath(path);
        var root = LocalFiles.DirectoryIdentity(Path.GetDirectoryName(path)!);
        return LocalFiles.ReadStable(path, LocalFiles.FileIdentity(path), root.Key);
    }

    private async Task Mutate(Action<ClipStore> action)
    { await store.RunAsync(action, lifetime.Token); backgroundError = null; Notify(); }
    public Task SaveSnippetAsync(string id) => Mutate(s => s.SaveSnippet(id));
    public Task UpsertSnippetAsync(string? id, string title, string text, bool parameterized)
    {
        if (id is not null) InvalidatePendingCopies();
        return Mutate(s =>
    {
        if (id is null) s.CreateSnippet(title, text);
        else
        {
            var item = s.Record(id) ?? throw new ClipStoreException("This snippet was removed.");
            s.UpdateSnippet(id, title, item.Kind == ClipKind.Image ? null : text, item.Kind == ClipKind.Text && parameterized);
        }
    });
    }
    public Task SetParameterizedAsync(string id, bool enabled) { InvalidatePendingCopies(); return Mutate(s => s.SetParameterized(id, enabled)); }
    public Task DeleteAsync(string id) { InvalidatePendingCopies(); session.ForgetRecentImages(); return Mutate(s => s.Delete(id)); }
    public Task ClearHistoryAsync() { InvalidatePendingCopies(); session.InvalidatePending(); return Mutate(s => s.ClearHistory()); }
    public Task DeleteAllAsync() { InvalidatePendingCopies(); session.InvalidatePending(); return Mutate(s => s.DeleteAll()); }

    public Task<UiSettings> GetSettingsAsync() => Task.FromResult(settings with { ExcludedApplications = settings.ExcludedApplications.ToArray() });
    public Task ApplySettingsAsync(UiSettings requested) => ChangeSettingsAsync(_ => requested);
    private async Task ChangeSettingsAsync(Func<UiSettings, UiSettings> change)
    {
        dispatcher.VerifyAccess();
        await changingSettings.WaitAsync(lifetime.Token);
        try
        {
        var next = LocalSettings.Validate(change(settings));
        var old = settings;
        try
        {
            hotkey.Register((uint)next.HotKeyVirtualKey, (uint)next.HotKeyModifiers);
            screenshots.Enabled = next.ScreenshotsEnabled;
            screenshots.ConfigureFolder(next.ScreenshotFolder);
            StartupService.SetEnabled(next.StartAtLogin);
            await Task.Run(() => persistence.Save(next), lifetime.Token);
            session.Paused = next.Paused; session.ExcludedProcesses = next.ExcludedApplications;
            settings = next; tray?.SetPaused(next.Paused); backgroundError = null; shortcutError = null; Notify();
        }
        catch
        {
            // Restore the last working settings if any native registration or durable save fails.
            try { hotkey.Register((uint)old.HotKeyVirtualKey, (uint)old.HotKeyModifiers); }
            catch (Exception error) { shortcutError = "Shortcut unavailable. Choose another in Settings. " + error.Message; }
            try { screenshots.Enabled = old.ScreenshotsEnabled; screenshots.ConfigureFolder(old.ScreenshotFolder); } catch { }
            try { StartupService.SetEnabled(old.StartAtLogin); } catch { }
            throw;
        }
        }
        finally { changingSettings.Release(); }
    }

    public void RestorePreviousApplication() => hotkey.RestoreForeground();
    public async ValueTask DisposeAsync()
    {
        if (stopping) return;
        stopping = true; InvalidatePendingCopies(); maintenance.Stop(); lifetime.Cancel(); session.InvalidatePending();
        // Let an in-progress settings save complete/roll back before releasing native registrations.
        await changingSettings.WaitAsync();
        try { clipboard.Dispose(); await screenshots.DisposeAsync(); hotkey.Dispose(); tray?.Dispose(); session.Dispose(); }
        finally { changingSettings.Release(); }
        Window.AllowClose = true; Window.Close();
        await Task.Run(store.Dispose);
        lock (copyCancellationGate) pendingCopies.Dispose();
        lifetime.Dispose();
    }
}
