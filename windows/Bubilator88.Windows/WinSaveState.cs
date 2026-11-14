using System;
using System.IO;

namespace Bubilator88.Windows;

/// <summary>
/// Host-side state used by normal UI and automation commands. New files encode
/// it using the macOS AMTA schema; the old Windows JSON shape is read only for
/// backward compatibility with sidecars.
/// </summary>
internal sealed class WinSaveMeta
{
    public int BootModeIndex { get; set; }      // 0=N88-V2 1=V1H 2=V1S 3=N-BASIC
    public bool Clock8MHz { get; set; } = true;

    // Monitor the machine was running on (0=15kHz 1=24kHz). Unlike the DIP
    // switches it travels with the state: the restored CRTC geometry was
    // programmed for this monitor, and pairing it with the other one gives a
    // frame rate no real machine has. Null in states written before it was
    // added — those were all 24kHz (mirrors the macOS SaveMeta.monitorType).
    public int? MonitorType { get; set; }

    // Memory wait DIP (SW1-6) the state was captured under. Like the clock it
    // only changes the speed, so it travels with the state. Null in older
    // states, which keep the current setting (mirrors macOS SaveMeta.memoryWaitDip).
    public bool? MemoryWaitDip { get; set; }

    public DriveMeta? Drive0 { get; set; }
    public DriveMeta? Drive1 { get; set; }

    internal sealed class DriveMeta
    {
        public string FileName { get; set; } = "";
        public string[] ImageNames { get; set; } = Array.Empty<string>();
        public int ImageCount { get; set; }
        public int CurrentImage { get; set; }
        public bool WriteProtected { get; set; }
        public string? SourcePath { get; set; }   // re-read for multi-image switching
    }
}

/// <summary>
/// Resolves save slots and reads embedded metadata/previews with legacy sidecar
/// fallbacks. New writes use one .b88s file with AMTA and THMB, as on macOS.
/// Slot −1 is the quick-save; slots 0..9 are the numbered save-state slots.
/// </summary>
internal static class WinSaveState
{
    public const int SlotCount = 10;

    public static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Bubilator88", "SaveStates");

    private static string Base(int slot) => slot < 0 ? "quicksave" : $"slot_{slot}";

    public static string StatePath(int slot) => Path.Combine(Dir, Base(slot) + ".b88s");
    public static string MetaPath(int slot) => Path.Combine(Dir, Base(slot) + ".meta.json");
    public static string ThumbPath(int slot) => Path.Combine(Dir, Base(slot) + ".thumb.png");

    public static bool Exists(int slot) => File.Exists(StatePath(slot));

    public static DateTime? ModifiedAt(int slot)
    {
        try { return Exists(slot) ? File.GetLastWriteTime(StatePath(slot)) : null; }
        catch { return null; }
    }

    public static (WinSaveMeta? Metadata, byte[]? Thumbnail) ReadPreview(int slot)
    {
        try
        {
            string path = StatePath(slot);
            byte[] blob = File.ReadAllBytes(path);
            return (StateSections.ReadMetadata(blob, path), StateSections.ReadThumbnail(blob, path));
        }
        catch { return (null, null); }
    }
}
