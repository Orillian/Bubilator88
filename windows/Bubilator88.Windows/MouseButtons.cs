namespace Bubilator88.Windows;

/// <summary>Tracks raw mouse button transitions received after capture begins.</summary>
internal sealed class MouseButtons
{
    public bool Left { get; private set; }
    public bool Right { get; private set; }

    public void BeginCapture()
    {
        Left = Right = false;
    }

    public bool Apply(ushort flags)
    {
        bool oldLeft = Left, oldRight = Right;
        if ((flags & 0x0001) != 0) Left = true;
        if ((flags & 0x0002) != 0) Left = false;
        if ((flags & 0x0004) != 0) Right = true;
        if ((flags & 0x0008) != 0) Right = false;
        return Left != oldLeft || Right != oldRight;
    }
}
