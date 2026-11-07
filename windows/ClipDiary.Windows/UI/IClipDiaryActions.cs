using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Threading;
using ClipDiary.Core;

namespace ClipDiary.Windows.UI;

/// <summary>All persistence and clipboard work runs asynchronously behind this boundary.</summary>
public interface IClipDiaryActions
{
    event Action? Changed;
    string CaptureStatus { get; }
    Task<IReadOnlyList<ClipRecord>> GetRecordsAsync(string query, bool snippets, ClipKind? kind, CancellationToken cancellationToken = default);
    Task<ClipRecord?> GetRecordAsync(string id);
    Task CopyAsync(string id, IReadOnlyDictionary<string, string>? values = null);
    Task SaveSnippetAsync(string id);
    Task UpsertSnippetAsync(string? id, string title, string text, bool parameterized);
    Task SetParameterizedAsync(string id, bool enabled);
    Task DeleteAsync(string id);
    Task ClearHistoryAsync();
    Task DeleteAllAsync();
    Task<UiSettings> GetSettingsAsync();
    Task ApplySettingsAsync(UiSettings settings);
    void RestorePreviousApplication();
}

public sealed record UiSettings(
    bool StartAtLogin,
    bool Paused,
    string[] ExcludedApplications,
    int HotKeyVirtualKey,
    int HotKeyModifiers,
    string? ScreenshotFolder,
    bool ScreenshotsEnabled = true);
