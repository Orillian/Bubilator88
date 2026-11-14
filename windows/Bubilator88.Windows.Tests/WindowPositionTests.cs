using System.Text.Json;
using Windows.Graphics;
using Xunit;

namespace Bubilator88.Windows.Tests;

public sealed class WindowPositionTests
{
    [Theory]
    [InlineData(200, 100, 800, 600, 0, 0, 1920, 1080, 200, 100)]
    [InlineData(-1600, -100, 800, 600, -1920, -200, 1920, 1080, -1600, -100)]
    [InlineData(3000, 2000, 800, 600, 0, 0, 1920, 1040, 1120, 440)]
    [InlineData(-2000, -1000, 800, 600, 0, 40, 1920, 1040, 0, 40)]
    [InlineData(200, 100, 2560, 1800, 0, 40, 1920, 1040, 0, 40)]
    public void ClampToWorkArea_KeepsWindowReachable(
        int x, int y, int width, int height,
        int left, int top, int areaWidth, int areaHeight, int expectedX, int expectedY)
    {
        var position = new WindowPosition(x, y);
        var area = new RectInt32(left, top, areaWidth, areaHeight);

        var restored = position.ClampToWorkArea(new SizeInt32(width, height), area);

        Assert.Equal(new WindowPosition(expectedX, expectedY), restored);
    }

    [Fact]
    public void Serialization_RoundTrip_PreservesNegativeMonitorCoordinates()
    {
        var position = new WindowPosition(-1600, -200);

        string json = JsonSerializer.Serialize(position);

        Assert.Equal(position, JsonSerializer.Deserialize<WindowPosition>(json));
    }
}
