import Bubilator88Core
import Foundation

/// Centralized persistent settings backed by UserDefaults.
///
/// All user preferences that survive across sessions live here.
/// Access via `Settings.shared`.
@Observable
final class Settings {
  static let shared = Settings()

  /// Every UserDefaults key this class owns, in one place.
  ///
  /// Both the `didSet` writers and the loader in `init` go through these, so a
  /// key exists as a literal exactly once. Renaming a member is safe; changing
  /// its string value silently discards the user's existing setting.
  enum Keys {
    // CPU / DIP switches
    static let clock8MHz                 = "clock8MHz"
    static let dipSw1                    = "dipSw1"
    static let dipSw2Base                = "dipSw2Base"
    static let monitorType               = "monitorType"
    static let memoryWaitDip             = "memoryWaitDip"
    static let extramCards               = "extramCards"

    // Audio
    static let volume                    = "volume"
    static let pseudoStereo              = "pseudoStereo"
    static let cdMix                     = "cdMix"
    static let audioBufferMs             = "audioBufferMs"
    static let pitchPreservingSpeed      = "pitchPreservingSpeed"
    // The only member whose key differs from its property name: the setting was
    // renamed but the key was deliberately left alone, since changing it would
    // discard the choice of every user who already had it set.
    static let immersiveAudio            = "spatialAudio"
    static let immersivePositions        = "immersivePositions"
    static let fddSound                  = "fddSound"
    static let fddSoundDeviceUID         = "fddSoundDeviceUID"
    static let fddSoundVolumeLevel       = "fddSoundVolumeLevel"

    // UI
    static let showDebugMenu             = "showDebugMenu"
    static let tapeAutoBoot              = "tapeAutoBoot"
    static let resetAnimationEnabled     = "resetAnimationEnabled"
    static let showTapeInStatusBar       = "showTapeInStatusBar"
    static let showCDInStatusBar         = "showCDInStatusBar"
    static let diskThumbnails            = DiskThumbnailSetting.key

    // Update check
    static let automaticUpdateCheck      = "automaticUpdateCheck"
    static let resumeOnLaunch            = "resumeOnLaunch"
    static let runInBackground           = "runInBackground"
    static let backgroundAudio           = "backgroundAudio"
    static let automationEnabled         = "automationEnabled"
    static let automationPort            = "automationPort"
    static let automationToken           = "automationToken"
    static let automationClient          = "automationClient"
    static let lastUpdateCheck           = "lastUpdateCheck"
    static let updateRemindAfter         = "updateRemindAfter"
    static let skippedUpdateVersion      = "skippedUpdateVersion"

    // Video
    static let videoFilter               = "videoFilter"
    static let scanlineEnabled           = "scanlineEnabled"
    static let windowScale               = "windowScale"
    static let fullscreenIntegerScaling  = "fullscreenIntegerScaling"  // legacy Bool, read once for migration
    static let fullscreenScaling         = "fullscreenScaling"

    // Screenshot
    static let screenshotFormat          = "screenshotFormat"
    static let screenshotAutoSave        = "screenshotAutoSave"
    static let screenshotDirectory       = "screenshotDirectory"

    // Audio / video / script recording
    static let recordingFormat           = "recordingFormat"
    static let recordingSeparation       = "recordingSeparation"
    static let recordingAutoSave         = "recordingAutoSave"
    static let recordingDirectory        = "recordingDirectory"
    static let videoRecordingFormat      = "videoRecordingFormat"
    static let videoRecordingAutoSave    = "videoRecordingAutoSave"
    static let videoRecordingDirectory   = "videoRecordingDirectory"
    static let scriptRecordingAutoSave   = "scriptRecordingAutoSave"
    static let scriptRecordingDirectory  = "scriptRecordingDirectory"

    // Game controller / mouse
    static let gameControllerEnabled     = "gameControllerEnabled"
    static let controllerHapticEnabled   = "controllerHapticEnabled"
    static let controllerMappings        = "controllerMappings"
    static let mouseEnabled              = "mouseEnabled"
    static let mouseJoyMode              = "mouseJoyMode"
    static let mouseSensitivity          = "mouseSensitivity"
    static let clickZonesEnabled         = "clickZonesEnabled"
    static let clickZoneUsesController   = "clickZoneUsesController"
    static let clickZonesAlwaysVisible   = "clickZonesAlwaysVisible"
    static let clickZoneConfirmButton    = "clickZoneConfirmButton"

    // Keyboard
    static let arrowKeysAsNumpad         = "arrowKeysAsNumpad"
    static let numberRowAsNumpad         = "numberRowAsNumpad"
    static let wasdAsNumpad              = "wasdAsNumpad"
    static let specialKeyMapping         = "specialKeyMapping"
    static let keyboardLayout            = "keyboardLayout"

    // Translation
    static let translationTargetLanguage = "translationTargetLanguage"

    // Recent files
    static let recentDiskFiles           = "recentDiskFiles"
    static let recentTapeFiles           = "recentTapeFiles"
    static let recentCDFiles             = "recentCDFiles"
  }

