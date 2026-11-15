using System;
using System.IO;
using System.IO.Compression;
using System.Text;

namespace Bubilator88.Windows;

internal enum BlankDiskType { TwoD = 0x00, TwoDD = 0x10, TwoHD = 0x20 }
internal readonly record struct CreatedBlankDisk(string Path, int Drive);

/// <summary>Creates disks from templates produced by the pinned Swift core's formatter.
/// Only the disk name changes; geometry, sector layout and BASIC FAT stay core-owned.</summary>
internal static class BlankDiskCreation
{
    private static readonly Encoding DiskNameEncoding = CodePagesEncodingProvider.Instance.GetEncoding(
        932, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback)!;

    public static byte[] CreateImage(BlankDiskType type, string name, bool initializeBasic)
    {
        string label = type switch
        {
            BlankDiskType.TwoD => "2D",
            BlankDiskType.TwoDD => "2DD",
            BlankDiskType.TwoHD => "2HD",
            _ => throw new ArgumentOutOfRangeException(nameof(type)),
        };
        string resource = $"Bubilator88.BlankDisks.{label}-{(initializeBasic ? "basic" : "erased")}.d88.gz";
        using var stream = typeof(BlankDiskCreation).Assembly.GetManifestResourceStream(resource)
            ?? throw new FileNotFoundException("The blank disk template is missing.", resource);
        using var gzip = new GZipStream(stream, CompressionMode.Decompress);
        using var output = new MemoryStream();
        gzip.CopyTo(output);
        byte[] image = output.ToArray();
        byte[] encoded;
        try { encoded = DiskNameEncoding.GetBytes(name); }
        catch (EncoderFallbackException) { encoded = Encoding.UTF8.GetBytes(name); }
        // Match D88Disk.serialize: at most 16 encoded bytes, followed by a NUL.
        encoded.AsSpan(0, Math.Min(16, encoded.Length)).CopyTo(image);
        return image;
    }

    /// <summary>Persists and selects the first empty drive, then drive 1.
    /// A mounted source cannot be overwritten while the machine still owns its contents.</summary>
    public static CreatedBlankDisk Save(string path, BlankDiskType type, bool initializeBasic, DriveSlot[] slots)
    {
        path = Path.GetFullPath(path);
        foreach (var slot in slots)
            if (slot.Occupied && slot.SourcePath is string source &&
                IsSameSource(source, path))
                throw new IOException("This file is mounted. Choose a different name or eject it first.");

        byte[] image = CreateImage(type, Path.GetFileNameWithoutExtension(path), initializeBasic);
        AtomicStateFile.Write(path, image);
        int drive = !slots[0].Occupied ? 0 : !slots[1].Occupied ? 1 : 0;
        return new CreatedBlankDisk(path, drive);
    }

    private static bool IsSameSource(string source, string destination)
    {
        try { return string.Equals(Path.GetFullPath(source), destination, StringComparison.OrdinalIgnoreCase); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            // A restored state's path may be invalid on Windows. It cannot be this valid destination.
            return false;
        }
    }
}
