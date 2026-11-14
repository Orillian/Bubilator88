using System;
using System.IO;
using System.Text;
using Xunit;

namespace Bubilator88.Windows.Tests;

public sealed class StatePersistenceTests
{
    [Fact]
    public void AtomicWrite_FailedWritePreservesExistingState()
    {
        string directory = Path.Combine(Path.GetTempPath(), "b88-state-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "state.b88s");
        try
        {
            File.WriteAllText(path, "original state");
            Assert.Throws<IOException>(() => AtomicStateFile.Write(path, stream =>
            { stream.Write(Encoding.UTF8.GetBytes("partial")); throw new IOException("Disk full."); }));
            Assert.Equal("original state", File.ReadAllText(path));
            Assert.Single(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public void Metadata_MissingRequiredFieldsIsIgnored()
    {
        Assert.Null(AppStateMetadata.Decode(Encoding.UTF8.GetBytes("{}")));
    }

    [Fact]
    public void Metadata_UsesMacOSFieldNamesAndRoundTripsDriveIdentity()
    {
        var meta = new WinSaveMeta
        {
            BootModeIndex = 2, Clock8MHz = false, MonitorType = 0, MemoryWaitDip = true,
            Drive0 = new WinSaveMeta.DriveMeta
            {
                FileName = "game", ImageNames = new[] { "Disk A", "Disk B" },
                ImageCount = 2, CurrentImage = 1, SourcePath = "C:\\games\\game.d88",
            },
        };
        byte[] json = AppStateMetadata.Encode(meta);
        Assert.Contains("\"bootMode\":\"n88-v1s\"", Encoding.UTF8.GetString(json));
        var restored = AppStateMetadata.Decode(json)!;
        Assert.Equal(2, restored.BootModeIndex);
        Assert.False(restored.Clock8MHz);
        Assert.Equal(0, restored.MonitorType);
        Assert.Equal(1, restored.Drive0!.CurrentImage);
        Assert.Equal(meta.Drive0.SourcePath, restored.Drive0.SourcePath);
    }
}