  /// CPU clock mode (true = 8 MHz, false = 4 MHz).
  var clock8MHz: Bool = false {
    didSet { UserDefaults.standard.set(clock8MHz, forKey: Keys.clock8MHz) }
  }

  /// Master volume level (0.0–1.0).
  var volume: Float = 0.5 {
    didSet { UserDefaults.standard.set(volume, forKey: Keys.volume) }
  }

  /// Pseudo-stereo: chorus effect on mono FM output for stereo widening.
  var pseudoStereo: Bool = false {
    didSet { UserDefaults.standard.set(pseudoStereo, forKey: Keys.pseudoStereo) }
  }

  /// CD mix: output low-pass + stereo reverb, fitted against a 1989 game-music
  /// CD. Taste rather than hardware accuracy, so it stays opt-in.
  var cdMix: Bool = false {
    didSet { UserDefaults.standard.set(cdMix, forKey: Keys.cdMix) }
  }

  // MARK: - DIP Switches

  /// DIP switch 1 (port 0x30 read). Applied on reset.
  var dipSw1: UInt8 = 0xC3 {
    didSet { UserDefaults.standard.set(Int(dipSw1), forKey: Keys.dipSw1) }
  }

  /// DIP switch 2 base value (port 0x31 read, excluding bit 3 which is dynamic).
  /// Applied on reset.
  var dipSw2Base: UInt8 = 0x71 {
    didSet { UserDefaults.standard.set(Int(dipSw2Base), forKey: Keys.dipSw2Base) }
  }

  /// Attached monitor — DIP SW1 bit 8 ("CRT モード") on real hardware.
  /// Applied on reset.
  ///
  /// It is not part of `dipSw1`: that byte is literally what port 0x30 reads
  /// back, and `SPECS/DIP_SWITCH.md` shows port 0x30 only carries SW1-1…SW1-5.
  /// Bit 8 has no port-0x30 representation, so it needs its own storage. The
  /// read-back for software is port 0x40 bit 1 (SHG).
  ///
  /// 24kHz is the default: it is what a PC-8801-FA ships with, and it is what
  /// the emulator already reported to software before 1.5.0, so no title sees
  /// its SHG answer change.
  var monitorType: MonitorType = .khz24 {
    didSet { UserDefaults.standard.set(monitorType.rawValue, forKey: Keys.monitorType) }
  }

  /// Memory wait DIP (DIP SW1 bit 6). ON adds one wait state to main memory,
  /// TVRAM and graphic-off GVRAM accesses — see `MEMORY_WAIT_STATES.md` §2.
  ///
  /// Like DIP SW1 bit 8 above, it has no port-0x30 representation, so it gets
  /// its own storage instead of a bit in `dipSw1`. Software cannot read it
  /// back at all. Off by default, matching BubiC's `DIPSWITCH_DEFAULT`.
  /// Applied on reset.
  var memoryWaitDip: Bool = false {
    didSet { UserDefaults.standard.set(memoryWaitDip, forKey: Keys.memoryWaitDip) }
  }

  /// Extended RAM card count. Applied on reset (disk reload).
  /// 0 = none, 1 = 128KB, 8 = 1MB. Encoding follows QUASI88 `use_extram`.
  var extramCards: Int = 1 {
    didSet { UserDefaults.standard.set(extramCards, forKey: Keys.extramCards) }
  }

  // MARK: - UI

  /// Show the Develop menu in the menu bar.
  var showDebugMenu: Bool = false {
    didSet { UserDefaults.standard.set(showDebugMenu, forKey: Keys.showDebugMenu) }
  }

  /// Boot a cassette as soon as it is opened: eject the disks, reset into
  /// V1S, `LOAD "CAS:"` and `RUN` (Tape > Auto Boot).
  var tapeAutoBoot: Bool = false {
    didSet { UserDefaults.standard.set(tapeAutoBoot, forKey: Keys.tapeAutoBoot) }
  }

  /// Play a Thanos-style dissolve animation when the user resets the machine.
  var resetAnimationEnabled: Bool = true {
    didSet { UserDefaults.standard.set(resetAnimationEnabled, forKey: Keys.resetAnimationEnabled) }
  }

  /// Let Finder boot `.d88` images to draw their thumbnails. Read by the
  /// Quick Look extension through `DiskThumbnailSetting`.
  var diskThumbnails: Bool = true {
    didSet { UserDefaults.standard.set(diskThumbnails, forKey: Keys.diskThumbnails) }
  }

  // MARK: - Update Check

  /// Check the release feed for a newer version at launch.
  var automaticUpdateCheck: Bool = true {
    didSet { UserDefaults.standard.set(automaticUpdateCheck, forKey: Keys.automaticUpdateCheck) }
  }

  /// Restore the state saved at the last quit when the app launches. The
  /// state is saved on every quit either way; this only gates the restore.
  var resumeOnLaunch: Bool = false {
    didSet { UserDefaults.standard.set(resumeOnLaunch, forKey: Keys.resumeOnLaunch) }
  }

  /// Keep emulating while the window is hidden (occluded, minimized or on
  /// another Space). Off, the emulator parks until the window is seen again.
  var runInBackground: Bool = false {
    didSet { UserDefaults.standard.set(runInBackground, forKey: Keys.runInBackground) }
  }

