using System;
using System.Buffers.Binary;
using System.IO;
using System.Text.Json;

namespace Bubilator88.Windows;

/// <summary>Reads the Core's BU88 sections through the existing C ABI. Container
/// interpretation stays in Core; app metadata encoding stays in the app.</summary>
internal static unsafe class StateSections
{
    public const uint AppMeta = 0x41544D41, Thumbnail = 0x424D4854;

    public static byte[]? Read(byte[] state, uint tag)
    {
        fixed (byte* input = state)
        {
            int length = NativeApi.b88_state_section(input, state.Length, tag, null, 0);
            if (length < 0) return null;
            var result = new byte[length];
            fixed (byte* output = result)
                if (NativeApi.b88_state_section(input, state.Length, tag, output, length) != length)
                    throw new InvalidDataException("Save state section changed while copying.");
            return result;
        }
    }

    public static byte[] MetadataSection(WinSaveMeta metadata)
    {
        byte[] json = AppStateMetadata.Encode(metadata);
        var section = new byte[8 + json.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(section, AppMeta);
        BinaryPrimitives.WriteInt32LittleEndian(section.AsSpan(4), json.Length);
        json.CopyTo(section, 8);
        return section;
    }

    public static WinSaveMeta? ReadMetadata(byte[] blob, string path)
    {
        byte[]? embedded = Read(blob, AppMeta);
        if (embedded is not null)
        {
            try { return AppStateMetadata.Decode(embedded); }
            catch (Exception ex) when (ex is JsonException or InvalidOperationException) { return null; }
        }
        string legacyPath = Path.ChangeExtension(path, ".meta.json");
        if (!File.Exists(legacyPath)) return null;
        try { return JsonSerializer.Deserialize<WinSaveMeta>(File.ReadAllText(legacyPath)); }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException) { return null; }
    }

    public static byte[]? ReadThumbnail(byte[] blob, string path)
    {
        byte[]? embedded = Read(blob, Thumbnail);
        if (embedded is not null) return embedded;
        string legacyPath = Path.ChangeExtension(path, ".thumb.png");
        return File.Exists(legacyPath) ? File.ReadAllBytes(legacyPath) : null;
    }

    /// <summary>Build a 320x200 PNG from a captured 640x400 native frame, using
    /// the shared Core encoder synchronously while the app is quiescent.</summary>
    public static byte[] EncodeThumbnail(ReadOnlySpan<byte> frame)
    {
        const int width = 320, height = 200;
        if (frame.Length != width * height * 16) throw new ArgumentException("Expected a 640x400 RGBA frame.");
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++)
                frame.Slice((y * 2 * 640 + x * 2) * 4, 4).CopyTo(pixels.AsSpan((y * width + x) * 4));
        fixed (byte* input = pixels)
        {
            int length = NativeApi.b88_encode_png(input, pixels.Length, width, height, null, 0);
            if (length <= 0) throw new InvalidDataException("Cannot encode the state thumbnail.");
            var png = new byte[length];
            fixed (byte* output = png)
                if (NativeApi.b88_encode_png(input, pixels.Length, width, height, output, length) != length)
                    throw new InvalidDataException("PNG length changed while copying.");
            return png;
        }
    }
}
