using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Xunit;

namespace Bubilator88.Windows.Tests;

public sealed class BlankDiskCreationTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "b88-blank-" + Guid.NewGuid().ToString("N"));
    public BlankDiskCreationTests() => Directory.CreateDirectory(_directory);
    public void Dispose() => Directory.Delete(_directory, recursive: true);

    [Theory]
    [InlineData(0x00, "2D", false)]
    [InlineData(0x00, "2D", true)]
    [InlineData(0x10, "2DD", false)]
    [InlineData(0x10, "2DD", true)]
    [InlineData(0x20, "2HD", false)]
    [InlineData(0x20, "2HD", true)]
    public void CreateImage_MatchesPinnedCoreFormatter(int type, string label, bool basic)
    {
        using var stream = typeof(BlankDiskCreation).Assembly.GetManifestResourceStream("Bubilator88.BlankDisks.manifest.json")!;
        using var manifest = JsonDocument.Parse(stream);
        string name = $"{label}-{(basic ? "basic" : "erased")}.d88";
        var reference = manifest.RootElement.GetProperty("images").GetProperty(name);

        byte[] image = BlankDiskCreation.CreateImage((BlankDiskType)type, "", basic);

        Assert.Equal(reference.GetProperty("size").GetInt32(), image.Length);
        Assert.Equal(reference.GetProperty("sha256").GetString(), Convert.ToHexString(SHA256.HashData(image)).ToLowerInvariant());
    }

    [Fact]
    public void Templates_ProvenanceMatchesPinnedCore()
    {
        var assembly = typeof(BlankDiskCreation).Assembly;
        using var manifestStream = assembly.GetManifestResourceStream("Bubilator88.BlankDisks.manifest.json")!;
        using var pinStream = assembly.GetManifestResourceStream("Bubilator88.BlankDisks.Package.resolved")!;
        using var manifest = JsonDocument.Parse(manifestStream);
        using var resolved = JsonDocument.Parse(pinStream);
        var core = resolved.RootElement.GetProperty("pins").EnumerateArray()
            .Single(pin => pin.GetProperty("identity").GetString() == "bubilator88core").GetProperty("state");
        Assert.Equal(core.GetProperty("revision").GetString(), manifest.RootElement.GetProperty("core_revision").GetString());
    }

    [Theory]
    [InlineData("SAVE", "53415645")]
    [InlineData("あいう", "82A082A282A4")]
    [InlineData("12345678901234567", "31323334353637383930313233343536")]
    [InlineData("Disk😀", "4469736BF09F9880")]
    public void CreateImage_NameUsesCoreEncodingAnd16ByteLimit(string name, string expectedHex)
    {
        byte[] image = BlankDiskCreation.CreateImage(BlankDiskType.TwoDD, name, true);
        byte[] expected = Convert.FromHexString(expectedHex);
        Assert.Equal(expected, image.Take(expected.Length));
        Assert.All(image.Skip(expected.Length).Take(17 - expected.Length), value => Assert.Equal(0, value));
    }

    [Theory]
    [InlineData(false, false, 0)]
    [InlineData(false, true, 0)]
    [InlineData(true, false, 1)]
    [InlineData(true, true, 0)]
    public void Save_SelectsFirstEmptyDriveAndReturnsPersistedFile(bool occupied0, bool occupied1, int expectedDrive)
    {
        var slots = new[] { new DriveSlot(), new DriveSlot() };
        if (occupied0) slots[0].Bytes = Array.Empty<byte>();
        if (occupied1) slots[1].Bytes = Array.Empty<byte>();
        string path = Path.Combine(_directory, "Save.v2.d88");
        var created = BlankDiskCreation.Save(path, BlankDiskType.TwoDD, true, slots);

        Assert.Equal(path, created.Path);
        Assert.Equal("Save.v2", Encoding.ASCII.GetString(File.ReadAllBytes(created.Path), 0, 7));
        Assert.Equal(expectedDrive, created.Drive);
        Assert.Equal(occupied0, slots[0].Occupied);
        Assert.Equal(occupied1, slots[1].Occupied);
    }

    [Fact]
    public void Save_MountedDestination_LeavesExistingImageUntouched()
    {
        string path = Path.Combine(_directory, "game.d88");
        byte[] original = { 1, 2, 3 };
        File.WriteAllBytes(path, original);
        var slots = new[] { new DriveSlot { Bytes = original, SourcePath = path }, new DriveSlot() };
        Assert.Throws<IOException>(() => BlankDiskCreation.Save(path, BlankDiskType.TwoD, true, slots));
        Assert.Equal(original, File.ReadAllBytes(path));
    }

    [Fact]
    public void Save_InvalidSourceMetadata_DoesNotBlockSavingUnrelatedFile()
    {
        string path = Path.Combine(_directory, "New.d88");
        var slots = new[]
        {
            new DriveSlot { Bytes = Array.Empty<byte>(), SourcePath = "invalid\0source.d88" },
            new DriveSlot(),
        };
        var created = BlankDiskCreation.Save(path, BlankDiskType.TwoDD, true, slots);
        Assert.Equal(1, created.Drive);
        Assert.True(File.Exists(path));
    }

    [Fact]
    public void Save_UnwritableDestination_DoesNotLeaveFile()
    {
        string path = Path.Combine(_directory, "missing-directory", "Blank.d88");
        Assert.Throws<DirectoryNotFoundException>(() => BlankDiskCreation.Save(path, BlankDiskType.TwoD, false,
            new[] { new DriveSlot(), new DriveSlot() }));
        Assert.False(File.Exists(path));
    }
}