  /// Let the sound through while `runInBackground` keeps a hidden window
  /// running. Off, it is muted until the window is seen again.
  var backgroundAudio: Bool = false {
    didSet { UserDefaults.standard.set(backgroundAudio, forKey: Keys.backgroundAudio) }
  }

  /// Serve the MCP tools to AI agents on 127.0.0.1:`automationPort`.
  var automationEnabled: Bool = false {
    didSet { UserDefaults.standard.set(automationEnabled, forKey: Keys.automationEnabled) }
  }

  static let defaultAutomationPort = 18801

  var automationPort: Int = Settings.defaultAutomationPort {
    didSet { UserDefaults.standard.set(automationPort, forKey: Keys.automationPort) }
  }

  /// The bearer token AI agents send with every request. Made and saved by
  /// `init` on the first launch; it keeps web pages, which cannot learn it,
  /// from reaching the server.
  private(set) var automationToken: String = ""

  /// The client Settings last showed the registration for.
  var automationClient: AutomationClient = .claudeCode {
    didSet { UserDefaults.standard.set(automationClient.rawValue, forKey: Keys.automationClient) }
  }

  /// Ports the AI tools server may listen on: the unprivileged ones.
  static let automationPortRange = 1024...65535

  /// When the release feed was last fetched by the launch check.
  var lastUpdateCheck: Date? {
    didSet { UserDefaults.standard.set(lastUpdateCheck, forKey: Keys.lastUpdateCheck) }
  }

  /// "Remind Me Later" was chosen; the launch check stays quiet until then.
  var updateRemindAfter: Date? {
    didSet { UserDefaults.standard.set(updateRemindAfter, forKey: Keys.updateRemindAfter) }
  }

  /// A version the user chose to skip, as written in the release tag (`v1.6.0`).
  var skippedUpdateVersion: String? {
    didSet { UserDefaults.standard.set(skippedUpdateVersion, forKey: Keys.skippedUpdateVersion) }
  }

  // MARK: - Video Filter

  /// Video filter mode (raw value of VideoFilter enum).
  var videoFilter: String = "None" {
    didSet { UserDefaults.standard.set(videoFilter, forKey: Keys.videoFilter) }
  }

  /// Scanline overlay enabled (only effective with None/Linear/Bicubic filters).
  var scanlineEnabled: Bool = false {
    didSet { UserDefaults.standard.set(scanlineEnabled, forKey: Keys.scanlineEnabled) }
  }

  /// Window scale factor (1, 2, or 4).
  var windowScale: Int = 1 {
    didSet { UserDefaults.standard.set(windowScale, forKey: Keys.windowScale) }
  }

  /// Fullscreen scaling mode: fit to screen, integer scaling (pixel-perfect), or 4:3 pixel-aspect correction.
  var fullscreenScaling: FullscreenScaling = .fit {
    didSet { UserDefaults.standard.set(fullscreenScaling.rawValue, forKey: Keys.fullscreenScaling) }
  }

  /// Show cassette tape icon in the status bar.
  var showTapeInStatusBar: Bool = false {
    didSet { UserDefaults.standard.set(showTapeInStatusBar, forKey: Keys.showTapeInStatusBar) }
  }

  /// Show the CD icon in the status bar.
  var showCDInStatusBar: Bool = false {
    didSet { UserDefaults.standard.set(showCDInStatusBar, forKey: Keys.showCDInStatusBar) }
  }

  /// Screenshot image format.
  var screenshotFormat: String = "png" {
    didSet { UserDefaults.standard.set(screenshotFormat, forKey: Keys.screenshotFormat) }
  }

  /// Auto-save screenshots to a preset directory instead of showing
  /// NSSavePanel every time. Default is true (auto-save to ~/Pictures).
  var screenshotAutoSave: Bool = true {
    didSet { UserDefaults.standard.set(screenshotAutoSave, forKey: Keys.screenshotAutoSave) }
  }

  /// The `Ask save location every time` toggle for screenshots: the inverse of
  /// `screenshotAutoSave`, so the UI can bind straight to it.
  var screenshotAskEveryTime: Bool {
    get { !screenshotAutoSave }
    set { screenshotAutoSave = !newValue }
  }

  /// Directory for auto-saved screenshots (absolute path). Nil means
  /// no directory has been chosen yet.
  var screenshotDirectory: String? {
    didSet {
      if let dir = screenshotDirectory {
        UserDefaults.standard.set(dir, forKey: Keys.screenshotDirectory)
      } else {
        UserDefaults.standard.removeObject(forKey: Keys.screenshotDirectory)
      }
    }
  }

  // MARK: - Audio Recording

  /// Audio recording format: "wav" (default), "alac", or "aac".
  var recordingFormat: String = "wav" {
    didSet { UserDefaults.standard.set(recordingFormat, forKey: Keys.recordingFormat) }
  }

