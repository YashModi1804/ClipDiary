using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace ClipDiary.Windows.Platform;

// This file deliberately has no Windows desktop references; link it into portable checks.
public static class CapturePolicy
{
    public const int MaximumImageBytes = 25 * 1024 * 1024;
    public const long MaximumPixels = 50_000_000;
    public const int MaximumTextBytes = 1024 * 1024;
    public static readonly TimeSpan Retention = TimeSpan.FromHours(96);
    public static bool IsLocallyAvailableCloudItem(uint attributes, uint state) =>
        (attributes & (0x1000u | 0x40000u | 0x400000u)) == 0 && state != uint.MaxValue && (state & 3u) != 0 && (state & 0x30u) == 0;
    public static bool ValidDimensions(int width, int height) => width > 0 && height > 0 && (long)width <= MaximumPixels / height;
    public static bool EligibleScreenshot(DateTimeOffset created, DateTimeOffset baseline, DateTimeOffset now) => created > baseline && created <= now && now - created < Retention;
    public static string NormalizeProcess(string value)
    {
        string name = value.Trim().Replace('\\', '/');
        name = name[(name.LastIndexOf('/') + 1)..];
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
        return name.ToLowerInvariant();
    }
    public static bool ValidText(string value) => !string.IsNullOrWhiteSpace(value) && Encoding.UTF8.GetByteCount(value) <= MaximumTextBytes;
    public static bool IsImagePath(string path) => new[] { ".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);
    public static TimeSpan RetryDelay(int failures) => TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, Math.Clamp(failures - 1, 0, 5))));
    public static bool IsPngComplete(ReadOnlySpan<byte> data)
    {
        ReadOnlySpan<byte> signature = [137, 80, 78, 71, 13, 10, 26, 10];
        ReadOnlySpan<byte> end = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
        return !data.StartsWith(signature) || data.EndsWith(end);
    }
}

public sealed record ClipboardPayload
{
    public string? Text { get; init; }
    public byte[]? ImageData { get; init; }
    public byte[]? ThumbnailData { get; init; }
    public string Extension { get; init; } = ".png";
    public string Title { get; init; } = "";
    public string Source { get; init; } = "Unknown application";
    public DateTimeOffset CapturedAt { get; init; } = DateTimeOffset.UtcNow;
    public string Digest { get; init; } = "";
    public bool IsFileScreenshot { get; init; }
    public bool IsImage => ImageData is not null;
}
