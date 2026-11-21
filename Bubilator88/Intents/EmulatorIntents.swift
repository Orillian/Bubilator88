import AppIntents
import Foundation

/// Why an intent could not run.
nonisolated enum EmulatorIntentError: Error, CustomLocalizedStringResourceConvertible {
  /// The main window has not started the machine yet, or the ROMs are missing.
  case unavailable
  /// An operation lock (for example, control-zone editing) holds the action back.
  case locked
  /// The disk is neither mounted nor in the recent list.
  case diskNotFound
  /// The disk was found but could not be mounted; the app shows why.
  case diskNotOpened
  /// The screen could not be captured.
  case screenUnavailable
  /// Nothing is in drive 1, so there is no game to save.
  case noDisk

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .unavailable: "Bubilator88 is not ready."
    case .locked: "This can't be done right now."
    case .diskNotFound: "The disk was not found."
    case .diskNotOpened: "The disk could not be opened."
    case .screenUnavailable: "The screen is not available."
    case .noDisk: "No disk is inserted."
    }
  }
}

extension EmulatorViewModel {
  /// The view model, once `operation` is allowed; throws otherwise. Same gate
  /// as the menu bar and the Dock menu.
  ///
  /// An intent can launch the app, so this waits for the main window to load
  /// the ROMs and restore the resume state before giving up.
  static func forIntent(_ operation: LockableOperation) async throws -> EmulatorViewModel {
    var viewModel = AppIntentsHost.viewModel
    for _ in 0..<150 where viewModel == nil {
      try await Task.sleep(for: .milliseconds(100))
      viewModel = AppIntentsHost.viewModel
    }
    // Without ROMs a save or mount would act on an empty machine.
    guard let viewModel, viewModel.romLoaded else { throw EmulatorIntentError.unavailable }
    guard viewModel.allows(operation) else { throw EmulatorIntentError.locked }
    return viewModel
  }
}

nonisolated struct PauseEmulationIntent: AppIntent {
  static let title: LocalizedStringResource = "Pause Emulation"
  static let description = IntentDescription("Pauses the emulator.")
  // The machine runs only in the main window: a background launch would
  // never create it, and the intent would wait in vain.
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    try await EmulatorViewModel.forIntent(.emulation).pause()
    return .result()
  }
}

nonisolated struct ResumeEmulationIntent: AppIntent {
  static let title: LocalizedStringResource = "Resume Emulation"
  static let description = IntentDescription("Resumes the paused emulator.")
  // The machine runs only in the main window: a background launch would
  // never create it, and the intent would wait in vain.
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    try await EmulatorViewModel.forIntent(.emulation).resume()
    return .result()
  }
}

nonisolated struct ResetMachineIntent: AppIntent {
  static let title: LocalizedStringResource = "Reset Machine"
  static let description = IntentDescription("Resets the emulated PC-8801.")
  // The machine runs only in the main window: a background launch would
  // never create it, and the intent would wait in vain.
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    try await EmulatorViewModel.forIntent(.emulation).reset()
    return .result()
  }
}

nonisolated struct QuickSaveIntent: AppIntent {
  static let title: LocalizedStringResource = "Quick Save"
  static let description = IntentDescription("Saves the current state to the quick save slot.")
  // The machine runs only in the main window: a background launch would
  // never create it, and the intent would wait in vain.
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    let viewModel = try await EmulatorViewModel.forIntent(.state)
    // An intent that launched the app without resume would otherwise save a
    // freshly booted machine over the user's quick save.
    guard viewModel.drive0Info != nil else { throw EmulatorIntentError.noDisk }
    try viewModel.quickSaveReportingErrors()
    return .result()
  }
}

// Not `nonisolated` like the others: that cannot be applied to the mutable
// stored property `@Parameter` needs.
struct OpenDiskIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Disk"
  static let description = IntentDescription("Opens a disk in the drive or a recently used one.")
  static let openAppWhenRun = true

  @Parameter(title: "Disk")
  var disk: DiskImageEntity

  static var parameterSummary: some ParameterSummary {
    Summary("Open \(\.$disk)")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    let viewModel = try await EmulatorViewModel.forIntent(.media)
    // Remounting an open disk would reboot the game in progress.
    if viewModel.isDiskOpen(disk.id) { return .result() }
    // Mounting reports failure only with an alert, so success is judged by
    // its effect: a new mount session in drive 1, where Mount 0&1 always
    // puts the first image. It never opens the image picker.
    let before = viewModel.drive0Info?.id
    if let entry = Settings.shared.recentFiles(.disk).first(where: {
      DiskImageEntity.identifier(forPath: $0.filePath) == disk.id
    }) {
      viewModel.mountRecentFile(entry)
    } else if FileManager.default.fileExists(atPath: disk.id) {
      // Suggested while mounted but not in the recent list: a disk from a
      // playlist (whose recent entry is the playlist) or one that dropped off.
      viewModel.mountDisk(url: URL(filePath: disk.id), drive: -1)
    } else {
      throw EmulatorIntentError.diskNotFound
    }
    guard let after = viewModel.drive0Info?.id, after != before else {
      throw EmulatorIntentError.diskNotOpened
    }
    return .result()
  }
}
