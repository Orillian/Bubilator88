using System;
using Xunit;

namespace Bubilator88.Windows.Tests;

public sealed class MouseMotionTests
{
    [Fact]
    public void Scale_PreservesSignedFractionsAcrossEvents()
    {
        var motion = new MouseMotion();
        Assert.Equal((0, 0), motion.Scale(1, -1, 0.5));
        Assert.Equal((1, -1), motion.Scale(1, -1, 0.5));
    }

    [Fact]
    public void Reset_DiscardsRemainderFromPreviousCapture()
    {
        var motion = new MouseMotion();
        motion.Scale(1, -1, 0.5);
        motion.Reset();
        Assert.Equal((0, 0), motion.Scale(1, -1, 0.5));
    }

    [Fact]
    public void AbsoluteMovement_UsesFirstPointAsBaseline_AndScalesDeltas()
    {
        var motion = new MouseMotion();
        Assert.Equal((0, 0), motion.ScaleAbsolute(10000, 20000, 1920, 1080, (IntPtr)1, true, 1));
        Assert.Equal((96, -54), motion.ScaleAbsolute(13277, 16723, 1920, 1080, (IntPtr)1, true, 1));
    }

    [Fact]
    public void AbsoluteMovement_ButtonOnlyPacketDoesNotResetBaseline()
    {
        var motion = new MouseMotion();
        motion.ScaleAbsolute(0, 0, 1000, 1000, (IntPtr)1, true, 1);
        motion.Scale(0, 0, 1);
        Assert.Equal((1000, 0), motion.ScaleAbsolute(65535, 0, 1000, 1000, (IntPtr)1, true, 1));
    }

    [Fact]
    public void AbsoluteMovement_DeviceOrGeometryChangeStartsNewBaseline()
    {
        var motion = new MouseMotion();
        motion.ScaleAbsolute(0, 0, 1000, 1000, (IntPtr)1, true, 1);
        Assert.Equal((0, 0), motion.ScaleAbsolute(65535, 0, 1000, 1000, (IntPtr)2, true, 1));
        Assert.Equal((0, 0), motion.ScaleAbsolute(0, 0, 2000, 1000, (IntPtr)2, true, 1));
        motion.Reset();
        Assert.Equal((0, 0), motion.ScaleAbsolute(65535, 0, 2000, 1000, (IntPtr)2, true, 1));
    }
}