  /// Audio recording channel mode: "separated" (8ch FM/SSG/ADPCM/Rhythm) or
  /// "stereo" (standard 2ch mix). AAC is always written as stereo regardless
  /// of this setting because AAC cannot encode 8-channel discrete layout.
  var recordingSeparation: String = "separated" {
    didSet { UserDefaults.standard.set(recordingSeparation, forKey: Keys.recordingSeparation) }
  }

  /// Auto-save recordings to a preset directory instead of showing
  /// NSSavePanel every time. Default is true (auto-save to ~/Music).
  var recordingAutoSave: Bool = true {
    didSet { UserDefaults.standard.set(recordingAutoSave, forKey: Keys.recordingAutoSave) }
  }

  /// The `Ask save location every time` toggle for audio recordings: the inverse of
  /// `recordingAutoSave`, so the UI can bind straight to it.
  var recordingAskEveryTime: Bool {
    get { !recordingAutoSave }
    set { recordingAutoSave = !newValue }
  }

  /// Directory for auto-saved recordings (absolute path). Nil means
  /// use the default ~/Music.
  var recordingDirectory: String? {
    didSet {
      if let dir = recordingDirectory {
        UserDefaults.standard.set(dir, forKey: Keys.recordingDirectory)
      } else {
        UserDefaults.standard.removeObject(forKey: Keys.recordingDirectory)
      }
    }
  }

  // MARK: - Video Recording

  /// Video recording format: "proRes4444" (default).
  var videoRecordingFormat: String = "proRes4444" {
    didSet { UserDefaults.standard.set(videoRecordingFormat, forKey: Keys.videoRecordingFormat) }
  }

  /// Auto-save video recordings to a preset directory instead of showing
  /// NSOpenPanel every time. Default is true (auto-save to ~/Movies).
  var videoRecordingAutoSave: Bool = true {
    didSet { UserDefaults.standard.set(videoRecordingAutoSave, forKey: Keys.videoRecordingAutoSave) }
  }

  /// The `Ask save location every time` toggle for video recordings: the inverse of
  /// `videoRecordingAutoSave`, so the UI can bind straight to it.
  var videoRecordingAskEveryTime: Bool {
    get { !videoRecordingAutoSave }
    set { videoRecordingAutoSave = !newValue }
  }

  /// Directory for auto-saved video recordings (absolute path). Nil means
  /// use the default ~/Movies.
  var videoRecordingDirectory: String? {
    didSet {
      if let dir = videoRecordingDirectory {
        UserDefaults.standard.set(dir, forKey: Keys.videoRecordingDirectory)
      } else {
        UserDefaults.standard.removeObject(forKey: Keys.videoRecordingDirectory)
      }
    }
  }

  /// Auto-save recorded operation scripts (.b88script) to a preset directory
  /// instead of showing NSSavePanel every time. Default true (~/Documents).
  var scriptRecordingAutoSave: Bool = true {
    didSet { UserDefaults.standard.set(scriptRecordingAutoSave, forKey: Keys.scriptRecordingAutoSave) }
  }

  /// The `Ask save location every time` toggle for recorded scripts: the inverse of
  /// `scriptRecordingAutoSave`, so the UI can bind straight to it.
  var scriptRecordingAskEveryTime: Bool {
    get { !scriptRecordingAutoSave }
    set { scriptRecordingAutoSave = !newValue }
  }

  /// Directory for auto-saved operation scripts (absolute path). Nil means
  /// use the default ~/Documents.
  var scriptRecordingDirectory: String? {
    didSet {
      if let dir = scriptRecordingDirectory {
        UserDefaults.standard.set(dir, forKey: Keys.scriptRecordingDirectory)
      } else {
        UserDefaults.standard.removeObject(forKey: Keys.scriptRecordingDirectory)
      }
    }
  }

  // MARK: - Audio

  /// Audio ring buffer size in milliseconds (20–500).
  var audioBufferMs: Int = 100 {
    didSet { UserDefaults.standard.set(audioBufferMs, forKey: Keys.audioBufferMs) }
  }

  /// Keep the pitch when the emulation speed is not x1: the sped-up output is
  /// time-stretched instead of resampled, so the music's tempo rises but its
  /// notes stay where they were. Off by default — the tape-style pitch rise is
  /// what every version so far has done, and time-stretching adds latency, CPU
  /// load and smearing at x8/x16. Takes effect on the next audio engine start.
  var pitchPreservingSpeed: Bool = false {
    didSet { UserDefaults.standard.set(pitchPreservingSpeed, forKey: Keys.pitchPreservingSpeed) }
  }

  /// Immersive audio: place YM2608 channels in 3D space (requires compatible headphones).
  var immersiveAudio: Bool = false {
    didSet { UserDefaults.standard.set(immersiveAudio, forKey: Keys.immersiveAudio) }
  }

  /// Immersive audio channel positions (x = L/R spread, z = front/back depth).
  var immersivePositions: ImmersiveAudioPositions = .defaults {
    didSet {
      if let data = try? JSONEncoder().encode(immersivePositions) {
        UserDefaults.standard.set(data, forKey: Keys.immersivePositions)
      }
    }
  }

  /// FDD access sound (synthesized seek/read sounds).
  var fddSound: Bool = true {
    didSet { UserDefaults.standard.set(fddSound, forKey: Keys.fddSound) }
  }

