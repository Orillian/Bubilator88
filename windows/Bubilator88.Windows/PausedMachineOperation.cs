using System;

namespace Bubilator88.Windows;

/// <summary>Quiesces the real-time loop across an application transaction,
/// including its metadata/UI updates, and restores running state on failure.</summary>
internal sealed class PausedMachineOperation
{
    private readonly Func<bool> _isRunning;
    private readonly Action<bool> _setRunning;
    public PausedMachineOperation(Func<bool> isRunning, Action<bool> setRunning)
    { _isRunning = isRunning; _setRunning = setRunning; }

    public T Run<T>(Func<T> operation)
    {
        bool wasRunning = _isRunning();
        if (wasRunning) _setRunning(false);
        try { return operation(); }
        finally { if (wasRunning) _setRunning(true); }
    }
    public void Run(Action operation) => Run(() => { operation(); return true; });
}
