using System;
using System.Runtime.InteropServices;

namespace Bubilator88.Windows;

internal static unsafe partial class NativeApi
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void McpExecute(IntPtr user, IntPtr action, IntPtr data, IntPtr result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate int McpRunFrame(IntPtr user, IntPtr predicate, IntPtr data, IntPtr result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void McpPublish(IntPtr user, IntPtr result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate int McpGetRunning(IntPtr user, IntPtr result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void McpSetRunning(IntPtr user, int running, IntPtr result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void McpSetDebugger(IntPtr user, int attached, IntPtr action, IntPtr data, IntPtr result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void McpReset(IntPtr user, int cold, int mode, int clock8MHz, IntPtr result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void McpMountDisk(IntPtr user, int drive, [MarshalAs(UnmanagedType.LPUTF8Str)] string path,
        int imageIndex, int writeProtected, IntPtr result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void McpEjectDisk(IntPtr user, int drive, IntPtr result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void McpStateFile(IntPtr user, [MarshalAs(UnmanagedType.LPUTF8Str)] string path, IntPtr result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate int McpRunFrameAfter(IntPtr user, IntPtr predicate, IntPtr data, IntPtr after, IntPtr afterData, IntPtr result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void McpSetWriteProtect(IntPtr user, int drive, int protectedFlag, IntPtr result);

    /// <summary>Managed roots for the typed callback arguments. This is not a
    /// marshaled struct: the C ABI receives individual C function pointers.</summary>
    internal sealed class McpAppCallbacks
    {
        public required McpExecute Execute { get; init; }
        public required McpRunFrame RunFrame { get; init; }
        public required McpPublish Publish { get; init; }
        public required McpGetRunning GetRunning { get; init; }
        public required McpSetRunning SetRunning { get; init; }
        public required McpSetDebugger SetDebugger { get; init; }
        public required McpReset Reset { get; init; }
        public required McpMountDisk MountDisk { get; init; }
        public required McpEjectDisk EjectDisk { get; init; }
        public required McpStateFile SaveState { get; init; }
        public required McpStateFile LoadState { get; init; }
        /// <summary>Optional: a frame that also runs the Core's after-frame
        /// action before its audio is discarded (capture_audio).</summary>
        public McpRunFrameAfter? RunFrameAfter { get; init; }
        /// <summary>Optional: write protection through the app's command.</summary>
        public McpSetWriteProtect? SetWriteProtect { get; init; }
    }

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr b88_mcp_app_session_create(IntPtr machine, IntPtr user,
        McpExecute execute, McpRunFrame frame, McpPublish publish, McpGetRunning getRunning,
        McpSetRunning setRunning, McpSetDebugger attach, McpReset reset, McpMountDisk mount,
        McpEjectDisk eject, McpStateFile save, McpStateFile load,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string version);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int b88_mcp_app_session_set_frame_after(IntPtr session, McpRunFrameAfter callback);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int b88_mcp_app_session_set_write_protect(IntPtr session, McpSetWriteProtect callback);

    public static IntPtr CreateAppMcpSession(IntPtr machine, McpAppCallbacks callbacks, string version)
    {
        IntPtr session = b88_mcp_app_session_create(machine, IntPtr.Zero, callbacks.Execute, callbacks.RunFrame,
            callbacks.Publish, callbacks.GetRunning, callbacks.SetRunning, callbacks.SetDebugger, callbacks.Reset,
            callbacks.MountDisk, callbacks.EjectDisk, callbacks.SaveState, callbacks.LoadState, version);
        if (session == IntPtr.Zero) return session;
        // Optional callbacks, set before the session's first request. A typed
        // session always takes them; refusing means a mismatched Core.
        if ((callbacks.RunFrameAfter is { } frameAfter && b88_mcp_app_session_set_frame_after(session, frameAfter) == 0)
            || (callbacks.SetWriteProtect is { } writeProtect && b88_mcp_app_session_set_write_protect(session, writeProtect) == 0))
        {
            b88_mcp_session_destroy(session);
            throw new InvalidOperationException("The Core refused the MCP session's optional callbacks.");
        }
        return session;
    }

    [LibraryImport(Dll)]
    public static partial void b88_mcp_app_result_error(IntPtr result, byte* text, int length);
    [LibraryImport(Dll)]
    public static partial void b88_mcp_app_result_text(IntPtr result, byte* text, int length);
}
