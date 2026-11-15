using System;
using System.Buffers.Binary;
using System.IO;
using System.Linq;

namespace Bubilator88.Windows;

/// <summary>D88 bank splicing and atomic write-through, matching macOS DiskWriteBackIO.</summary>
internal static class DiskWriteBackIO
{
    /// <summary>Replaces only the selected bank, preserving banks owned by the other drive.</summary>
    public static byte[] ReplaceBank(byte[] original, int index, byte[] bank)
    {
        if (index < 0) throw new ArgumentOutOfRangeException(nameof(index));
        int start = 0;
        for (int i = 0; i < index; i++) start += BankSize(original, start);
        int end = start + BankSize(original, start);
        var merged = new byte[checked(original.Length - (end - start) + bank.Length)];
        original.AsSpan(0, start).CopyTo(merged);
        bank.CopyTo(merged, start);
        original.AsSpan(end).CopyTo(merged.AsSpan(start + bank.Length));
        return merged;
    }

    private static int BankSize(byte[] bytes, int offset)
    {
        if (offset < 0 || offset > bytes.Length - 0x20)
            throw new InvalidDataException("D88 bank header is out of range.");
        uint size = BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset + 0x1c));
        if (size < 0x20 || size > bytes.Length - offset)
            throw new InvalidDataException("Invalid D88 bank size.");
        return (int)size;
    }

    /// <summary>Reads the latest file on every write. Creation must be explicitly allowed
    /// for a standalone image; a missing multi-bank file must never become one bank.</summary>
    public static byte[] WriteBank(string path, int index, byte[] bank, bool allowCreate = false)
    {
        byte[] merged;
        try { merged = ReplaceBank(File.ReadAllBytes(path), index, bank); }
        catch (FileNotFoundException) when (allowCreate && index == 0) { merged = bank; }
        AtomicStateFile.Write(path, merged);
        return merged;
    }

    public static string DefaultRecoveryDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Bubilator88", "ModifiedDisks");

    /// <summary>Saves a standalone bank without overwriting earlier recovery copies.</summary>
    public static string WriteRecovery(string directory, string name, int drive, byte[] bank)
    {
        Directory.CreateDirectory(directory);
        char[] invalid = Path.GetInvalidFileNameChars();
        string safe = new(name.Select(c => invalid.Contains(c) ? '_' : c).ToArray());
        string path = Path.Combine(directory, $"{safe}-drive{drive}-{DateTime.UtcNow:yyyyMMddTHHmmssfff}-{Guid.NewGuid():N}.d88");
        AtomicStateFile.Write(path, bank);
        return path;
    }
}
