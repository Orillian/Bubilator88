using System;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Bubilator88.Windows;

/// <summary>The AMTA schema shared with macOS. Windows's old PascalCase JSON
/// sidecars remain a read-only fallback; new saves contain AMTA inside BU88.</summary>
internal static class AppStateMetadata
{
    private static readonly string[] Modes = { "n88-v2", "n88-v1h", "n88-v1s", "n-basic" };

    public static byte[] Encode(WinSaveMeta meta)
    {
        var json = new JsonObject
        {
            ["bootMode"] = Modes[meta.BootModeIndex], ["clock8MHz"] = meta.Clock8MHz,
            ["monitorType"] = meta.MonitorType, ["memoryWaitDip"] = meta.MemoryWaitDip,
        };
        AddDrive(json, 0, meta.Drive0); AddDrive(json, 1, meta.Drive1);
        return JsonSerializer.SerializeToUtf8Bytes(json);
    }

    private static void AddDrive(JsonObject json, int drive, WinSaveMeta.DriveMeta? meta)
    {
        if (meta is null) return;
        string prefix = "drive" + drive;
        string name = meta.ImageNames.ElementAtOrDefault(meta.CurrentImage) ?? meta.FileName;
        json["disk" + drive] = name;
        json[prefix + "Name"] = name;
        json[prefix + "FileName"] = meta.FileName;
        json[prefix + "SourceURL"] = meta.SourcePath is null ? null : new Uri(meta.SourcePath).AbsoluteUri;
        json[prefix + "ImageIndex"] = meta.CurrentImage;
    }

    public static WinSaveMeta? Decode(byte[] bytes)
    {
        var json = JsonNode.Parse(bytes);
        if (json is not JsonObject || json["bootMode"] is not JsonValue mode ||
            !mode.TryGetValue<string>(out var modeName) || json["clock8MHz"] is not JsonValue clock ||
            !clock.TryGetValue<bool>(out var clock8MHz)) return null;
        return new WinSaveMeta
        {
            BootModeIndex = Array.IndexOf(Modes, modeName), Clock8MHz = clock8MHz,
            MonitorType = json["monitorType"]?.GetValue<int>(), MemoryWaitDip = json["memoryWaitDip"]?.GetValue<bool>(),
            Drive0 = ReadDrive(json, 0), Drive1 = ReadDrive(json, 1),
        };
    }

    private static WinSaveMeta.DriveMeta? ReadDrive(JsonNode json, int drive)
    {
        string prefix = "drive" + drive;
        string? name = json[prefix + "Name"]?.GetValue<string>() ?? json["disk" + drive]?.GetValue<string>();
        if (name is null) return null;
        int index = json[prefix + "ImageIndex"]?.GetValue<int>() ?? 0;
        if (index < 0) throw new JsonException("Invalid saved disk image index.");
        string? source = json[prefix + "SourceURL"]?.GetValue<string>();
        return new WinSaveMeta.DriveMeta
        {
            FileName = json[prefix + "FileName"]?.GetValue<string>() ?? name,
            CurrentImage = index, ImageCount = 1, ImageNames = new[] { name },
            SourcePath = Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.IsFile ? uri.LocalPath : null,
        };
    }
}
