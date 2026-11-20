import AppKit

/// Application delegate used only for shortcut-confirmation plumbing.
///
/// macOS lets Cmd+Q and Cmd+W tear the app/window down with a single
/// keypress. That's trivially easy to hit by accident while a game is
/// running, so we pop a confirmation dialog — **but only for the
/// keyboard-shortcut path**. Selecting the same command from the menu
/// bar skips the confirmation, on the theory that a deliberate menu
/// click already expresses intent.
///
/// Design:
/// - **Cmd+Q** flows through unchanged to `applicationShouldTerminate(_:)`,
///   which puts up the confirmation sheet. The keyDown monitor only records
///   that the terminate was shortcut-triggered (so a *menu* Quit skips the
///   prompt — the menu invokes the action directly, the monitor never fires).
/// - **Cmd+W** is intercepted *and swallowed* by the keyDown monitor, which
///   then drives the confirmation itself. We do this in the monitor rather than
///   from `NSWindowDelegate.windowShouldClose(_:)` because we must NOT become
///   the window's delegate: SwiftUI owns the `Window` scene's delegate, and
///   stealing it tears the window down on a backgrounded document open
///   (`.b88script` double-clicked while another app is frontmost) → the app
///   quits. The sheet is presented via `beginSheetModal` dispatched async, so
///   there is no nested-runloop reentrancy (the bug that originally pushed this
///   onto the delegate hook).
/// - Closing the main window cascades to the supplementary windows (Debugger)
///   via `NSWindow.willCloseNotification` — a notification, so again no delegate.
final class AppDelegate: NSObject, NSApplicationDelegate {
  override init() {
    // Handled before anything else touches `self`: `-h`/`-help`/`--help` must
    // print to stdout and exit without ever bringing up a window. This is the
    // earliest hook in the process (see the comment below), so it is also the
    // only point that can intercept a CLI `--help` before AppKit starts
    // building UI.
    if LaunchRequest.wantsHelp() {
      print(LaunchRequest.usageText)
      exit(0)
    }
    super.init()
    // Earliest hook in the process: `@NSApplicationDelegateAdaptor` is the
    // first stored property of `Bubilator88App`, so this runs before the view
    // model — and therefore before Bubilator88Core builds its loggers. See
    // bootstrapLogging() for why that ordering matters.
    bootstrapLogging()
  }

  /// Set by the root SwiftUI scene so terminate hooks can reach the
  /// recorder. Weak to avoid a retain cycle; the view model outlives
  /// the delegate in practice.
  weak var viewModel: EmulatorViewModel?

  private var shortcutMonitor: Any?
  private var rewindMonitor: Any?

  /// US-keyboard "z" virtual key code. Used to detect Cmd+Z hold for
  /// rewind regardless of localized character (Z is the same physical
  /// position on JIS as well, where keyCode 6 maps to "z").
  private static let rewindKeyCode: UInt16 = 6

  /// Title of the SwiftUI `Window("Bubilator88", id: "main")` scene. Used to
  /// identify the emulator window (the only window that carries it). One
  /// source of truth for the by-title matching the window observers rely on.
  private static let mainWindowTitle = "Bubilator88"
  private var rewindHoldActive = false

  /// Strong identity reference to the emulator window, captured the
  /// first time we observe it become key. Used by the rewind hold
  /// monitor to gate Cmd+Z so it doesn't engage while a Settings
  /// sheet, About panel, or Debugger window is foremost.
  private weak var emulatorWindow: NSWindow?

  /// True if the most recent terminate attempt was triggered by Cmd+Q.
  /// Cleared inside `applicationShouldTerminate(_:)` once consumed.
  private var lastTerminateWasShortcut = false

  /// Guards against stacking close-confirmation sheets when Cmd+W is hit
  /// repeatedly. Cleared when the sheet finishes.
  private var closeConfirmationActive = false

  // MARK: - NSApplicationDelegate

