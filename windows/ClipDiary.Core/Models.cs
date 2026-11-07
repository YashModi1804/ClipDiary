namespace ClipDiary.Core;

public enum ClipKind { Text, Image }
public sealed record ClipRecord(string Id, ClipKind Kind, string? Text, string Title,
    DateTimeOffset CapturedAt, DateTimeOffset? ExpiresAt, string Source, bool IsSnippet,
    string? AssetPath, string? ThumbnailPath, long ByteCount, bool IsParameterized = false);
public sealed record ClipStats(int HistoryCount, int SnippetCount, long Bytes);
public sealed class ClipStoreException(string message, Exception? inner = null) : Exception(message, inner);
