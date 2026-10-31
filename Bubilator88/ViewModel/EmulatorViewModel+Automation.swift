import AppKit
import Foundation
@_spi(Debug) import Bubilator88Automation
@_spi(Debug) import Bubilator88Core

// MARK: - AI agent control (MCP)

extension EmulatorViewModel {

  /// Start or stop the AI tools server to match Settings.
  func applyAutomationSetting() {
    automationServer?.stop()
    automationServer = nil
    let settings = Settings.shared
    guard settings.automationEnabled,
          let port = UInt16(exactly: settings.automationPort), port >= 1024 else { return }
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    let handler = MCPHandler(tools: AutomationTools(host: AppAutomationHost(viewModel: self)),
                             serverVersion: version)
    let server = AutomationHTTPServer(port: port, token: settings.automationToken) { handler.handle($0) }
    server.onFailure = { [weak self] message in
      self?.showAlert(title: String(localized: "AI Control Unavailable", comment: ""), message: message)
    }
    server.start()
    automationServer = server
  }

  /// The command that registers this app with Claude Code.
  var automationSetupCommand: String {
    let settings = Settings.shared
    return "claude mcp add --transport http bubilator88 http://127.0.0.1:\(settings.automationPort)/mcp"
      + " --header \"Authorization: Bearer \(settings.automationToken)\""
  }

  func copyAutomationSetupCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(automationSetupCommand, forType: .string)
    showToast(String(localized: "Copied", comment: ""))
  }
}

/// The app's side of the AI tools: the machine the user sees, driven so that
/// the window, the debugger window and Settings follow along.
///
/// Called on the server's queue. Machine access goes through `emuQueue`;
/// anything that touches the view model hops to the main thread first.
nonisolated final class AppAutomationHost: AutomationHost, @unchecked Sendable {
  private weak var viewModel: EmulatorViewModel?
  private let pc88: PC88
  private let emuQueue: DispatchQueue
  let debugger: Debugger

  @MainActor init(viewModel: EmulatorViewModel) {
    self.viewModel = viewModel
    pc88 = viewModel.pc88
    emuQueue = viewModel.emuQueue
    debugger = viewModel.debugger
  }

  /// Run `body` on the main thread with the view model.
  private func onMain<T: Sendable>(_ body: @MainActor (EmulatorViewModel) throws -> T) throws -> T {
    try DispatchQueue.main.sync {
      try MainActor.assumeIsolated {
        guard let viewModel else { throw AutomationError("The emulator window is gone.") }
        return try body(viewModel)
      }
    }
  }

  func withMachine<T>(_ body: (PC88) throws -> T) throws -> T {
    try emuQueue.sync { try body(pc88) }
  }

  func runFrames(_ count: Int, beforeEach: (PC88) -> Bool) throws -> Int {
    // The AI takes the machine over: real-time running stops and stays
    // stopped, so the next look at the screen shows what these frames did.
    let viewModel = try onMain { viewModel in
      if viewModel.isRunning { viewModel.pause() }
      return viewModel
    }
    let frames = emuQueue.sync { () -> Int in
      var run = 0
      while run < count, beforeEach(pc88) {
        viewModel.applyCheats()
        pc88.runFrame()
        // Nothing plays while paused; drop the sound rather than let it
        // burst out when real time resumes.
        _ = pc88.takeAudioSamples()
        run += 1
        if debugger.isPaused { break }
      }
      return run
    }
    try onMain { $0.renderSingleFrame() }
    return frames
  }

  func setDebuggerAttached(_ attached: Bool) throws {
    try onMain { viewModel in
      viewModel.automationNeedsDebugger = attached
      viewModel.updateDebuggerAttachment()
    }
  }

  var isRunningInRealTime: Bool {
    (try? onMain { $0.isRunning }) ?? false
  }

  func setRunningInRealTime(_ running: Bool) throws {
    try onMain { viewModel in
      if running { viewModel.resume() } else { viewModel.pause() }
    }
  }

  /// The app has one reset, the front-panel RESET with the DIP switches
  /// applied; `cold` makes no difference here.
  func reset(cold: Bool, mode: BootMode?, clock8MHz: Bool?) throws {
    try onMain { viewModel in
      if let clock8MHz { Settings.shared.clock8MHz = clock8MHz }
      if let mode {
        viewModel._bootModeStorage = switch mode {
        case .n88v2: .n88v2
        case .n88v1h: .n88v1h
        case .n88v1s: .n88v1s
        case .nbasic: .n
        }
      }
      viewModel.performReset(resetTranslation: true)
    }
  }

  func mountDisk(drive: Int, url: URL, imageIndex: Int, writeProtected: Bool) throws -> String {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw AutomationError("Cannot read \(url.path): \(error.localizedDescription)")
    }
    var disks = D88Disk.parseAll(data: Array(data))
    guard !disks.isEmpty else {
      throw AutomationError("\(url.lastPathComponent) is not a D88 disk image.")
    }
    guard disks.indices.contains(imageIndex) else {
      throw AutomationError("\(url.lastPathComponent) holds \(disks.count) image(s); image \(imageIndex) does not exist.")
    }
    disks[imageIndex].writeProtected = disks[imageIndex].writeProtected || writeProtected
    let name = disks[imageIndex].name
    try onMain { viewModel in
      viewModel.mountDiskExplicit(disks: disks, imageIndex: imageIndex, url: url, drive: drive)
    }
    return name
  }

  func ejectDisk(drive: Int) throws {
    try onMain { $0.ejectDisk(drive: drive) }
  }

  func saveState(to url: URL) throws {
    try onMain { viewModel in
      let wasRunning = viewModel.isRunning
      if wasRunning { viewModel.stop() }
      defer { if wasRunning { viewModel.start() } }
      try viewModel.writeSaveState(to: url)
      viewModel.saveStateRevision += 1
    }
  }

  func loadState(from url: URL) throws {
    try onMain { viewModel in
      try viewModel.applySaveState(Data(contentsOf: url), from: url)
    }
  }
}