  /// Output device UID for the FDD access sound. An empty string means the
  /// system default.
  var fddSoundDeviceUID: String = "" {
    didSet { UserDefaults.standard.set(fddSoundDeviceUID, forKey: Keys.fddSoundDeviceUID) }
  }

  /// Volume level for the FDD access sound: 0=low (30%), 1=medium (60%),
  /// 2=high (100%). Defaults to high.
  var fddSoundVolumeLevel: Int = 2 {
    didSet { UserDefaults.standard.set(fddSoundVolumeLevel, forKey: Keys.fddSoundVolumeLevel) }
  }

  // MARK: - Game Controller

  /// Enable game controller input.
  var gameControllerEnabled: Bool = true {
    didSet { UserDefaults.standard.set(gameControllerEnabled, forKey: Keys.gameControllerEnabled) }
  }

  /// Enable haptic feedback on game controller during disk access.
  var controllerHapticEnabled: Bool = true {
    didSet { UserDefaults.standard.set(controllerHapticEnabled, forKey: Keys.controllerHapticEnabled) }
  }

  /// Per-controller-type button mappings (keyed by productCategory).
  var controllerMappings: [String: ControllerButtonMapping] = [:] {
    didSet {
      if let data = try? JSONEncoder().encode(controllerMappings) {
        UserDefaults.standard.set(data, forKey: Keys.controllerMappings)
      }
    }
  }

  // MARK: - Mouse

  /// Enable mouse input. When on, the host mouse is captured (cursor hidden +
  /// locked) while the window is key, and relative motion / left+right buttons
  /// are fed to the emulator via the OPN I/O ports.
  var mouseEnabled: Bool = false {
    didSet { UserDefaults.standard.set(mouseEnabled, forKey: Keys.mouseEnabled) }
  }

  /// Mouse read mode. false = bus mouse (PC-8872, strobed 4-phase nibble),
  /// true = joystick mode (mouse drives an Atari-spec joystick on the OPN
  /// port, for games like あーくしゅ that read the port as a joystick).
  var mouseJoyMode: Bool = false {
    didSet { UserDefaults.standard.set(mouseJoyMode, forKey: Keys.mouseJoyMode) }
  }

  /// Mouse movement sensitivity multiplier (0.5x – 3.0x).
  var mouseSensitivity: Float = 0.5 {
    didSet { UserDefaults.standard.set(mouseSensitivity, forKey: Keys.mouseSensitivity) }
  }

  /// Enable control zones: screen rectangles that type a key sequence when
  /// clicked, for games without mouse support. Only in effect while
  /// `mouseEnabled` is off.
  var clickZonesEnabled: Bool = false {
    didSet { UserDefaults.standard.set(clickZonesEnabled, forKey: Keys.clickZonesEnabled) }
  }

  /// Keep every control zone faintly outlined. Off, only the zone under the
  /// pointer, or the one the controller has focused, is shown.
  var clickZonesAlwaysVisible: Bool = false {
    didSet { UserDefaults.standard.set(clickZonesAlwaysVisible, forKey: Keys.clickZonesAlwaysVisible) }
  }

  /// Dedicate the controller's D-pad, left stick and confirm button to control
  /// zones: they move a focus between the zones and play the focused one, and
  /// cannot be mapped to keys. Only in effect while the game controller is
  /// enabled and the mounted disk has a layout with zones; otherwise the
  /// buttons keep their mapping.
  var clickZoneUsesController: Bool = true {
    didSet { UserDefaults.standard.set(clickZoneUsesController, forKey: Keys.clickZoneUsesController) }
  }

  /// The controller button that plays the focused control zone's keys
  /// (`ControllerButton.rawValue`).
  var clickZoneConfirmButton: String = ControllerButton.buttonX.rawValue {
    didSet { UserDefaults.standard.set(clickZoneConfirmButton, forKey: Keys.clickZoneConfirmButton) }
  }

  // MARK: - Keyboard

  /// Map arrow keys to numpad (↑→8, ↓→2, ←→4, →→6).
  var arrowKeysAsNumpad: Bool = false {
    didSet { UserDefaults.standard.set(arrowKeysAsNumpad, forKey: Keys.arrowKeysAsNumpad) }
  }

  /// Map number row keys (1-0) to numpad (kp1-kp0).
  var numberRowAsNumpad: Bool = false {
    didSet { UserDefaults.standard.set(numberRowAsNumpad, forKey: Keys.numberRowAsNumpad) }
  }

  /// Map WASD keys to numpad (W→8, A→4, S→2, D→6).
  var wasdAsNumpad: Bool = false {
    didSet { UserDefaults.standard.set(wasdAsNumpad, forKey: Keys.wasdAsNumpad) }
  }

  /// Custom key assignments for PC-8801 special keys (STOP, COPY, etc.).
  /// Keys: PC88SpecialKey.rawValue, Values: macOS keyCode as Int.
  var specialKeyMapping: [String: Int] = [:] {
    didSet {
      if let data = try? JSONEncoder().encode(specialKeyMapping) {
        UserDefaults.standard.set(data, forKey: Keys.specialKeyMapping)
      }
    }
  }

