using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Controls;
using WinRT;

namespace Bubilator88.Windows;

/// <summary>The screen hit-test surface controls the WinUI pointer during capture.</summary>
public sealed class MouseInputSurface : Control
{
    private InputCursor? _transparentCursor;
    private InputSystemCursor? _arrowCursor;

    internal void PrepareCaptureCursor() => _transparentCursor ??= CreateTransparentCursor();

    public void SetCaptured(bool captured)
    {
        ProtectedCursor = captured ? _transparentCursor
            : (_arrowCursor ??= InputSystemCursor.Create(InputSystemCursorShape.Arrow));
    }

    internal void DisposeCursors()
    {
        ProtectedCursor = null;
        _transparentCursor?.Dispose();
        _arrowCursor?.Dispose();
    }

    private static unsafe InputCursor CreateTransparentCursor()
    {
        const int size = 32;
        // A monochrome cursor leaves the background unchanged when AND=1 and XOR=0.
        Span<byte> andMask = stackalloc byte[size * size / 8];
        Span<byte> xorMask = stackalloc byte[size * size / 8];
        andMask.Fill(0xFF);
        xorMask.Clear();
        fixed (byte* andBits = andMask, xorBits = xorMask)
        {
            nint cursor = CreateCursor(0, 0, 0, size, size, andBits, xorBits);
            if (cursor == 0) throw new Win32Exception();
            try
            {
                // CreateFromHCursor copies the cursor into a WinUI InputCursor.
                using var factory = ActivationFactory.Get("Microsoft.UI.Input.InputCursor");
                var interopId = new Guid("ac6f5065-90c4-46ce-beb7-05e138e54117");
                Marshal.ThrowExceptionForHR(Marshal.QueryInterface(factory.ThisPtr, in interopId, out nint interop));
                try
                {
                    // The method follows the six IInspectable entries.
                    var create = (delegate* unmanaged[Stdcall]<nint, nint, nint*, int>)(*(nint**)interop)[6];
                    nint result = 0;
                    Marshal.ThrowExceptionForHR(create(interop, cursor, &result));
                    try { return MarshalInspectable<InputCursor>.FromAbi(result); }
                    finally { Marshal.Release(result); }
                }
                finally { Marshal.Release(interop); }
            }
            finally { DestroyCursor(cursor); }
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern unsafe nint CreateCursor(nint instance, int hotX, int hotY,
        int width, int height, byte* andMask, byte* xorMask);

    [DllImport("user32.dll")]
    private static extern bool DestroyCursor(nint cursor);
}
