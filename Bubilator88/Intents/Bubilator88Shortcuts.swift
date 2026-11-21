import AppIntents

/// The intents Siri offers without setup. Phrase translations live in
/// `AppShortcuts.xcstrings`.
nonisolated struct Bubilator88Shortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: PauseEmulationIntent(),
                phrases: ["Pause \(.applicationName)"],
                shortTitle: "Pause",
                systemImageName: "pause.fill")
    AppShortcut(intent: ResumeEmulationIntent(),
                phrases: ["Resume \(.applicationName)"],
                shortTitle: "Resume",
                systemImageName: "play.fill")
    AppShortcut(intent: ResetMachineIntent(),
                phrases: ["Reset \(.applicationName)"],
                shortTitle: "Reset",
                systemImageName: "arrow.counterclockwise")
    AppShortcut(intent: QuickSaveIntent(),
                phrases: ["Quick save in \(.applicationName)"],
                shortTitle: "Quick Save",
                systemImageName: "square.and.arrow.down")
    AppShortcut(intent: OpenDiskIntent(),
                phrases: ["Open \(\.$disk) in \(.applicationName)",
                          "Open a disk in \(.applicationName)"],
                shortTitle: "Open Disk",
                systemImageName: "opticaldiscdrive")
  }
}
