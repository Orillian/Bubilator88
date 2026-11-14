using System;
using System.IO;

namespace Bubilator88.Windows;

/// <summary>Mounted-disk state. Retains bytes for image switching without
/// re-reading the file, and display metadata for save-state reconstruction.</summary>
internal sealed class DriveSlot
{
    public byte[]? Bytes;
    public string FileName = ""; // Display base name, without the file extension.
    public string[] ImageNames = Array.Empty<string>();
    public EmulatorHost.ImageInfo[] Images = Array.Empty<EmulatorHost.ImageInfo>();
    public int ImageCount;
    public int CurrentImage;
    public bool WriteProtected;
    public string? SourcePath;
    public bool Occupied => Bytes != null;

    /// <summary>Initializes a mounted file, removing its extension once and
    /// retaining requested protection on the selected image for later switches.</summary>
    public void Fill(byte[] bytes, string name, EmulatorHost.ImageInfo[] images, int current, string? sourcePath,
        bool writeProtected = false)
    {
        string fileBase = Path.GetFileNameWithoutExtension(name);
        Bytes = bytes;
        FileName = fileBase;
        Images = (EmulatorHost.ImageInfo[])images.Clone();
        if (current >= 0 && current < Images.Length && writeProtected)
            Images[current] = Images[current] with { WriteProtected = true };
        ImageCount = images.Length;
        ImageNames = new string[images.Length];
        for (int i = 0; i < images.Length; i++)
        {
            string imageName = images[i].Name.Trim();
            ImageNames[i] = imageName.Length > 0 ? imageName :
                (images.Length > 1 ? $"{fileBase} #{i}" : fileBase);
        }
        CurrentImage = current;
        WriteProtected = current >= 0 && current < Images.Length && Images[current].WriteProtected;
        SourcePath = sourcePath;
    }

    /// <summary>Changes only the active image; file identity and display names
    /// remain those established when the file was mounted.</summary>
    public void SelectImage(int index)
    {
        if (index < 0 || index >= Images.Length) throw new ArgumentOutOfRangeException(nameof(index));
        CurrentImage = index;
        WriteProtected = Images[index].WriteProtected;
    }
}