  // MARK: - Translation

  /// Target language for translation (maximal BCP 47 identifier, e.g. "en-Latn-US").
  var translationTargetLanguage: String = "en-Latn-US" {
    didSet { UserDefaults.standard.set(translationTargetLanguage, forKey: Keys.translationTargetLanguage) }
  }

  /// Keyboard layout detection mode.
  var keyboardLayout: KeyboardLayout = .auto {
    didSet { UserDefaults.standard.set(keyboardLayout.rawValue, forKey: Keys.keyboardLayout) }
  }

  /// Recently used disk files (max 10, newest first).
  var recentDiskFiles: [RecentDiskEntry] = []

  /// Recently used cassette-tape files (max 10, newest first). Stored
  /// in a separate list from disks so the two menus can be offered
  /// independently without mode cross-contamination.
  var recentTapeFiles: [RecentDiskEntry] = []

  /// Recently used CD images (max 10, newest first), a list of their own
  /// like the tapes.
  var recentCDFiles: [RecentDiskEntry] = []

  /// The media whose files each have their own Recent Files list.
  enum RecentFileKind {
    case disk, tape, cd

    fileprivate var list: ReferenceWritableKeyPath<Settings, [RecentDiskEntry]> {
      switch self {
      case .disk: \.recentDiskFiles
      case .tape: \.recentTapeFiles
      case .cd:   \.recentCDFiles
      }
    }

    fileprivate var defaultsKey: String {
      switch self {
      case .disk: Keys.recentDiskFiles
      case .tape: Keys.recentTapeFiles
      case .cd:   Keys.recentCDFiles
      }
    }
  }

  /// The recent list for `kind`.
  func recentFiles(_ kind: RecentFileKind) -> [RecentDiskEntry] {
    self[keyPath: kind.list]
  }

  /// Put a file at the top of its recent list (deduplicated, capped at 10).
  func addRecentFile(url: URL, kind: RecentFileKind) {
    guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
    let filePath = url.standardizedFileURL.path
    let entry = RecentDiskEntry(filePath: filePath, bookmark: bookmark,
                                displayName: url.lastPathComponent,
                                displayDir: abbreviatedDir(url.deletingLastPathComponent().path))
    var entries = self[keyPath: kind.list]
    entries.removeAll { $0.filePath == filePath }
    entries.insert(entry, at: 0)
    self[keyPath: kind.list] = Array(entries.prefix(10))
    persistRecentFiles(kind)
  }

  /// Remove a specific recent file entry.
  func removeRecentFile(_ entry: RecentDiskEntry, kind: RecentFileKind) {
    self[keyPath: kind.list].removeAll { $0.filePath == entry.filePath }
    persistRecentFiles(kind)
  }

  /// Clear one recent list.
  func clearRecentFiles(kind: RecentFileKind) {
    self[keyPath: kind.list] = []
    persistRecentFiles(kind)
  }

  private func persistRecentFiles(_ kind: RecentFileKind) {
    if let data = try? JSONEncoder().encode(self[keyPath: kind.list]) {
      UserDefaults.standard.set(data, forKey: kind.defaultsKey)
    }
  }

  private func loadRecentFiles() {
    for kind in [RecentFileKind.disk, .tape, .cd] {
      if let data = UserDefaults.standard.data(forKey: kind.defaultsKey),
         let entries = try? JSONDecoder().decode([RecentDiskEntry].self, from: data) {
        self[keyPath: kind.list] = entries
      }
    }
  }

