using Xunit;

namespace Bubilator88.Windows.Tests;

public sealed class MouseButtonsTests
{
    [Fact]
    public void CaptureRelease_IsIgnored_AndNextClickIsForwarded()
    {
        var buttons = new MouseButtons();
        buttons.BeginCapture();
        Assert.False(buttons.Apply(0x0002));
        Assert.True(buttons.Apply(0x0001));
        Assert.True(buttons.Left);
        Assert.True(buttons.Apply(0x0002));
        Assert.False(buttons.Left);
    }

    [Fact]
    public void Buttons_TrackIndependentTransitions()
    {
        var buttons = new MouseButtons();
        buttons.BeginCapture();
        buttons.Apply(0x0002);
        Assert.True(buttons.Apply(0x0001 | 0x0004));
        Assert.True(buttons.Left);
        Assert.True(buttons.Right);
        Assert.True(buttons.Apply(0x0002));
        Assert.False(buttons.Left);
        Assert.True(buttons.Right);
        Assert.True(buttons.Apply(0x0008));
        Assert.False(buttons.Right);
    }
}