  func applicationDidFinishLaunching(_ notification: Notification) {
    shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      return self.handleShortcut(event)
    }
    rewindMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .keyUp, .flagsChanged]
    ) { [weak self] event in
      self?.handleRewindEvent(event) ?? event
    }
    // Cache the main window's identity the first time it becomes key
    // (used to gate Cmd+Z rewind and Cmd+W to the emulator window). We do
    // NOT set ourselves as its delegate — SwiftUI owns that.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(mainWindowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil
    )
    // Cascade-close supplementary windows (Debugger) when the main window
    // closes, so `applicationShouldTerminateAfterLastWindowClosed` can fire.
    // A notification, not a delegate method — see the type doc.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(mainWindowWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: nil
    )
    // NOTE: document opens (`.b88script` / `.d88` double-click / "Open With") are
    // handled by SwiftUI's `.onOpenURL` on the root scene, NOT here.
    //
    // We deliberately do NOT implement `application(_:open:)` nor install a
    // custom kAEOpenDocuments handler. Doing either makes AppKit route
    // document opens through its default open-document machinery, which —
    // for a singleton SwiftUI `Window` (no `DocumentGroup`) — tears down
    // the main window before delivering the URLs. That transient
    // zero-window moment trips `applicationShouldTerminateAfterLastWindowClosed`
    // and quietly quits the app on a warm open, and on a cold-launch open it
    // also leaves the MTKView's display link born dead (black screen).
    // Letting SwiftUI keep ownership via `.onOpenURL` avoids both: it fires
    // for cold AND warm opens, never touches the window, and the internal
    // display loop comes up alive. (Verified end-to-end, 2026-06-05.)

    Task { await UpdateChecker.shared.checkOnLaunch() }
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Finalize an in-progress recording. M4A/AAC needs its `moov` atom
    // written at close — skipping stopRecording here leaves the file
    // unreadable. Runs synchronously on the main thread before the
    // process exits.
    MainActor.assumeIsolated {
      viewModel?.stopRecording()
      // Auto-save silently if a recording is in progress; a save panel cannot
      // be shown during termination.
      viewModel?.flushScriptRecordingIfNeeded()
      // Flush unwritten disk changes to their files.
      viewModel?.diskWriteBackScheduler.flushAll()
      // After the flush, so the disk files and the state's embedded images
      // agree.
      viewModel?.saveResumeState()
    }
    if let monitor = shortcutMonitor {
      NSEvent.removeMonitor(monitor)
      shortcutMonitor = nil
    }
    if let monitor = rewindMonitor {
      NSEvent.removeMonitor(monitor)
      rewindMonitor = nil
    }
  }

  // MARK: - Rewind hold detection

  /// Returns nil to swallow the event (so SwiftUI's menu shortcut
  /// doesn't double-fire), or `event` to let it propagate normally.
  /// Only the `Cmd+Z` chord is intercepted; everything else passes
  /// through unchanged.
  private func handleRewindEvent(_ event: NSEvent) -> NSEvent? {
    // Only intercept Cmd+Z when the emulator window itself is key —
    // not a Settings sheet, About panel, or Debugger window where
    // Cmd+Z legitimately means "undo" in a text field. Identity
    // comparison rather than title matching so localization or any
    // future title change doesn't silently disable rewind.
    guard let emu = emulatorKeyWindow(), NSApp.keyWindow === emu else {
      return event
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let cmdOnly = flags.contains(.command)
      && flags.isDisjoint(with: [.shift, .option, .control])

    switch event.type {
    case .keyDown:
      if event.keyCode == Self.rewindKeyCode && cmdOnly {
        if !rewindHoldActive {
          rewindHoldActive = true
          MainActor.assumeIsolated {
            viewModel?.startRewindHold()
          }
        }
        return nil  // swallow (also suppresses menu shortcut + autorepeat)
      }
    case .keyUp:
      if event.keyCode == Self.rewindKeyCode && rewindHoldActive {
        rewindHoldActive = false
        MainActor.assumeIsolated {
          viewModel?.stopRewindHold()
        }
        return nil
      }
    case .flagsChanged:
      // User released Command before Z: end the hold immediately
      // so the emulator resumes from the current rewound frame.
      if rewindHoldActive && !flags.contains(.command) {
        rewindHoldActive = false
        MainActor.assumeIsolated {
          viewModel?.stopRewindHold()
        }
      }
    default:
      break
    }
    return event
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard lastTerminateWasShortcut else { return .terminateNow }
    lastTerminateWasShortcut = false
    // Nothing is lost when the next launch resumes, so there is nothing to
    // confirm.
    if MainActor.assumeIsolated({ Settings.shared.resumeOnLaunch }) { return .terminateNow }
    guard let host = mainEmulatorWindow() else {
      // Fallback: no host window → plain modal.
      MainActor.assumeIsolated { viewModel?.beginQuitDissolve() }
      let confirmed = confirmQuitShortcutModal()
      if !confirmed {
        MainActor.assumeIsolated { viewModel?.cancelQuitDissolve() }
      }
      return confirmed ? .terminateNow : .terminateCancel
    }
    MainActor.assumeIsolated { viewModel?.beginQuitDissolve() }
    presentQuitConfirmationSheet(on: host)
    // Defer the terminate decision until the sheet's completion handler
    // calls NSApp.reply(toApplicationShouldTerminate:).
    return .terminateLater
  }

  /// Rebuilt on every request so it shows the current run state and recent
  /// files. See `DockMenu`.
  @MainActor
  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    guard let viewModel else { return nil }
    return DockMenu.make(viewModel: viewModel)
  }

  /// Closing the main emulator window should tear the whole app down,
  /// including any supplementary windows (Debugger, etc.). Without
  /// this override, the app would stay alive with only the debugger
  /// visible — a state that has no meaning on its own.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  // MARK: - Window observers (notifications, not delegate)

  @objc private func mainWindowDidBecomeKey(_ note: Notification) {
    guard let window = note.object as? NSWindow,
          window.title == Self.mainWindowTitle else {
      return
    }
    // Cache identity for Cmd+Z / Cmd+W gating. Title-based comparison is
    // brittle (localization, in-flight setTitle calls, etc.) so we do it
    // once here and from then on rely on `===` identity. We deliberately do
    // not set ourselves as the window's delegate (see the type doc).
    if emulatorWindow == nil {
      emulatorWindow = window
    }
  }

  /// When the main emulator window closes, dismiss every other window so the
  /// "last window closed" check can fire and terminate the app. Without this
  /// the Debugger (and any other supplementary scene) would keep the process
  /// alive after the user has clearly asked to go away.
  @objc private func mainWindowWillClose(_ note: Notification) {
    guard let window = note.object as? NSWindow,
          window.title == Self.mainWindowTitle else {
      return
    }
    // The window is going away; any pending close confirmation is moot.
    // Reset the guard so a future window (or re-show) isn't left unable to
    // present the Cmd+W sheet because the flag latched true.
    closeConfirmationActive = false
    for other in NSApp.windows where other !== window && other.isVisible {
      other.close()
    }
  }

  // MARK: - Sheet / modal helpers

  private func mainEmulatorWindow() -> NSWindow? {
    return NSApp.windows.first { $0.title == Self.mainWindowTitle }
  }

  /// The cached main-window identity, resolved lazily by title if
  /// `didBecomeKey` hasn't captured it yet (it can miss when the window first
  /// becomes key before SwiftUI sets the title). Keeps Cmd+W / Cmd+Z gating
  /// reliable from the very first keypress after launch. Callers still
  /// `=== NSApp.keyWindow` so a non-key emulator window won't match.
  private func emulatorKeyWindow() -> NSWindow? {
    if emulatorWindow == nil { emulatorWindow = mainEmulatorWindow() }
    return emulatorWindow
  }

  private func presentQuitConfirmationSheet(on host: NSWindow) {
    let alert = makeQuitAlert()
    alert.beginSheetModal(for: host) { [weak self] response in
      let confirmed = (response == .alertFirstButtonReturn)
      if !confirmed {
        MainActor.assumeIsolated { self?.viewModel?.cancelQuitDissolve() }
      }
      NSApp.reply(toApplicationShouldTerminate: confirmed)
    }
  }

  private func presentCloseConfirmationSheet(on host: NSWindow) {
    let alert = makeCloseAlert()
    alert.beginSheetModal(for: host) { [weak self] response in
      self?.closeConfirmationActive = false
      if response == .alertFirstButtonReturn {
        host.close()
      } else {
        MainActor.assumeIsolated { self?.viewModel?.cancelQuitDissolve() }
      }
    }
  }

  /// Last-resort screen-centered modal used when no suitable host window
  /// exists (shouldn't happen in practice — the main window lives for the
  /// entire app session — but keeps Cmd+Q working if it ever does).
  private func confirmQuitShortcutModal() -> Bool {
    return makeQuitAlert().runModal() == .alertFirstButtonReturn
  }

  // MARK: - Shortcut detection

  /// Returns the event to let it propagate, or `nil` to swallow it. Only
  /// Cmd+W (on the emulator window) is swallowed — we drive its confirmation
  /// ourselves. Cmd+Q passes through to `applicationShouldTerminate`.
  private func handleShortcut(_ event: NSEvent) -> NSEvent? {
    // Only bare Command+<letter> counts. Cmd+Shift+Q etc. are left
    // alone so the user can still build custom shortcuts elsewhere.
    let required: NSEvent.ModifierFlags = .command
    let forbidden: NSEvent.ModifierFlags = [.shift, .option, .control]
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(required), flags.isDisjoint(with: forbidden) else { return event }
    guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return event }

    switch chars {
    case "q":
      lastTerminateWasShortcut = true
    case "w":
      // Only gate Cmd+W for the main emulator window. Settings /
      // About / Help sheets should still close with a single keypress.
      if let emu = emulatorKeyWindow(), NSApp.keyWindow === emu {
        if MainActor.assumeIsolated({ Settings.shared.resumeOnLaunch }) {
          // Same reasoning as Cmd+Q. Closed on the next run-loop turn, like
          // the sheet path, so the keyDown finishes dispatching first.
          DispatchQueue.main.async { emu.close() }
          return nil
        }
        requestCloseConfirmation(for: emu)
        return nil  // swallow so AppKit doesn't close the window now
      }
    default:
      break
    }
    return event
  }

  /// Present the Cmd+W close-confirmation sheet (async so the keyDown event
  /// finishes dispatching first — no nested-runloop reentrancy). On confirm,
  /// the sheet closes the window; on cancel it reverses the quit dissolve.
  ///
  /// Deliberately **not** `Task { @MainActor }`: what this needs is a run-loop
  /// turn, which `DispatchQueue.main.async` guarantees and a `Task` hop does
  /// not. Same reasoning as `Views/Debug/AudioPane.swift`.
  private func requestCloseConfirmation(for window: NSWindow) {
    guard !closeConfirmationActive else { return }
    closeConfirmationActive = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      MainActor.assumeIsolated { self.viewModel?.beginQuitDissolve() }
      self.presentCloseConfirmationSheet(on: window)
    }
  }

  // MARK: - Alert builders

  private func makeQuitAlert() -> NSAlert {
    let alert = NSAlert()
    alert.messageText = String(
      localized:       "Quit Bubilator88?",
      comment: "Confirmation dialog shown when Cmd+Q is pressed"
    )
    alert.informativeText = String(
      localized:       "Unsaved emulator state will be lost.",
      comment: "Cmd+Q confirmation body"
    )
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "Quit", comment: "Quit button"))
    alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button"))
    return alert
  }

  private func makeCloseAlert() -> NSAlert {
    let alert = NSAlert()
    alert.messageText = String(
      localized:       "Close the emulator window?",
      comment: "Confirmation dialog shown when Cmd+W is pressed on the main window"
    )
    alert.informativeText = String(
      localized:       "Unsaved emulator state will be lost.",
      comment: "Cmd+W confirmation body"
    )
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "Close", comment: "Close button"))
    alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button"))
    return alert
  }
}
