using System;
using System.IO;

namespace Bubilator88.Windows;

internal static class AtomicStateFile
{
    public static void Write(string path, byte[] bytes) => Write(path, stream => stream.Write(bytes));

    /// <summary>Writes and flushes a sibling temporary file before replacing
    /// the destination. A failed write never truncates an existing save.</summary>
    internal static void Write(string path, Action<Stream> write)
    {
        path = Path.GetFullPath(path);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { write(stream); stream.Flush(flushToDisk: true); }
            if (File.Exists(path)) File.Replace(temporary, path, destinationBackupFileName: null);
            else File.Move(temporary, path);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
