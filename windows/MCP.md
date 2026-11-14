# Windows MCP

## Ownership

The Windows app follows the macOS split:

| Responsibility | macOS | Windows |
| --- | --- | --- |
| JSON-RPC, tool schemas, validation, tool execution | Core `MCPHandler` / `AutomationTools` | Same Core implementation |
| Application-specific `AutomationHost` | `AppAutomationHost` | Core `TypedAppAutomationHost` plus C# `AppAutomationHost` |
| HTTP, authentication, settings, client registration | App | App |
| Machine serialization | `emuQueue` | `EmulatorHost.SyncRoot` |
| UI and app commands | Main actor | `DispatcherQueue` |

`AutomationSession` passes request/reply bytes unchanged through the new
`b88_mcp_app_session_create` factory and `b88_mcp_session_handle/reply/destroy` functions. The existing
`b88_mcp_handle/reply` retain their headless semantics. Every new Core C export
is public and the ABI additions do not replace existing functions.

The typed callback contract is documented in the Core's
`Sources/CApi/CApiTypedAutomation.swift`. Separate C function pointers mirror
the AutomationHost methods. Machine actions and frame predicates have no JSON
payload or byte-output buffer; error strings are copied only on failure through
a borrowed result handle. The app has no numeric operation dispatcher and never
branches on a tool name or rewrites a tool result. The old JSON-callback factory
remains available in Core, with its original semantics, for ABI compatibility;
the Windows app no longer uses it.

## Thread and lifetime rules

HTTP requests can arrive on multiple connections, but handlers run serially.
Each session also serializes its handle/reply/destroy operations. The server
binds only IPv4 loopback, requires the bearer token and rejects non-loopback
Host/Origin values. Requests are limited to 16 KiB of headers and 1 MiB of body.
GET returns 405; notifications return 202. Responses are plain JSON, without SSE.

The session worker calls native MCP **without the machine lock**. Core invokes
the host for each machine operation; C# takes the lock and executes the borrowed
native action synchronously. UI operations use DispatcherQueue, with no machine
lock held while waiting for it. Callbacks cannot outlive their invocation and
must not re-enter the session API.

`runFrames` parks real-time execution first, then requests one host frame at a
time. Every frame rechecks whether the user resumed, executes the Core's
before-frame predicate, runs normal host frame work including cheats and
discards paused audio. It publishes the resulting screen and stays paused.
Tools such as breakpoints, watches, profiling and recording remain implemented
only in Core.

Disabling control, changing ports or closing the window cancels waiting host
callbacks. Session destruction waits asynchronously for the active native call
to finish; it clears watches, write tracking and profiling and detaches the
debugger. Breakpoints survive session recreation, as on macOS. The callback
delegate remains rooted until native destruction finishes. Machine disposal
and machine callbacks serialize through the same host lock.
Cancellation skips UI callbacks that have not started. Once a callback starts,
dispatch waits for it to finish, so borrowed native actions cannot outlive their
invocation even when the session is canceled.

## Application operations

Pause/resume use the existing app command and update the menu and run LED.
Reset uses the app's hardware settings and preserves RAM, matching the macOS
app's single front-panel reset operation. A requested clock override applies
to that reset without changing the saved clock preference.

Normal menus and MCP both call `IEmulatorAppCommands`, implemented in
`MainWindow.MachineCommands.cs`. Disk mount/eject update the same drive tracking,
recent files, menus and status. The additive `b88_mount_disk_protected` API sets
protection before passing a disk to the machine, including the delayed swap
slot; a post-mount flag update would miss that slot.

Save/load use `PausedMachineOperation` to stop and join real-time execution and
restore its previous state even on failure. Machine data, metadata and display
updates are synchronized before resuming. New files are a single `.b88s` with
the same AMTA JSON fields and THMB section used by macOS. The app calls the
shared PNG encoder through an additive, stateless C ABI for synchronous
thumbnail capture; serialization still uses `b88_save_state_ex`. A flushed
sibling temporary file is atomically substituted for an existing state. Old
Windows `.meta.json` and `.thumb.png` files are read only when their embedded
sections are absent; new saves never write them. Without usable metadata,
embedded disks get display-only tracking rather than keeping paths to previously
mounted files. Disk persistence otherwise follows the
existing Windows shell; MCP does not introduce a separate write-back policy.

The HTTP handler only returns the common MCP handler's bytes. Frame publication
belongs to the host/application commands; initialize, ping, tools/list and
malformed messages do not dispatch to UI or redraw the window.

Windows currently has no cassette UI. The host therefore uses the protocol's
default cassette operations under the machine lock.

## Validation

Build the modified Core DLL locally before testing the app. A published build
must first pin a released Core version containing the new session API; 1.10.0
does not contain it. Follow the repository's Core release workflow rather than
creating release tags by hand.

```powershell
swift test --package-path ..\Bubilator88Core
dotnet build windows/Bubilator88.Windows -p:Platform=x64

# Includes the actual Swift DLL and reverse-P/Invoke tests, in addition to
# transport tests. Swift runtime DLLs must be available on PATH.
$env:B88_MCP_TEST_DLL = (Resolve-Path '..\Bubilator88Core\.build\debug\Bubilator88C.dll').Path
dotnet test windows/Bubilator88.Windows.Tests
./scripts/check-windows-capi-exports.ps1
```

Without `B88_MCP_TEST_DLL`, native integration tests are explicitly
skipped. They exercise authenticated HTTP through the real Core, app-host
real-time state, frame execution, host errors, callback cancellation and safe
session disposal. Production `EmulatorHost.Media.cs` is also tested against
the DLL for concurrent protected mounts, embedded AMTA/THMB and legacy sidecar
reading. Tests cover failed atomic writes, restoration after command errors,
and cancellation before/after a UI callback starts. Core tests separately cover
legacy APIs, typed callbacks, session recreation and protection across the disk
swap delay. The pixel comparison regression suite still needs its
macOS reference environment before committing Core source changes.
