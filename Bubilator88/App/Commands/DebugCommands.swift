import AppKit
import SwiftUI

/// Develop Menu
struct DebugCommands: Commands {
  @Bindable var viewModel: EmulatorViewModel
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandMenu("Develop") {
      Group {
        Button("Debugger…") {
          openWindow(id: "debugger")
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])

        Toggle("Allow Control from AI Tools", isOn: $viewModel.automationEnabled)

        Divider()

        #if DEBUG
        Button("Dump Text DMA Snapshot") {
          viewModel.dumpTextDMASnapshotToDefaultPath()
        }
        #endif
        Button("Dump Memory…") {
          viewModel.dumpMemoryViaSavePanel()
        }

        Divider()

        Button("Play Script…") {
          viewModel.openAndPlayScript()
        }
        .disabled(viewModel.isRecordingScript)
        if viewModel.isPlayingScript {
          Button("Stop Script Playback") {
            viewModel.cancelScriptPlayback()
          }
        }

        if !viewModel.isRecordingScript {
          Button("Record Script…") {
            viewModel.startScriptRecording()
          }
          .disabled(viewModel.isPlayingScript)
        } else {
          Button("Stop Recording and Save…") {
            viewModel.stopScriptRecordingAndSave()
          }
        }

        Divider()

        Button("Open BIOS ROM Folder") {
          Self.openBIOSROMFolder()
        }

        Button("Reset Settings") {
          Self.resetSettings()
        }

        Divider()

        Toggle("Show Text Layer", isOn: $viewModel.debugTextLayerEnabled)

        Toggle("Exempt Text from Scanlines", isOn: $viewModel.debugTextScanlineExempt)
          .disabled(!viewModel.effectiveScanlineEnabled)

        Divider()

        Toggle("FM", isOn: $viewModel.fmEnabled)

        Toggle("SSG", isOn: $viewModel.ssgEnabled)

        Toggle("ADPCM", isOn: $viewModel.adpcmEnabled)

        Toggle("Rhythm", isOn: $viewModel.rhythmEnabled)

        Divider()

        // Not persisted; each takes effect at the next reset.
        Toggle("Use Built-in Font ROM", isOn: $viewModel.forceBuiltInFont)

        Toggle("Use Built-in Kanji ROM", isOn: $viewModel.forceBuiltInKanji)

        Toggle("Use Built-in Rhythm Samples", isOn: $viewModel.forceBuiltInRhythm)

        Divider()

        Toggle("Preserve Pitch at Fast Speeds", isOn: $viewModel.pitchPreservingSpeed)

        Toggle("Force YM2203 (OPN)", isOn: $viewModel.forceOPNMode)

        Divider()

        Picker("CPU Overclock", selection: $viewModel.cpuOverclock) {
          Text("1× (Real)").tag(1)
          Text("2×").tag(2)
          Text("4×").tag(4)
        }
      }
      .disabled(!viewModel.allows(.develop))
    }
  }

  /// Reveals the Application Support directory — where BIOS ROMs and friends
  /// live — in Finder, creating it first if it does not exist yet.
  private static func openBIOSROMFolder() {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appending(component: "Bubilator88", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    NSWorkspace.shared.open(appSupport)
  }

  /// Deletes every user setting stored in UserDefaults, behind a confirmation
  /// alert. Some settings only take effect after a restart, which the alert says.
  private static func resetSettings() {
    let alert = NSAlert()
    alert.messageText = String(
      localized: "Reset all settings?",
      comment: "Confirmation alert title for the Develop menu's Reset Settings")
    alert.informativeText = String(
      localized: """
      Every user preference returns to its default. This cannot be undone, and \
      the app must be restarted for all of the changes to take effect.
      """,
      comment: "Confirmation alert body for the Develop menu's Reset Settings")
    alert.alertStyle = .warning
    alert.addButton(
      withTitle: String(localized: "Reset", comment: "Confirm button for Reset Settings"))
    alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    if let bundleID = Bundle.main.bundleIdentifier {
      UserDefaults.standard.removePersistentDomain(forName: bundleID)
    }
    UserDefaults.standard.synchronize()
  }
}
