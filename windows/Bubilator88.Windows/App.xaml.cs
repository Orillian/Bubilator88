using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using WinRT.Interop;

namespace Bubilator88.Windows;

public partial class App : Application
{
    private Window? _window;
    private AppInstance? _instance;
    private DispatcherQueue? _dispatcher;

    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(uint processId);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    public App()
    {
        InitializeComponent();
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Register before constructing MainWindow: its initialization loads shared
        // settings and starts the emulator, which must only happen in one process.
        _instance = AppInstance.FindOrRegisterForKey("Bubilator88.Main");
        if (!_instance.IsCurrent)
        {
            try
            {
                // A user-initiated launch can pass its foreground permission to
                // the running instance before asking it to activate its window.
                AllowSetForegroundWindow(_instance.ProcessId);
                await _instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs());
            }
            catch (Exception ex)
            {
                Trace.TraceError($"Could not activate the existing Bubilator88 instance: {ex}");
            }
            finally
            {
                Exit();
            }
            return;
        }

        _dispatcher = DispatcherQueue.GetForCurrentThread();
        _instance.Activated += OnInstanceActivated;
        _window = new MainWindow();
        _window.Closed += (_, _) =>
        {
            _instance.Activated -= OnInstanceActivated;
            _window = null;
        };
        _window.Activate();
    }

    private void OnInstanceActivated(object? sender, AppActivationArguments args)
    {
        // Redirected activations arrive on a worker thread. Queueing also lets
        // the first launch finish constructing the window before showing it.
        _dispatcher?.TryEnqueue(() =>
        {
            if (_window is null) return;
            if (_window.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter)
                presenter.Restore();
            _window.Activate();
            SetForegroundWindow(WindowNative.GetWindowHandle(_window));
        });
    }
}
