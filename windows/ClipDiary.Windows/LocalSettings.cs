using System.Text.Json;
using ClipDiary.Windows.UI;

namespace ClipDiary.Windows;

internal sealed class LocalSettings(string directory)
{
    private const int MaximumBytes = 64 * 1024;
    private readonly string path = Path.Combine(directory, "settings.json");
    internal bool Exists => File.Exists(path);
    internal static UiSettings Default => new(true, false,
        ["1Password", "Bitwarden", "KeePass", "KeePassXC", "CredentialUIBroker"], 0x44, 3, null, true);

    internal UiSettings Load()
    {
        if (!Exists) return Default;
        RejectLink(path);
        if (new FileInfo(path).Length > MaximumBytes)
            throw new InvalidDataException("The settings file is too large. Your history has not been reset.");
        return Validate(JsonSerializer.Deserialize<UiSettings>(File.ReadAllText(path))
            ?? throw new InvalidDataException("Settings could not be read. Your history has not been reset."));
    }

    internal void Save(UiSettings settings)
    {
        settings = Validate(settings);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(settings, new JsonSerializerOptions { WriteIndented = true });
        if (bytes.Length > MaximumBytes)
            throw new InvalidDataException("Settings exceed the 64 KiB limit. Shorten the exclusion list or folder path; existing settings have not been changed.");
        RejectLink(path);
        var temporary = Path.Combine(directory, $"settings-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { stream.Write(bytes); stream.Flush(true); }
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    internal static UiSettings Validate(UiSettings settings)
    {
        if (settings.HotKeyVirtualKey is < 1 or > 254 || settings.HotKeyModifiers is < 1 or > 15)
            throw new InvalidDataException("Choose a shortcut with Ctrl, Alt, Shift or Windows and a regular key.");
        if (settings.ExcludedApplications is null || settings.ExcludedApplications.Length > 256 ||
            settings.ExcludedApplications.Any(p => p is null || p.Length > 512))
            throw new InvalidDataException("The application exclusion list is too large.");
        var folder = string.IsNullOrWhiteSpace(settings.ScreenshotFolder) ? null : Path.GetFullPath(settings.ScreenshotFolder);
        return settings with { ScreenshotFolder = folder, ExcludedApplications = settings.ExcludedApplications.ToArray() };
    }

    private static void RejectLink(string file)
    {
        var info = new FileInfo(file);
        if (info.LinkTarget is not null || info.Exists && (info.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("Settings cannot be a symbolic link or reparse point.");
    }
}