  /// Abbreviate home directory in path display.
  private func abbreviatedDir(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) {
      return "~" + path.dropFirst(home.count)
    }
    return path
  }

  private init() {
    if let v = UserDefaults.standard.object(forKey: Keys.clock8MHz) as? Bool {
      clock8MHz = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.volume) {
      volume = min(1.0, max(0.0, (v as? NSNumber)?.floatValue ?? 0.5))
    }
    if let v = UserDefaults.standard.object(forKey: Keys.pseudoStereo) as? Bool {
      pseudoStereo = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.dipSw1) as? Int {
      dipSw1 = UInt8(v & 0xFF)
    }
    if let v = UserDefaults.standard.object(forKey: Keys.dipSw2Base) as? Int {
      dipSw2Base = UInt8(v & 0xFF)
    }
    if let v = UserDefaults.standard.object(forKey: Keys.monitorType) as? Int,
       let m = MonitorType(rawValue: v) {
      monitorType = m
    }
    if let v = UserDefaults.standard.object(forKey: Keys.memoryWaitDip) as? Bool {
      memoryWaitDip = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.extramCards) as? Int,
       [0, 1, 8].contains(v) {
      extramCards = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.tapeAutoBoot) as? Bool {
      tapeAutoBoot = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.showDebugMenu) as? Bool {
      showDebugMenu = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.resetAnimationEnabled) as? Bool {
      resetAnimationEnabled = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.diskThumbnails) as? Bool {
      diskThumbnails = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.automaticUpdateCheck) as? Bool {
      automaticUpdateCheck = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.resumeOnLaunch) as? Bool {
      resumeOnLaunch = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.runInBackground) as? Bool {
      runInBackground = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.automationEnabled) as? Bool {
      automationEnabled = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.automationPort) as? Int {
      automationPort = v
    }
    if let v = UserDefaults.standard.string(forKey: Keys.automationToken), !v.isEmpty {
      automationToken = v
    } else {
      // Two UUIDs' worth of randomness, without the dashes.
      automationToken = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
      UserDefaults.standard.set(automationToken, forKey: Keys.automationToken)
    }
    if let v = UserDefaults.standard.string(forKey: Keys.automationClient), let client = AutomationClient(rawValue: v) {
      automationClient = client
    }
    if let v = UserDefaults.standard.object(forKey: Keys.backgroundAudio) as? Bool {
      backgroundAudio = v
    }
    lastUpdateCheck = UserDefaults.standard.object(forKey: Keys.lastUpdateCheck) as? Date
    updateRemindAfter = UserDefaults.standard.object(forKey: Keys.updateRemindAfter) as? Date
    skippedUpdateVersion = UserDefaults.standard.string(forKey: Keys.skippedUpdateVersion)
    if let v = UserDefaults.standard.object(forKey: Keys.audioBufferMs) as? Int {
      audioBufferMs = max(20, min(500, v))
    }
    if let v = UserDefaults.standard.object(forKey: Keys.pitchPreservingSpeed) as? Bool {
      pitchPreservingSpeed = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.immersiveAudio) as? Bool {
      immersiveAudio = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.cdMix) as? Bool {
      cdMix = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.fddSound) as? Bool {
      fddSound = v
    }
    if let v = UserDefaults.standard.string(forKey: Keys.fddSoundDeviceUID) {
      fddSoundDeviceUID = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.fddSoundVolumeLevel) as? Int {
      fddSoundVolumeLevel = v
    }
    if let data = UserDefaults.standard.data(forKey: Keys.immersivePositions),
       let pos = try? JSONDecoder().decode(ImmersiveAudioPositions.self, from: data) {
      immersivePositions = pos
    }
    if let v = UserDefaults.standard.object(forKey: Keys.gameControllerEnabled) as? Bool {
      gameControllerEnabled = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.controllerHapticEnabled) as? Bool {
      controllerHapticEnabled = v
    }
    if let data = UserDefaults.standard.data(forKey: Keys.controllerMappings),
       let m = try? JSONDecoder().decode([String: ControllerButtonMapping].self, from: data) {
      controllerMappings = m
    }
    if let v = UserDefaults.standard.object(forKey: Keys.mouseEnabled) as? Bool {
      mouseEnabled = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.mouseJoyMode) as? Bool {
      mouseJoyMode = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.mouseSensitivity) {
      mouseSensitivity = (v as? NSNumber)?.floatValue ?? 0.5
    }
    if let v = UserDefaults.standard.object(forKey: Keys.clickZonesEnabled) as? Bool {
      clickZonesEnabled = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.clickZonesAlwaysVisible) as? Bool {
      clickZonesAlwaysVisible = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.clickZoneUsesController) as? Bool {
      clickZoneUsesController = v
    }
    if let v = UserDefaults.standard.string(forKey: Keys.clickZoneConfirmButton) {
      clickZoneConfirmButton = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.arrowKeysAsNumpad) as? Bool {
      arrowKeysAsNumpad = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.numberRowAsNumpad) as? Bool {
      numberRowAsNumpad = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.wasdAsNumpad) as? Bool {
      wasdAsNumpad = v
    }
    if let data = UserDefaults.standard.data(forKey: Keys.specialKeyMapping),
       let m = try? JSONDecoder().decode([String: Int].self, from: data) {
      specialKeyMapping = m
    }
    if let v = UserDefaults.standard.string(forKey: Keys.keyboardLayout),
       let layout = KeyboardLayout(rawValue: v) {
      keyboardLayout = layout
    }
    if let v = UserDefaults.standard.object(forKey: Keys.windowScale) as? Int, [1, 2, 4].contains(v) {
      windowScale = v
    }
    if let v = UserDefaults.standard.string(forKey: Keys.screenshotFormat),
       ["png", "jpeg", "heic"].contains(v) {
      screenshotFormat = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.screenshotAutoSave) as? Bool {
      screenshotAutoSave = v
    }
    screenshotDirectory = UserDefaults.standard.string(forKey: Keys.screenshotDirectory)
    if let v = UserDefaults.standard.string(forKey: Keys.recordingFormat),
       ["wav", "alac", "aac"].contains(v) {
      recordingFormat = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.recordingAutoSave) as? Bool {
      recordingAutoSave = v
    }
    if let v = UserDefaults.standard.string(forKey: Keys.recordingSeparation),
       ["separated", "stereo"].contains(v) {
      recordingSeparation = v
    }
    recordingDirectory = UserDefaults.standard.string(forKey: Keys.recordingDirectory)
    if let v = UserDefaults.standard.string(forKey: Keys.videoRecordingFormat),
       ["proRes4444", "h264Mp4"].contains(v) {
      videoRecordingFormat = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.videoRecordingAutoSave) as? Bool {
      videoRecordingAutoSave = v
    }
    videoRecordingDirectory = UserDefaults.standard.string(forKey: Keys.videoRecordingDirectory)
    if let v = UserDefaults.standard.object(forKey: Keys.scriptRecordingAutoSave) as? Bool {
      scriptRecordingAutoSave = v
    }
    scriptRecordingDirectory = UserDefaults.standard.string(forKey: Keys.scriptRecordingDirectory)
    if let raw = UserDefaults.standard.string(forKey: Keys.fullscreenScaling),
       let v = FullscreenScaling(rawValue: raw) {
      fullscreenScaling = v
    } else if let legacy = UserDefaults.standard.object(forKey: Keys.fullscreenIntegerScaling) as? Bool {
      // Before the 4:3 option existed this was a Bool.
      fullscreenScaling = legacy ? .integer : .fit
    }
    if let v = UserDefaults.standard.string(forKey: Keys.videoFilter) {
      videoFilter = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.scanlineEnabled) as? Bool {
      scanlineEnabled = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.showTapeInStatusBar) as? Bool {
      showTapeInStatusBar = v
    }
    if let v = UserDefaults.standard.object(forKey: Keys.showCDInStatusBar) as? Bool {
      showCDInStatusBar = v
    }
    if let v = UserDefaults.standard.string(forKey: Keys.translationTargetLanguage) {
      translationTargetLanguage = v
    }
    loadRecentFiles()
  }
}

