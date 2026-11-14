using System;
using Windows.Graphics;

namespace Bubilator88.Windows;

/// <summary>Persisted desktop position in physical pixels, including negative monitor coordinates.</summary>
internal sealed record WindowPosition(int X, int Y)
{
    /// <summary>Keep the window within the work area; oversized windows keep their title bar reachable.</summary>
    public WindowPosition ClampToWorkArea(SizeInt32 size, RectInt32 area) => new(
        Math.Clamp(X, area.X, area.X + Math.Max(0, area.Width - size.Width)),
        Math.Clamp(Y, area.Y, area.Y + Math.Max(0, area.Height - size.Height)));
}
