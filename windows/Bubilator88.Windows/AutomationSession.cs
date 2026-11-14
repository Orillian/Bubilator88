using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Bubilator88.Windows;

/// <summary>Native session lifetime and typed reverse P/Invoke marshaling.
/// JSON-RPC request/reply bytes pass through unchanged; no host operation uses JSON.</summary>
internal sealed class AutomationSession : IAsyncDisposable
{
    private readonly NativeApi.McpAppCallbacks _callbacks;
    private readonly AppAutomationHost _host;
    private readonly SemaphoreSlim _serial = new(1);
    private readonly CancellationTokenSource _stop = new();
    private readonly object _disposeLock = new();
    private Task? _disposeTask;
    private IntPtr _session;
    private CancellationToken _activeToken;

    public AutomationSession(Func<NativeApi.McpAppCallbacks, string, IntPtr> createSession,
        string version, AppAutomationHost host)
    {
        _host = host;
        _callbacks = new NativeApi.McpAppCallbacks
        {
            Execute = (_, action, data, result) => Guard(result,
                () => _host.WithMachine(() => InvokeAction(action, data)), allowCancelled: true),
            RunFrame = (_, predicate, data, result) => Guard(result,
                () => _host.RunFrame(() => InvokeAction(predicate, data) != 0, _activeToken) ? 1 : 0, 0),
            Publish = (_, result) => Guard(result, () => _host.PublishFrame(_activeToken)),
            GetRunning = (_, result) => Guard(result, () => _host.IsRunning(_activeToken) ? 1 : 0, 0),
            SetRunning = (_, running, result) => Guard(result, () => _host.SetRunning(running != 0, _activeToken)),
            SetDebugger = (_, attached, action, data, result) => Guard(result,
                () => _host.SetDebuggerAttached(attached != 0, () => InvokeAction(action, data), _activeToken)),
            Reset = (_, cold, mode, clock, result) => Guard(result,
                () => _host.Reset(cold != 0, mode < 0 ? null : (EmulatorBootMode)mode,
                    clock < 0 ? null : clock != 0, _activeToken)),
            MountDisk = (_, drive, path, image, writeProtected, result) => Guard(result,
                () => ReturnText(result, _host.MountDisk(drive, path, image, writeProtected != 0, _activeToken))),
            EjectDisk = (_, drive, result) => Guard(result, () => _host.EjectDisk(drive, _activeToken)),
            SaveState = (_, path, result) => Guard(result, () => _host.SaveState(path, _activeToken)),
            LoadState = (_, path, result) => Guard(result, () => _host.LoadState(path, _activeToken)),
        };
        _session = createSession(_callbacks, version);
        if (_session == IntPtr.Zero) throw new InvalidOperationException("Cannot create the MCP session.");
    }

    public async Task<byte[]?> HandleAsync(byte[] message, CancellationToken token)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, _stop.Token);
        await _serial.WaitAsync(linked.Token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() => Handle(message, linked.Token), linked.Token).ConfigureAwait(false);
        }
        finally { _serial.Release(); }
    }

    private unsafe byte[]? Handle(byte[] message, CancellationToken token)
    {
        _activeToken = token;
        int length;
        fixed (byte* input = message)
            length = NativeApi.b88_mcp_session_handle(_session, input, message.Length);
        if (length == 0) return null;
        if (length < 0) throw new InvalidOperationException("Invalid MCP reply length.");
        var reply = new byte[length];
        fixed (byte* output = reply)
            if (NativeApi.b88_mcp_session_reply(_session, output, length) != length)
                throw new InvalidOperationException("MCP reply changed while copying.");
        return reply;
    }

    private static int InvokeAction(IntPtr action, IntPtr data) =>
        Marshal.GetDelegateForFunctionPointer<NativeApi.McpMachineAction>(action)(data);

    private void Guard(IntPtr result, Action action, bool allowCancelled = false)
    {
        try
        {
            if (!allowCancelled) _activeToken.ThrowIfCancellationRequested();
            action();
        }
        catch (Exception ex) { ReportError(result, ex); }
    }

    private T Guard<T>(IntPtr result, Func<T> action, T fallback)
    {
        try { _activeToken.ThrowIfCancellationRequested(); return action(); }
        catch (Exception ex) { ReportError(result, ex); return fallback; }
    }

    private static unsafe void ReportError(IntPtr result, Exception error)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(string.IsNullOrEmpty(error.Message) ? error.GetType().Name : error.Message);
        fixed (byte* text = bytes) NativeApi.b88_mcp_app_result_error(result, text, bytes.Length);
    }

    private static unsafe void ReturnText(IntPtr result, string value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value);
        fixed (byte* text = bytes) NativeApi.b88_mcp_app_result_text(result, text, bytes.Length);
    }

    public void Cancel() => _stop.Cancel();
    public ValueTask DisposeAsync()
    {
        lock (_disposeLock) return new ValueTask(_disposeTask ??= DestroyAsync());
    }

    private async Task DestroyAsync()
    {
        Cancel();
        await _serial.WaitAsync().ConfigureAwait(false);
        try
        {
            await Task.Run(() => NativeApi.b88_mcp_session_destroy(_session)).ConfigureAwait(false);
            _session = IntPtr.Zero;
            GC.KeepAlive(_callbacks);
        }
        finally { _serial.Release(); }
    }
}
