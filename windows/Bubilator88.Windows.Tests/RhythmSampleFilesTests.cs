using System;
using System.IO;
using System.Linq;
using Xunit;

namespace Bubilator88.Windows.Tests;

public sealed class RhythmSampleFilesTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "b88-rhythm-" + Guid.NewGuid().ToString("N"));

    public RhythmSampleFilesTests() => Directory.CreateDirectory(_directory);
    public void Dispose() => Directory.Delete(_directory, recursive: true);

    [Fact]
    public void Load_NoUserFiles_ProvidesAllSixBundledSounds()
    {
        var samples = RhythmSampleFiles.Load(_directory).ToArray();
        Assert.Equal(Enumerable.Range(0, 6), samples.Select(sample => sample.Index));
        Assert.All(samples, sample =>
        {
            Assert.True(sample.Data.Length > 44);
            Assert.Equal("RIFF"u8.ToArray(), sample.Data[..4]);
            Assert.Equal("WAVE"u8.ToArray(), sample.Data[8..12]);
        });
    }

    [Theory]
    [InlineData(0, "BD")]
    [InlineData(1, "SD")]
    [InlineData(2, "TOP")]
    [InlineData(3, "HH")]
    [InlineData(4, "TOM")]
    [InlineData(5, "RIM")]
    public void Load_UserSound_LoadsAfterItsFallbackWithoutReplacingOtherSounds(int index, string name)
    {
        byte[] user = { 1, 2, 3 };
        File.WriteAllBytes(Path.Combine(_directory, $"2608_{name}.WAV"), user);
        var samples = RhythmSampleFiles.Load(_directory).ToArray();
        Assert.Equal(7, samples.Length);
        var instrument = samples.Where(sample => sample.Index == index).ToArray();
        Assert.Equal(2, instrument.Length);
        Assert.True(instrument[0].Data.Length > 44);
        Assert.Equal(user, instrument[1].Data);
    }

    [Fact]
    public void Load_LockedUserFile_KeepsBundledSound()
    {
        using var locked = new FileStream(Path.Combine(_directory, "2608_BD.WAV"),
            FileMode.Create, FileAccess.ReadWrite, FileShare.None);
        Assert.Equal(6, RhythmSampleFiles.Load(_directory).Count());
    }
}
