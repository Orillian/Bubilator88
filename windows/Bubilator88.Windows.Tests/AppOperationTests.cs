using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Bubilator88.Windows.Tests;

public sealed class AppOperationTests
{
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void PausedOperation_RestoresOriginalStateAfterFailure(bool initiallyRunning)
    {
        bool running = initiallyRunning;
        var events = new List<string>();
        var operation = new PausedMachineOperation(() => running, value =>
        { running = value; events.Add(value ? "resume" : "stop-and-join"); });
        Assert.Throws<InvalidOperationException>(() => operation.Run(() =>
        {
            Assert.False(running);
            events.Add("restore-machine-and-metadata");
            throw new InvalidOperationException("Load failed.");
        }));
        Assert.Equal(initiallyRunning, running);
        Assert.Equal(initiallyRunning ? new[] { "stop-and-join", "restore-machine-and-metadata", "resume" }
                                      : new[] { "restore-machine-and-metadata" }, events);
    }

    [Fact]
    public async Task Dispatcher_CancelBeforeStartDoesNotInvokeBorrowedAction()
    {
        Action? queued = null;
        using var cancellation = new CancellationTokenSource();
        using var enqueued = new ManualResetEventSlim();
        var dispatcher = new AutomationUiDispatcher(action => { queued = action; enqueued.Set(); return true; });
        bool invoked = false;
        var pending = Task.Run(() => dispatcher.Invoke(() => { invoked = true; }, cancellation.Token));
        Assert.True(enqueued.Wait(TimeSpan.FromSeconds(5)));
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        queued!();
        Assert.False(invoked);
    }

    [Fact]
    public async Task Dispatcher_CancelAfterStartWaitsForBorrowedActionToFinish()
    {
        using var cancellation = new CancellationTokenSource();
        using var started = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        var dispatcher = new AutomationUiDispatcher(action => { _ = Task.Run(action); return true; });
        var pending = Task.Run(() => dispatcher.Invoke(() =>
        { started.Set(); release.Wait(); return 42; }, cancellation.Token));
        Assert.True(started.Wait(TimeSpan.FromSeconds(5)));
        try
        {
            cancellation.Cancel();
            Assert.False(pending.IsCompleted);
        }
        finally { release.Set(); }
        Assert.Equal(42, await pending.WaitAsync(TimeSpan.FromSeconds(5)));
    }
}
