using System;
using System.Threading;
using System.Threading.Tasks;

namespace Bubilator88.Windows;

/// <summary>Synchronous UI dispatch for reverse P/Invoke. Cancellation removes
/// work that has not started. Once started, the callback must complete before
/// returning, because a borrowed native action must never outlive its caller.</summary>
internal sealed class AutomationUiDispatcher
{
    private readonly Func<Action, bool> _enqueue;
    public AutomationUiDispatcher(Func<Action, bool> enqueue) => _enqueue = enqueue;

    public void Invoke(Action action, CancellationToken token) => Invoke(() => { action(); return true; }, token);

    public T Invoke<T>(Func<T> action, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var gate = new object();
        bool started = false;
        using var registration = token.Register(() =>
        {
            lock (gate) if (!started) completion.TrySetCanceled(token);
        });
        if (!_enqueue(() =>
        {
            lock (gate)
            {
                if (completion.Task.IsCompleted) return;
                started = true;
            }
            try { completion.TrySetResult(action()); }
            catch (Exception ex) { completion.TrySetException(ex); }
        })) completion.TrySetException(new InvalidOperationException("The emulator window is unavailable."));
        // The native contract is synchronous. This wait is used only by the
        // server worker, never by UI or emulation callbacks holding a lock.
        return completion.Task.GetAwaiter().GetResult();
    }
}
