using System;
using System.Collections.Generic;
using System.IO;

namespace Bubilator88.Windows;

/// <summary>Selects the same rhythm assets as macOS; WAV decoding stays in the core.</summary>
internal static class RhythmSampleFiles
{
    // Order is the core's instrument index: BD, SD, TOP, HH, TOM, RIM.
    private static readonly string[] Names = { "BD", "SD", "TOP", "HH", "TOM", "RIM" };

    public static IEnumerable<(int Index, byte[] Data)> Load(string directory)
    {
        for (int index = 0; index < Names.Length; index++)
        {
            // The existing C ABI returns void on invalid WAVs. Install the
            // fallback first so a rejected user sample leaves it intact.
            if (Read(DeploymentFiles.Find($"Rhythm_{Names[index]}.wav")) is byte[] bundled)
                yield return (index, bundled);
            if (Read(Path.Combine(directory, $"2608_{Names[index]}.WAV")) is byte[] user)
                yield return (index, user);
        }
    }

    private static byte[]? Read(string? path)
    {
        if (path is null) return null;
        try { return File.ReadAllBytes(path); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
}
