using System;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using WinRT.Interop;

namespace Bubilator88.Windows;

public sealed partial class MainWindow
{
    private const uint WmInput = 0x00ff, RidInput = 0x10000003, RidevRemove = 1;
    [StructLayout(LayoutKind.Sequential)]
    private struct MousePoint { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct RawDevice { public ushort UsagePage, Usage; public uint Flags; public IntPtr Target; }
    [StructLayout(LayoutKind.Sequential)]
    private struct RawHeader { public uint Type, Size; public IntPtr Device, WParam; }
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct RawMouse
    {
        [FieldOffset(0)] public ushort Flags;
        [FieldOffset(4)] public ushort ButtonFlags;
        [FieldOffset(12)] public int X;
        [FieldOffset(16)] public int Y;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct RawInput { public RawHeader Header; public RawMouse Mouse; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterRawInputDevices([In] RawDevice[] devices, uint count, uint size);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputData(IntPtr input, uint command, out RawInput data, ref uint size, uint headerSize);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out MousePoint point);
    [DllImport("user32.dll")] private static extern IntPtr SetCursor(IntPtr cursor);
    [DllImport("user32.dll", EntryPoint = "ClipCursor")] private static extern bool ClipMouse(ref MouseRect rect);
    [DllImport("user32.dll", EntryPoint = "ClipCursor")] private static extern bool UnclipMouse(IntPtr rect);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(IntPtr hwnd, SubclassProc proc, UIntPtr id);

    private bool _mouseEnabled, _mouseJoystick, _mouseCaptured;
    private double _mouseSensitivity = 0.5;
    private readonly MouseMotion _mouseMotion = new();
    private readonly MouseButtons _mouseButtons = new();
    private SubclassProc? _mouseSubclass;

    private bool RegisterMouse(bool enable)
    {
        var devices = new[] { new RawDevice { UsagePage = 1, Usage = 2,
            Flags = enable ? 0 : RidevRemove,
            Target = enable ? WindowNative.GetWindowHandle(this) : IntPtr.Zero } };
        return RegisterRawInputDevices(devices, 1, (uint)Marshal.SizeOf<RawDevice>());
    }

    private void InitializeMouseInput()
    {
        _mouseSubclass = MouseWindowProc;
        if (!SetWindowSubclass(WindowNative.GetWindowHandle(this), _mouseSubclass, (UIntPtr)1, UIntPtr.Zero))
            _mouseSubclass = null;
        MouseInputSurface.PointerPressed += OnMouseCapturePressed;
        Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated) ReleaseMouse();
        };
    }

    private void OnMouseCapturePressed(object sender, PointerRoutedEventArgs e)
    {
        if (!_mouseEnabled || _mouseCaptured || _host is null || IsPopupOpen()) return;
        if (!e.GetCurrentPoint(ScreenPanel).Properties.IsLeftButtonPressed) return;
        try { MouseInputSurface.PrepareCaptureCursor(); }
        catch (Exception error) when (error is COMException or System.ComponentModel.Win32Exception)
        {
            ShowToast("Unable to hide the mouse cursor");
            return;
        }
        if (_mouseSubclass is null || !GetCursorPos(out var point) || !RegisterMouse(true))
        {
            ShowToast("Unable to start mouse capture");
            return;
        }
        var rect = new MouseRect { Left = point.X, Top = point.Y, Right = point.X + 1, Bottom = point.Y + 1 };
        if (!ClipMouse(ref rect))
        {
            RegisterMouse(false);
            ShowToast("Unable to start mouse capture");
            return;
        }
        _mouseCaptured = true;
        _mouseMotion.Reset();
        _mouseButtons.BeginCapture();
        MouseInputSurface.SetCaptured(true);
        // Hide the current cursor immediately, before WinUI updates its shape.
        SetCursor(IntPtr.Zero);
        MouseCaptureIcon.Visibility = Visibility.Visible;
        RestoreEmulatorFocus();
        ShowToast("Mouse captured — Shift+Esc to release");
        e.Handled = true;
    }

    private IntPtr MouseWindowProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam,
                                   UIntPtr id, UIntPtr refData)
    {
        if (message == WmInput && _mouseCaptured && _host is not null)
        {
            uint size = (uint)Marshal.SizeOf<RawInput>();
            if (GetRawInputData(lParam, RidInput, out var input, ref size, (uint)Marshal.SizeOf<RawHeader>()) == size
                && input.Header.Type == 0)
            {
                (int dx, int dy) movement;
                if ((input.Mouse.Flags & 1) != 0)
                {
                    bool virtualDesktop = (input.Mouse.Flags & 2) != 0;
                    int width = GetSystemMetrics(virtualDesktop ? 78 : 0);
                    int height = GetSystemMetrics(virtualDesktop ? 79 : 1);
                    movement = _mouseMotion.ScaleAbsolute(input.Mouse.X, input.Mouse.Y, width, height,
                        input.Header.Device, virtualDesktop, _mouseSensitivity);
                }
                else
                {
                    movement = _mouseMotion.Scale(input.Mouse.X, input.Mouse.Y, _mouseSensitivity);
                }
                if (movement.dx != 0 || movement.dy != 0) _host.MoveMouse(movement.dx, movement.dy);
                if (_mouseButtons.Apply(input.Mouse.ButtonFlags))
                    _host.SetMouseButtons(_mouseButtons.Left, _mouseButtons.Right);
            }
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    private void ReleaseMouse()
    {
        if (!_mouseCaptured) return;
        _mouseCaptured = false;
        MouseCaptureIcon.Visibility = Visibility.Collapsed;
        RegisterMouse(false);
        UnclipMouse(IntPtr.Zero);
        MouseInputSurface.SetCaptured(false);
        _host?.SetMouseButtons(false, false);
    }

    private void DisposeMouseInput()
    {
        ReleaseMouse();
        MouseInputSurface.DisposeCursors();
        if (_mouseSubclass is not null)
        {
            RemoveWindowSubclass(WindowNative.GetWindowHandle(this), _mouseSubclass, (UIntPtr)1);
            _mouseSubclass = null;
        }
    }
}
