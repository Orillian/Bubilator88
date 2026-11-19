import SwiftUI
import UniformTypeIdentifiers
import Bubilator88Core

// MARK: - Cassette Tape Operations

extension EmulatorViewModel {

  /// Mount a cassette-tape image (`.cmt` / `.t88`, or an archive
  /// containing one). Multi-entry archives mount the first hit — PC-88
  /// tape ZIPs in the wild are almost always single-file so a picker
  /// isn't justified here. Boots it when Tape > Auto Boot is on.
  @discardableResult
  func mountTape(url: URL) -> Bool {
    guard insertTape(url: url) else { return false }
    // Every way of opening a tape ends here, the picker and Recent Files alike.
    if Settings.shared.tapeAutoBoot { startTapeAutoBoot() }
    return true
  }

  /// Put a cassette in and show it, without booting it: what AI tools use,
  /// which boot a tape themselves and keep the machine paused.
  @discardableResult
  func insertTape(url: URL) -> Bool {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url) else {
      showAlert(
        title: String(localized: "Tape Load Error", comment: ""),
        message: "Could not read \(url.lastPathComponent)"
      )
      return false
    }
    // Unwrap archive if present.
    var tapeData = data
    if let entries = ArchiveExtractor.extractTapeImages(data) {
      guard let first = entries.first else {
        showAlert(
          title: String(localized: "Tape Load Error", comment: ""),
          message: "No .cmt or .t88 found in \(url.lastPathComponent)"
        )
        return false
      }
      tapeData = first.data
    }

    let format: TapeFormat = emuQueue.sync {
      pc88.mountTape(data: tapeData)
    }
    Settings.shared.addRecentFile(url: url, kind: .tape)
    tapeName = url.deletingPathExtension().lastPathComponent
    tapeSourceURL = url
    tapeFormat = format
    // Set here rather than waiting for the 4Hz sampler, so the menus and the
    // status bar update on the same run loop turn as the mount.
    isTapeMounted = true
    return true
  }

  /// Mount a previously-remembered tape via its security-scoped bookmark.
  func mountRecentTape(_ entry: RecentDiskEntry) {
    guard let url = entry.resolveBookmark() else {
      Settings.shared.removeRecentFile(entry, kind: .tape)
      showAlert(
        title: String(localized: "Tape Load Error", comment: ""),
        message: "Could not resolve \(entry.displayName)"
      )
      return
    }
    mountTape(url: url)
  }

  /// Boot the mounted tape (Tape > Auto Boot does this on every open): eject
  /// the disks and the CD, reset into N88-BASIC V1S, then type `LOAD "CAS:"` and, once it
  /// has loaded, `RUN`.
  ///
  /// V1S rather than the current mode because the tape routine is the same in
  /// every N88-BASIC mode and V1S is the one that gets to the prompt without
  /// a disk. The mode stays V1S afterwards.
  func startTapeAutoBoot() {
    guard isTapeMounted else { return }
    ejectDisk(drive: 0)
    ejectDisk(drive: 1)
    // A CD in at the reset fits the drive and the CD BIOS boots it instead.
    if isCDMounted { ejectCD() }
    rewindTape()
    // Tape software is written for 4MHz. The clock goes first so the reset
    // that `bootMode` makes picks it up; both stay that way afterwards.
    Settings.shared.clock8MHz = false
    // Resets the machine, and the reset cancels anything in flight, so the
    // sequencer is started only afterwards.
    bootMode = .n88v1s
    pasteQueueLock.lock()
    tapeAutoBoot.start()
    pasteQueueLock.unlock()
    // The sequencer is ticked by the frame loop, so a machine that is paused,
    // or has not been started yet, has to run for it to get anywhere.
    resume()
  }

  /// The Tape > Auto Boot check, shared by the menu bar and the status bar.
  var tapeAutoBootBinding: Binding<Bool> {
    Binding(
      get: { Settings.shared.tapeAutoBoot },
      set: { Settings.shared.tapeAutoBoot = $0 }
    )
  }

  /// Whether Auto Boot is still running.
  var isTapeAutoBootActive: Bool {
    pasteQueueLock.lock()
    defer { pasteQueueLock.unlock() }
    return tapeAutoBoot.isActive
  }

  /// Stop an Auto Boot in progress. Nothing already typed is taken back.
  func cancelTapeAutoBoot() {
    pasteQueueLock.lock()
    tapeAutoBoot.cancel()
    pasteQueueLock.unlock()
  }

  /// Advance Auto Boot by one frame. Called from the frame loop right after
  /// `tickPasteQueue()`, on the emulation thread, so the machine is read
  /// directly rather than through `emuQueue`.
  nonisolated func tickTapeAutoBoot() {
    pasteQueueLock.lock()
    guard tapeAutoBoot.isActive else {
      pasteQueueLock.unlock()
      return
    }
    if let text = tapeAutoBoot.tick(
      motorRunning: pc88.isTapeMotorRunning,
      tapeProgress: pc88.tapeProgress,
      typingIdle: pasteQueue.isEmpty,
      screen: { pc88.copyTextAsUnicode() }
    ) {
      pasteQueue.enqueue(text)
    }
    var stopped = false
    if case .failed = tapeAutoBoot.phase { stopped = true }
    pasteQueueLock.unlock()

    // It stopped without sending RUN. BASIC may well be stuck mid-load, so say
    // so rather than leave the user watching a screen that never changes.
    if stopped {
      DispatchQueue.main.async { [weak self] in
        self?.showToast(String(localized: "Tape Auto Boot stopped", comment: "Toast"))
      }
    }
  }

  /// Rewind tape to the beginning (keep it loaded).
  func rewindTape() {
    emuQueue.sync {
      pc88.rewindTape()
    }
    tapeProgress = 0
  }

  /// Eject the currently-loaded tape.
  func ejectTape() {
    cancelTapeAutoBoot()
    emuQueue.sync {
      pc88.ejectTape()
    }
    tapeName = "Empty"
    tapeSourceURL = nil
    tapeFormat = nil
    tapeProgress = 0
    isTapeMounted = false
  }
}
