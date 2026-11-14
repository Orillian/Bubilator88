using System;
using System.IO;

namespace Bubilator88.Windows;

/// <summary>Native media transactions, isolated from rendering/audio services so
/// the same implementation can be exercised against the real Core DLL.</summary>
internal sealed unsafe partial class EmulatorHost
{
    /// <summary>Mount a D88 image. Returns image count in the blob.</summary>
    public int MountDisk(int drive, byte[] d88, int imageIndex = 0)
    {
        lock (SyncRoot)
            fixed (byte* p = d88)
                return NativeApi.b88_mount_disk(_handle, drive, p, d88.Length, imageIndex);
    }

    /// <summary>Publishes a mounted image and its write protection as one
    /// transaction; the real-time loop cannot observe an unprotected image.</summary>
    public int MountDiskProtected(int drive, byte[] d88, int imageIndex, bool writeProtected)
    {
        lock (SyncRoot)
        {
            fixed (byte* input = d88)
                return NativeApi.b88_mount_disk_protected(_handle, drive, input, d88.Length, imageIndex, writeProtected ? 1 : 0);
        }
    }

    /// <summary>Per-image metadata returned by <see cref="ProbeDisk"/>.</summary>
    public readonly record struct ImageInfo(string Name, string Type, bool WriteProtected);

    /// <summary>
    /// Probe a (multi-image) D88 blob without mounting. Returns the image count
    /// and per-image metadata (embedded name, disk type label, write-protect).
    /// </summary>
    public int ProbeDisk(byte[] d88, out ImageInfo[] images)
    {
        const int Cap = 8192;
        byte* o = stackalloc byte[Cap];
        int count;
        fixed (byte* p = d88)
            count = NativeApi.b88_d88_probe(p, d88.Length, o, Cap);

        if (count <= 0)
        {
            images = Array.Empty<ImageInfo>();
            return count;
        }
        int end = 0;
        while (end < Cap && o[end] != 0) end++;
        string joined = end > 0 ? System.Text.Encoding.UTF8.GetString(o, end) : "";
        string[] lines = joined.Length > 0 ? joined.Split('\n') : Array.Empty<string>();

        images = new ImageInfo[count];
        for (int i = 0; i < count; i++)
        {
            string name = "", type = "2D";
            bool wp = false;
            if (i < lines.Length)
            {
                string[] f = lines[i].Split('\t');
                if (f.Length > 0) name = f[0];
                if (f.Length > 1) type = TypeLabel(f[1]);
                if (f.Length > 2) wp = f[2] == "1";
            }
            images[i] = new ImageInfo(name, type, wp);
        }
        return count;
    }

    private static string TypeLabel(string raw) => raw switch
    {
        "16" => "2DD",
        "32" => "2HD",
        _ => "2D",
    };

    public void EjectDisk(int drive) { lock (SyncRoot) NativeApi.b88_eject_disk(_handle, drive); }

    public void SetWriteProtect(int drive, bool protectedFlag)
    {
        lock (SyncRoot) NativeApi.b88_set_write_protect(_handle, drive, protectedFlag ? 1 : 0);
    }

    /// <summary>
    /// Capture the current machine state as a .b88s blob (CPU, bus, sound,
    /// sub-system, mounted disk images). Mirrors macOS Machine.createSaveState.
    /// </summary>
    public byte[] SaveState()
    {
        lock (SyncRoot) return SaveStateLocked();
    }

    private byte[] SaveStateLocked()
    {
        int len = NativeApi.b88_save_state(_handle);
        return ReadSavedState(len);
    }

    public byte[] SaveState(WinSaveMeta metadata, byte[] thumbnail)
    {
        byte[] extra = StateSections.MetadataSection(metadata);
        lock (SyncRoot)
        {
            fixed (byte* thumb = thumbnail)
            fixed (byte* sections = extra)
                return ReadSavedState(NativeApi.b88_save_state_ex(_handle, thumb, thumbnail.Length, sections, extra.Length));
        }
    }

    private byte[] ReadSavedState(int len)
    {
        if (len <= 0) return Array.Empty<byte>();
        var blob = new byte[len];
        fixed (byte* p = blob)
        {
            int n = NativeApi.b88_save_state_read(_handle, p, len);
            if (n != len) Array.Resize(ref blob, n < 0 ? 0 : n);
        }
        return blob;
    }

    /// <summary>Restore machine state from a .b88s blob. Returns false on failure.</summary>
    public bool LoadState(byte[] blob)
    {
        if (blob is null || blob.Length == 0) return false;
        lock (SyncRoot)
            fixed (byte* p = blob)
                return NativeApi.b88_load_state(_handle, p, blob.Length) != 0;
    }

    public bool HasDisk(int drive)
    {
        lock (SyncRoot) return NativeApi.b88_disk_name(_handle, drive, null, 0) >= 0;
    }

    public bool IsWriteProtected(int drive)
    {
        lock (SyncRoot) return NativeApi.b88_is_write_protected(_handle, drive) != 0;
    }

    public string DiskName(int drive)
    {
        lock (SyncRoot)
        {
            int length = NativeApi.b88_disk_name(_handle, drive, null, 0);
            if (length <= 0) return "";
            var bytes = new byte[length + 1];
            fixed (byte* output = bytes) NativeApi.b88_disk_name(_handle, drive, output, bytes.Length);
            return System.Text.Encoding.UTF8.GetString(bytes, 0, length);
        }
    }
}
