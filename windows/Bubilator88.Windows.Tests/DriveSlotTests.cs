using System.Linq;
using Xunit;

namespace Bubilator88.Windows.Tests;

public sealed class DriveSlotTests
{
    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    [InlineData(false, false)]
    public void SelectImage_ProtectedMountPreservesEachImagesProtection(bool requestedProtection, bool imageProtection)
    {
        var slot = new DriveSlot();
        var images = new[]
        {
            new EmulatorHost.ImageInfo("A", "2D", imageProtection),
            new EmulatorHost.ImageInfo("B", "2D", false),
        };
        slot.Fill(new byte[] { 1 }, "game.release.v1.2.d88", images, 0, null,
            writeProtected: requestedProtection);
        bool expectedProtection = requestedProtection || imageProtection;
        Assert.Equal(expectedProtection, slot.WriteProtected);

        slot.SelectImage(1);
        Assert.False(slot.WriteProtected);
        Assert.False(slot.Images[1].WriteProtected);

        slot.SelectImage(0);
        // SwitchImage uses this per-image flag when re-mounting through the C ABI.
        Assert.Equal(expectedProtection, slot.Images[0].WriteProtected);
        Assert.Equal(expectedProtection, slot.WriteProtected);
        Assert.Equal("game.release.v1.2", slot.FileName);
    }

    [Theory]
    [InlineData("game.v1.d88", "game.v1", null)]
    [InlineData("game.release.v1.2.d88", "game.release.v1.2", null)]
    [InlineData("game.release.v1.2.d88", "game.release.v1.2", "C:\\games\\game.release.v1.2.d88")]
    [InlineData("ゲーム.ver.1.2.D88", "ゲーム.ver.1.2", "C:\\games\\ゲーム.ver.1.2.D88")]
    public void SelectImage_RepeatedSwitchesPreserveFileAndImageNames(string fileName, string expectedBase, string? sourcePath)
    {
        var slot = new DriveSlot();
        byte[] bytes = { 1 };
        var images = new[]
        {
            new EmulatorHost.ImageInfo("", "2D", false),
            new EmulatorHost.ImageInfo("Named disk", "2D", true),
            new EmulatorHost.ImageInfo("  ", "2D", false),
        };
        slot.Fill(bytes, fileName, images, 0, sourcePath);
        Assert.Equal(expectedBase, slot.FileName);
        Assert.Equal(new[] { expectedBase + " #0", "Named disk", expectedBase + " #2" }, slot.ImageNames);
        string[] originalNames = slot.ImageNames.ToArray();

        foreach (int index in new[] { 1, 2, 0, 2, 1, 0 })
        {
            slot.SelectImage(index);

            Assert.Equal(expectedBase, slot.FileName);
            Assert.Equal(originalNames, slot.ImageNames);
            Assert.Equal(index, slot.CurrentImage);
            Assert.Equal(images[index].WriteProtected, slot.WriteProtected);
            Assert.Same(bytes, slot.Bytes);
            Assert.Equal(sourcePath, slot.SourcePath);
        }
    }
}
