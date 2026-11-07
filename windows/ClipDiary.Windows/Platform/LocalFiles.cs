using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ClipDiary.Windows.Platform;

internal static class LocalFiles
{
    internal sealed record Identity(string Key, long Length, DateTimeOffset Created, DateTimeOffset Modified);
    internal static string ValidatePath(string path)
    {
        string full = Path.GetFullPath(path);
        string root = Path.GetPathRoot(full) ?? throw new IOException("Invalid local path.");
        if (root.StartsWith(@"\\", StringComparison.Ordinal) || new DriveInfo(root).DriveType == DriveType.Network) throw new IOException("Choose a local folder; network shares are not monitored.");
        // Validate ancestors before traversing descendants: a local junction must
        // never cause a network lookup before it is rejected.
        string current = root;
        foreach (string segment in full[root.Length..].Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            FileAttributes attributes;
            try { attributes = File.GetAttributes(current); }
            catch (FileNotFoundException) { break; }
            catch (DirectoryNotFoundException) { break; }
            if ((attributes & FileAttributes.ReparsePoint) == 0) continue;
            FileSystemInfo entry = (attributes & FileAttributes.Directory) != 0 ? new DirectoryInfo(current) : new FileInfo(current);
            if (entry.LinkTarget is not null || !SafeCloudPath(current)) throw new IOException("Linked or online-only folders are not monitored. Choose the local physical folder.");
        }
        return full;
    }
    internal static Identity DirectoryIdentity(string path)
    {
        ValidatePath(path);
        using var handle = Open(path);
        var info = Info(handle);
        if ((info.Attributes & 0x10) == 0 || !SafeReparse(handle, info.Attributes)) throw new IOException("Screenshot folder is not a regular local directory.");
        return Convert(info);
    }
    internal static Identity FileIdentity(string path)
    {
        ValidatePath(path);
        using var handle = Open(path);
        var info = Info(handle);
        if ((info.Attributes & 0x10u) != 0 || !SafeReparse(handle, info.Attributes)) throw new IOException("Linked, placeholder or nonregular image skipped.");
        return Convert(info);
    }
    internal static byte[] ReadStable(string path, Identity expected, string rootIdentity)
    {
        if (DirectoryIdentity(Path.GetDirectoryName(path)!).Key != rootIdentity) throw new IOException("Screenshot folder was moved or replaced. Choose it again.");
        using var handle = Open(path);
        var before = Info(handle);
        var identity = Convert(before);
        if ((before.Attributes & 0x10u) != 0 || !SafeReparse(handle, before.Attributes) || identity != expected || identity.Length <= 0 || identity.Length > CapturePolicy.MaximumImageBytes) throw new IOException("Screenshot changed while being read; retrying.");
        var canonical = FinalPath(handle);
        if (DirectoryIdentity(Path.GetDirectoryName(canonical)!).Key != rootIdentity) throw new IOException("Image is outside the selected screenshot directory.");
        var data = new byte[checked((int)identity.Length)];
        using (var stream = new FileStream(handle, FileAccess.Read)) stream.ReadExactly(data);
        // FileStream owns the handle. Reopen only for identity verification; replacement cannot substitute captured bytes.
        if (FileIdentity(path) != expected || DirectoryIdentity(Path.GetDirectoryName(path)!).Key != rootIdentity) throw new IOException("Screenshot changed while being read; retrying.");
        return data;
    }
    private static bool SafeCloudPath(string path)
    {
        using var handle = Open(path);
        return SafeReparse(handle, Info(handle).Attributes);
    }
    private static bool SafeReparse(SafeFileHandle handle, uint attributes)
    {
        if ((attributes & (0x1000u | 0x40000u | 0x400000u)) != 0) return false;
        if ((attributes & 0x400u) == 0) return true;
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 16299) || !GetFileInformationByHandleEx(handle, 9, out var tag, (uint)Marshal.SizeOf<AttributeTag>())) return false;
        uint state = CfGetPlaceholderStateFromAttributeTag(tag.Attributes, tag.Tag);
        return CapturePolicy.IsLocallyAvailableCloudItem(tag.Attributes, state);
    }
    [StructLayout(LayoutKind.Sequential)] private struct AttributeTag { public uint Attributes, Tag; }
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out AttributeTag info, uint size);
    [DllImport("cfapi.dll")] private static extern uint CfGetPlaceholderStateFromAttributeTag(uint attributes, uint tag);
    private static SafeFileHandle Open(string path)
    {
        string root = Path.GetPathRoot(Path.GetFullPath(path)) ?? "";
        if (root.StartsWith(@"\\", StringComparison.Ordinal) || new DriveInfo(root).DriveType == DriveType.Network) throw new IOException("Network paths are not captured.");
        var handle = CreateFile(path, 0x80000000, 7, 0, 3, 0x00200000 | 0x02000000 | 0x00100000, 0);
        if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
        return handle;
    }
    private static ByHandleInfo Info(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return info;
    }
    private static Identity Convert(ByHandleInfo info)
    {
        long created = ((long)info.Created.High << 32) | info.Created.Low;
        long modified = ((long)info.Modified.High << 32) | info.Modified.Low;
        string key = $"{info.Volume:X8}:{info.IndexHigh:X8}{info.IndexLow:X8}:{created:X16}";
        return new Identity(key, ((long)info.SizeHigh << 32) | info.SizeLow, DateTimeOffset.FromFileTime(created), DateTimeOffset.FromFileTime(modified));
    }
    private static string FinalPath(SafeFileHandle handle)
    {
        var builder = new StringBuilder(32768);
        uint size = GetFinalPathNameByHandle(handle, builder, (uint)builder.Capacity, 0);
        if (size == 0 || size >= builder.Capacity) throw new IOException("Cannot validate the image path.");
        string value = builder.ToString();
        if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) throw new IOException("Network images are not captured.");
        return value.StartsWith(@"\\?\", StringComparison.Ordinal) ? value[4..] : value;
    }
    [StructLayout(LayoutKind.Sequential)] private struct FileTime { internal uint Low, High; }
    [StructLayout(LayoutKind.Sequential)] private struct ByHandleInfo
    {
        internal uint Attributes; internal FileTime Created, Accessed, Modified;
        internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFile(string path, uint access, uint share, nint security, uint disposition, uint flags, nint template);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleInfo info);
    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
}
