using System;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;

namespace Bubilator88.Windows;

public sealed partial class MainWindow
{
    private DiskWriteBack? _diskWriteBack;
    private DispatcherQueueTimer? _diskWriteBackTimer;

    private void StartDiskWriteBack()
    {
        _diskWriteBack = new DiskWriteBack(_host!, _drives, DiskWriteBackIO.DefaultRecoveryDirectory)
        { Warning = ShowError };
        // Independent of CompositionTarget.Rendering, which stops while minimized.
        // Polling also covers writes from MCP runFrames while the real-time loop is paused.
        _diskWriteBackTimer = DispatcherQueue.CreateTimer();
        _diskWriteBackTimer.Interval = TimeSpan.FromMilliseconds(25);
        _diskWriteBackTimer.Tick += (_, _) => DiskOperation(() => _diskWriteBack.Tick(_clock.Elapsed.TotalSeconds));
        _diskWriteBackTimer.Start();
    }

    private void DiskOperation(Action operation)
    {
        try { operation(); }
        catch (Exception error) { ShowError(error.Message); }
    }

    /// <summary>Flush before replacement while holding the same lock as real-time and MCP execution.</summary>
    private T DiskTransaction<T>(int drives, Func<T> operation) =>
        _diskWriteBack!.BeforeMediaChange(drives, operation);

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        ReleaseMouse();
        bool wasRunning = !_paused;
        _automationClosing = true;
        SetEmulatorRunning(false);
        try
        {
            if (_host is not null) DiskTransaction(3, () => true);
            _diskWriteBackTimer?.Stop();
        }
        catch (Exception error)
        {
            // Keep the machine alive if neither the source nor a recovery file can be saved.
            args.Cancel = true;
            _automationClosing = false;
            if (wasRunning) SetEmulatorRunning(true);
            ShowError(error.Message);
        }
    }
}