// MARK: - Keyboard Layout

enum KeyboardLayout: String, CaseIterable, Identifiable {
  case auto = "auto"
  case jis = "jis"
  case us = "us"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .auto: return String(localized: "Auto-detect", comment: "Keyboard layout auto-detection")
    case .jis: return "JIS"
    case .us: return "US (ANSI)"
    }
  }
}

// MARK: - Immersive Audio Positions

/// Per-channel 3D positions for immersive audio.
/// x = L/R spread (0..1), z = front/back depth (-1..1, negative = front).
/// L channel at (-x, 0, z), R channel at (x, 0, z).
struct ImmersiveAudioPositions: Codable, Equatable {
  var fmX: Float = 0.5;     var fmZ: Float = -0.5
  var ssgX: Float = 0.5;    var ssgZ: Float = -0.5
  var adpcmX: Float = 0.3;  var adpcmZ: Float = -0.3
  var rhythmX: Float = 0.5; var rhythmZ: Float = 0.5

  static let defaults = ImmersiveAudioPositions()

  /// Channel labels and colors for UI.
  enum Channel: Int, CaseIterable {
    case fm, ssg, adpcm, rhythm

    var label: String {
      switch self {
      case .fm: return "FM"
      case .ssg: return "SSG"
      case .adpcm: return "ADPCM"
      case .rhythm: return "Rhythm"
      }
    }
  }

  /// Get position for a channel.
  func position(for ch: Channel) -> (x: Float, z: Float) {
    switch ch {
    case .fm:     return (fmX, fmZ)
    case .ssg:    return (ssgX, ssgZ)
    case .adpcm:  return (adpcmX, adpcmZ)
    case .rhythm: return (rhythmX, rhythmZ)
    }
  }

  /// Set position for a channel.
  mutating func setPosition(for ch: Channel, x: Float, z: Float) {
    let cx = min(1, max(0, x))
    let cz = min(1, max(-1, z))
    switch ch {
    case .fm:     fmX = cx; fmZ = cz
    case .ssg:    ssgX = cx; ssgZ = cz
    case .adpcm:  adpcmX = cx; adpcmZ = cz
    case .rhythm: rhythmX = cx; rhythmZ = cz
    }
  }

  /// Convert to AVAudio3DPoint array (8 elements: L/R pairs for FM, SSG, ADPCM, Rhythm).
  var spatialPoints: [(x: Float, y: Float, z: Float)] {
    var points: [(x: Float, y: Float, z: Float)] = []
    for ch in Channel.allCases {
      let p = position(for: ch)
      points.append((x: -p.x, y: 0, z: p.z))  // L
      points.append((x:  p.x, y: 0, z: p.z))  // R
    }
    return points
  }
}

// MARK: - Recent Disk Entry

struct RecentDiskEntry: Codable, Identifiable, Hashable {
  let filePath: String
  let bookmark: Data
  let displayName: String
  let displayDir: String

  var id: String { filePath }

  func hash(into hasher: inout Hasher) { hasher.combine(filePath) }
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.filePath == rhs.filePath }

  /// Resolve the bookmark back to a URL, granting sandbox access.
  ///
  /// A stale bookmark is kept rather than discarded, because the URL still
  /// works: write-back's atomic writes change the inode, which makes every
  /// bookmark stale, and discarding them would make recents unopenable. If
  /// resolving the bookmark fails outright, the filePath is tried directly.
  func resolveBookmark() -> URL? {
    var stale = false
    if let url = try? URL(resolvingBookmarkData: bookmark,
                          options: .withSecurityScope,
                          relativeTo: nil,
                          bookmarkDataIsStale: &stale) {
      return url
    }
    let fallback = URL(filePath: filePath)
    return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
  }
}
