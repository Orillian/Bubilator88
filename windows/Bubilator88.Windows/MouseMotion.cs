using System;

namespace Bubilator88.Windows;

/// <summary>Converts raw movement to relative pixels and retains fractional pixels.</summary>
internal sealed class MouseMotion
{
    private double _x, _y;
    private bool _hasAbsolute;
    private int _lastX, _lastY, _width, _height;
    private IntPtr _device;
    private bool _virtualDesktop;

    public (int X, int Y) Scale(int dx, int dy, double sensitivity)
    {
        // Button-only relative packets can be interleaved with absolute movement.
        if (dx != 0 || dy != 0) _hasAbsolute = false;
        return Accumulate(dx, dy, sensitivity);
    }

    public (int X, int Y) ScaleAbsolute(int x, int y, int width, int height,
                                        IntPtr device, bool virtualDesktop, double sensitivity)
    {
        if (width <= 0 || height <= 0 || x < 0 || x > 65535 || y < 0 || y > 65535)
        {
            _hasAbsolute = false;
            return (0, 0);
        }
        if (!_hasAbsolute || _device != device || _width != width || _height != height ||
            _virtualDesktop != virtualDesktop)
        {
            _hasAbsolute = true;
            _device = device;
            _width = width;
            _height = height;
            _virtualDesktop = virtualDesktop;
            _lastX = x;
            _lastY = y;
            return (0, 0);
        }
        double dx = (x - _lastX) * (double)width / 65535;
        double dy = (y - _lastY) * (double)height / 65535;
        _lastX = x;
        _lastY = y;
        return Accumulate(dx, dy, sensitivity);
    }

    private (int X, int Y) Accumulate(double dx, double dy, double sensitivity)
    {
        _x += dx * sensitivity;
        _y += dy * sensitivity;
        int x = (int)_x, y = (int)_y;
        _x -= x;
        _y -= y;
        return (x, y);
    }

    public void Reset()
    {
        _x = _y = 0;
        _hasAbsolute = false;
    }
}
