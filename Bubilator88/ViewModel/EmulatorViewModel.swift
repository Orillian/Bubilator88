import SwiftUI
import MetalKit
import Synchronization
@_spi(Debug) import Bubilator88Core

/// ViewModel that drives the emulator and provides screen output to SwiftUI.
///
/// The machine runs on `EmulationLoop`'s dedicated thread, serialized by
/// `emuQueue`. Completed frames reach the Metal view through `FramePublisher`;
/// host input reaches the machine through `InputEventQueue`.
@Observable
final class EmulatorViewModel {

  // MARK: - Boot Mode

  /// PC-8801 boot mode — determines ROM, clock speed, and DIP switch config.
  enum BootMode: String, CaseIterable {
    case n88v2  = "N88-BASIC V2"
    case n88v1h = "N88-BASIC V1H"
    case n88v1s = "N88-BASIC V1S"
    case n      = "N-BASIC"
    case custom = "Custom"

    /// Standard (non-custom) modes for menu display.
    static var standardCases: [BootMode] { [.n88v2, .n88v1h, .n88v1s, .n] }

    /// Short label for the status bar.
    var shortLabel: String {
      switch self {
      case .n88v2:  return "V2"
      case .n88v1h: return "V1H"
      case .n88v1s: return "V1S"
      case .n:      return "N"
      case .custom: return "Custom"
      }
    }

    /// Default clock speed for this mode
    var is8MHz: Bool {
      self == .n88v2
    }

    /// DIP SW1 value (bit 0: 1=N88, 0=N; bit 1: 1=BASIC, 0=Terminal)
    /// BubiC: (mode==N ? 0 : 1) | 0xC2
    var dipSw1: UInt8 {
      switch self {
      case .n:      return 0xC2
      case .custom: return Settings.shared.dipSw1
      default:      return 0xC3
      }
    }

    /// DIP SW2 value (bit7=V1, bit6=H, bit3: 0=FDD boot, 1=ROM boot)
    /// Base value 0x31 from QUASI88/BubiC + mode flags, FDD boot default
    var dipSw2: UInt8 {
      switch self {
      case .n88v2:  return 0x71  // 0x31 | H(0x40), FDD boot
      case .n88v1h: return 0xF1  // 0x31 | V1(0x80) | H(0x40), FDD boot
      case .n88v1s: return 0xB1  // 0x31 | V1(0x80), FDD boot
      case .n:      return 0xB1  // 0x31 | V1(0x80), FDD boot
      case .custom: return Settings.shared.dipSw2Base
      }
    }
  }

  // MARK: - Emulation Speed

  enum EmulationSpeed: String, CaseIterable {
    case x1 = "x1"
    case x2 = "x2"
    case x4 = "x4"
    case x8 = "x8"
    case x16 = "x16"

    var framesPerDraw: Int {
      switch self {
      case .x1: return 1
      case .x2: return 2
      case .x4: return 4
      case .x8: return 8
      case .x16: return 16
      }
    }

    var audioRate: Float {
      Float(framesPerDraw)
    }
  }

  var emulationSpeed: EmulationSpeed = .x1 {
    didSet {
      audio.setRate(emulationSpeed.audioRate)
      emulationLoop.setFramesPerStep(emulationSpeed.framesPerDraw)
    }
  }

  /// Temporary turbo mode (x8 speed while held).
  var turboMode: Bool = false {
    didSet {
      guard turboMode != oldValue else { return }
      // Recording sessions lock the timeline to wall-clock — refuse turbo
      // changes for the duration of the session.
      if videoRecorder.isRecording || audioRecorder.isRecording {
        turboMode = false
        return
      }
      if turboMode {
        savedSpeed = emulationSpeed
        emulationSpeed = .x8
      } else {
        emulationSpeed = savedSpeed
      }
    }
  }
  private var savedSpeed: EmulationSpeed = .x1

  // MARK: - Video Filter

  enum VideoFilter: String, CaseIterable {
    case none = "None"
    case linear = "Linear"
    case bicubic = "Bicubic"
    case crt = "CRT"
    case xbrz = "xBRZ"
    case enhanced = "Enhanced"
    case aiUpscaleFast = "AI Upscale (Fast)"
    case aiUpscaleBalanced = "AI Upscale (Balanced)"
    case aiUpscale = "AI Upscale (Quality)"

    var fragmentFunctionName: String {
      switch self {
      case .none: return "fragmentNearest"
      case .linear: return "fragmentLinear"
      case .bicubic: return "fragmentBicubic"
      case .crt: return "fragmentCRT"
      case .xbrz: return "fragmentXBRZ"
      case .enhanced: return "fragmentXBRZ"  // pass 2 uses xBRZ
      case .aiUpscaleFast: return "fragmentNearest"
      case .aiUpscaleBalanced: return "fragmentNearest"
      case .aiUpscale: return "fragmentNearest"  // AI texture is pre-upscaled
      }
    }

    var usesLinearSampler: Bool {
      self == .linear
    }

    var supportsScanlines: Bool {
      switch self {
      case .none, .linear, .bicubic: return true
      case .crt, .xbrz, .enhanced, .aiUpscaleFast, .aiUpscaleBalanced, .aiUpscale: return false
      }
    }

    var requiresAIUpscale: Bool {
      switch self {
      case .aiUpscaleFast, .aiUpscaleBalanced, .aiUpscale: return true
      default: return false
      }
    }

    /// Model name to load for this filter
    var aiModelName: String? {
      switch self {
      case .aiUpscaleFast: return "SRVGGNet_x2_lite"
      case .aiUpscaleBalanced: return "SRVGGNet_x2"
      case .aiUpscale: return "RealESRGAN_x2"
      default: return nil
      }
    }

    /// The model this filter needs when it is not bundled and must be
    /// downloaded first. Nil for every filter that works out of the box.
    var downloadableModel: DownloadableAIModel? {
      aiModelName.flatMap(AIModelStore.downloadableModel(named:))
    }
  }

  /// Selecting a filter whose model has not been downloaded does not switch to
  /// it: the setting keeps its current value and the download sheet opens
  /// instead. The switch happens once the model is installed.
  var videoFilter: VideoFilter {
    get { VideoFilter(rawValue: Settings.shared.videoFilter) ?? .none }
    set {
      if let model = newValue.downloadableModel, !AIModelStore.shared.isInstalled(model) {
        requestAIModelDownload(for: newValue)
        return
      }
      Settings.shared.videoFilter = newValue.rawValue
      pushVideoFilterToMetalView()
    }
  }

  /// The model download in progress or awaiting confirmation. Drives the
  /// download sheet; nil when none is showing.
  var aiModelDownload: AIModelDownloadSession?
  @ObservationIgnored var aiModelDownloadTask: Task<Void, Never>?
  /// Bumped whenever a downloadable model is installed or removed. Installed
  /// state lives on disk, where Observation cannot see it; reading this
  /// makes a view re-evaluate `isAIModelInstalled` when it changes.
  var aiModelStoreRevision: Int = 0

  var scanlineEnabled: Bool {
    get { Settings.shared.scanlineEnabled }
    set {
      Settings.shared.scanlineEnabled = newValue
      pushVideoFilterToMetalView()
    }
  }

  /// DEBUG-only experiment: keep the text layer out of the scanline dimming,
  /// the way XM8's SDL port does. Not persisted — always off at launch, since
  /// dimming everything uniformly is what a real CRT does.
  var debugTextScanlineExempt: Bool = false {
    didSet { pushVideoFilterToMetalView() }
  }

  var isScanlineAvailable: Bool {
    videoFilter.supportsScanlines
  }

  var effectiveScanlineEnabled: Bool {
    isScanlineAvailable && scanlineEnabled
  }

  /// Tag text pixels only while the exemption can actually take effect, so the
  /// alpha marks never reach the AI upscaler or any other consumer of the
  /// shared pixel buffer.
  var markTextPixelsForDisplay: Bool {
    effectiveScanlineEnabled && debugTextScanlineExempt
  }

  private func pushVideoFilterToMetalView() {
    syncLoopSettings()
    metalView?.updateVideoFilter(
      videoFilter,
      scanlineEnabled: effectiveScanlineEnabled,
      textScanlineExempt: debugTextScanlineExempt
    )
  }

  // MARK: - HQ Filter Debug Parameters

  var hqOffset: Float = 0.05
  var hqGradient: Float = 0.3
  var hqMaxBlend: Float = 0.3

  // MARK: - Published State (MainActor)

  /// Window scale factor (1, 2, or 4)
  var windowScale: Int {
    get { Settings.shared.windowScale }
    set { Settings.shared.windowScale = newValue }
  }

  /// Fullscreen mode
  var isFullScreen: Bool = false
  var showFullScreenOverlay: Bool = false

  /// Emulation running state
  var isRunning: Bool = false

  /// Whether the host cursor is currently captured (hidden + locked) for
  /// bus-mouse input. UI-facing flag, driven by `KeyEventView`.
  var mouseCapturing: Bool = false

  /// Whether a timeline script is currently playing back (live mode).
  /// UI-facing flag; the player itself lives in `scriptPlayer`.
  var isPlayingScript: Bool = false

  /// Whether operation recording is in progress (real input → `.b88script`).
  /// UI-facing flag; the recorder itself lives in `scriptRecorder`.
  var isRecordingScript: Bool = false

  // MARK: - Notifications (toast + alert)

  /// Toast message shown briefly over the emulator screen, auto-dismissed
  /// after 2 seconds. Nil when hidden.
  var currentToast: String?

  /// Alert requiring user acknowledgement. Nil when dismissed.
  var currentAlert: (title: String, message: String)?

  @ObservationIgnored private var toastDismissTask: Task<Void, Never>?

  func showToast(_ message: String) {
    toastDismissTask?.cancel()
    currentToast = message
    toastDismissTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      withAnimation { self?.currentToast = nil }
    }
  }

  func showAlert(title: String, message: String) {
    currentAlert = (title, message)
  }

  var alertIsPresented: Bool {
    get { currentAlert != nil }
    set { if !newValue { currentAlert = nil } }
  }
  var alertTitle: String { currentAlert?.title ?? "" }
  var alertMessage: String { currentAlert?.message ?? "" }

  /// ROM loaded state
  var romLoaded: Bool = false

  /// Measured frames per second (updated every second while running)
  var fps: Double = 0.0

  /// The machine's own VSYNC rate, published from the emulation thread.
  ///
  /// Exists so the status bar can explain a reading of "55 fps": that is the
  /// PC-8801 running correctly on a 24kHz monitor, not a dropped-frame
  /// problem. The machine has never actually run at 60Hz.
  var targetFrameRate: Double = 0.0

  /// Current boot mode (backing storage, also used for save state restore without reset)
  var _bootModeStorage: BootMode = .n88v2

  /// Current boot mode — triggers reset on change via UI.
  /// Setting a non-custom mode updates Settings.dipSw1/dipSw2Base.
  var bootMode: BootMode {
    get { _bootModeStorage }
    set {
      _bootModeStorage = newValue
      if newValue != .custom {
        Settings.shared.dipSw1 = newValue.dipSw1
        Settings.shared.dipSw2Base = newValue.dipSw2
      }
      applyBootMode()
    }
  }

  /// Effective boot mode derived from current DIP switch settings.
  var effectiveBootModePreset: BootModePreset {
    BootModePreset.from(dipSw1: Settings.shared.dipSw1, dipSw2Base: Settings.shared.dipSw2Base)
  }

  /// CPU clock mode — persisted via Settings.
  /// Applied on next reset, not immediately.
  var clock8MHz: Bool {
    get { Settings.shared.clock8MHz }
    set {
      Settings.shared.clock8MHz = newValue
      applyBootMode()
    }
  }

  /// CPU overclock multiplier (1/2/4) — Develop menu only, not persisted.
  /// Applies live without reset.
  var cpuOverclock: Int = 1 {
    didSet {
      let clamped = [1, 2, 4].contains(cpuOverclock) ? cpuOverclock : 1
      if clamped != cpuOverclock { cpuOverclock = clamped; return }
      emuQueue.sync { pc88.cpuOverclock = clamped }
    }
  }

  /// Master volume (0.0–1.0) — persisted via Settings.
  var volume: Float {
    get { Settings.shared.volume }
    set {
      Settings.shared.volume = newValue
      applyVolume()
    }
  }

  /// Show/hide the Develop menu — persisted via Settings.
  var showDebugMenu: Bool {
    get { Settings.shared.showDebugMenu }
    set { Settings.shared.showDebugMenu = newValue }
  }

  /// Pseudo-stereo chorus effect on mono FM — persisted via Settings.
  ///
  /// The flag lands on `emuQueue`, like the debug masks in `+Audio.swift`.
  /// These setters run on the main thread from the settings window while the
  /// sound core reads the same flags to generate samples
  /// (`RELEASE_1_5_0_PLAN.md` §3.3(c), §9.6).
  var pseudoStereo: Bool {
    get { Settings.shared.pseudoStereo }
    set {
      Settings.shared.pseudoStereo = newValue
      let enabled = newValue && !immersiveAudio
      emuQueue.async { [weak self] in
        self?.pc88.pseudoStereoEnabled = enabled
      }
    }
  }

  /// CD mix output stage: low-pass + stereo reverb — persisted via Settings.
  var cdMix: Bool {
    get { Settings.shared.cdMix }
    set {
      Settings.shared.cdMix = newValue
      emuQueue.async { [weak self] in
        self?.pc88.cdMixEnabled = newValue
      }
    }
  }

  /// Immersive audio: place YM2608 channels in 3D space — persisted via Settings.
  var immersiveAudio: Bool {
    get { Settings.shared.immersiveAudio }
    set {
      Settings.shared.immersiveAudio = newValue
      let chorus = pseudoStereo && !newValue
      // Both writes go in one block, in this order: disabling pseudo-stereo
      // *first* avoids a window where both flags are true and chorus-processed
      // FM leaks into the spatial buffer. A serial queue keeps that ordering,
      // which two separate hops would not guarantee.
      emuQueue.async { [weak self] in
        guard let self else { return }
        pc88.pseudoStereoEnabled = chorus
        pc88.immersiveOutputEnabled = newValue
      }
      restartAudio()
    }
  }

  /// Keep the pitch at non-x1 emulation speeds — persisted via Settings.
  ///
  /// The speed unit is chosen when the audio graph is built, so the engine has
  /// to come back up for the new choice to take; `restartAudio()` is a no-op
  /// while the emulator is stopped, and `start()` reads the setting anyway.
  var pitchPreservingSpeed: Bool {
    get { Settings.shared.pitchPreservingSpeed }
    set {
      Settings.shared.pitchPreservingSpeed = newValue
      restartAudio()
    }
  }

  /// Update immersive audio 3D positions live (called when user drags channel dots).
  func updateImmersivePositions() {
    audio.updateSpatialPositions()
  }

  /// Volume as integer percentage for display.
  var volumePercent: Int {
    Int((volume * 100).rounded())
  }

  /// Increase volume by 10%.
  func volumeUp() {
    let step = Int((volume * 10).rounded())
    volume = Float(min(10, step + 1)) / 10.0
  }

  /// Decrease volume by 10%.
  func volumeDown() {
    let step = Int((volume * 10).rounded())
    volume = Float(max(0, step - 1)) / 10.0
  }

  /// Currently active clock mode (reflects what Machine is actually using)
  private(set) var activeClock8MHz: Bool = true

  /// Sync the status-bar clock indicator to the machine's actual clock.
  /// Used by the script-playback path (a separate file, which can't reach
  /// the file-private setter) to reflect a script-set clock.
  ///
  /// **Call only with the loop stopped.** Both call sites (`performLaunch`,
  /// `adoptScriptSetup` via `playScript`) sit inside a `stop()` … `start()`
  /// window, which is why this reads `machine` without taking `emuQueue` —
  /// `ScriptPlayer` writes `machine.clock8MHz` from the emulation thread on a
  /// `clock` or `reset` step. Same rule as the deck read in `performLoad`
  /// (`RELEASE_1_5_0_PLAN.md` §3.3(e), §9.6). Calling it from a running loop
  /// needs an `emuQueue.sync` here instead.
  func syncActiveClockFromMachine() {
    activeClock8MHz = pc88.clock8MHz
  }

  /// Mounted disk names for UI display
  var drive0Name: String = "Empty"
  var drive1Name: String = "Empty"

  /// Original D88 file names (for save state display)
  var drive0FileName: String?
  var drive1FileName: String?

  /// Per-drive metadata for disk switching from menu
  var drive0Info: MountedDiskInfo?
  var drive1Info: MountedDiskInfo?

  /// Per-drive write-protect state, synced to the mounted D88Disk.
  var drive0WriteProtected: Bool = false
  var drive1WriteProtected: Bool = false

  /// Currently mounted cassette tape: display name ("Empty" when none),
  /// source URL (for save-state metadata / recent reload), and format.
  var tapeName: String = "Empty"
  var tapeSourceURL: URL?
  var tapeFormat: TapeFormat?
  var tapeProgress: Double = 0

  /// True when a tape image is mounted. Unlike disks, the tape bytes live
  /// entirely inside the save state, so mount truth is the engine's own
  /// `isLoaded` — not whether a source URL happens to be known.
  ///
  /// Mirrored here rather than read straight off `machine.cassette`, which is
  /// what this used to do. SwiftUI evaluates `ContentView.statusBar` on the
  /// main thread at moments of its own choosing, while `stepRewindBack()`
  /// rewrites the deck's buffer from the emulation thread — Thread Sanitizer
  /// caught exactly that pair during a ⌘Z hold. Core state reaches the UI by
  /// being published to it (`RELEASE_1_5_0_PLAN.md` §3.3(e)), never by the UI
  /// reaching into the core.
  ///
  /// Written at mount/eject/save-state load, and refreshed by the 4Hz sampler
  /// in `runFrameForMetal` so that changes the engine makes on its own — a
  /// rewind restoring a state with a different tape — still show up.
  var isTapeMounted: Bool = false

  /// The CD in the drive: display name ("Empty" when none) and source, which
  /// a save state records so the disc can be put back when it is loaded.
  var cdName: String = "Empty"
  var cdSourceURL: URL?
  var isCDMounted: Bool = false
  /// CDBIOS.ROM was found when the ROMs were loaded.
  var cdBiosAvailable: Bool = false
  /// CD access lamp, sampled at 4Hz like the drive lamps.
  var cdAccess: Bool = false

  /// Tape position as "NN%", for the status bar only. Menus show just the
  /// tape name: reading `tapeProgress` there re-evaluated them at the 4Hz
  /// sampler rate, which got in the way of using an open menu.
  var tapePositionLabel: String {
    "\(Int((tapeProgress * 100).rounded()))%"
  }

  /// Disk access LED indicators (true = active this frame)
  var drive0Access: Bool = false
  var drive1Access: Bool = false

  /// Sub-CPU debug info
  var subCpuInfo: String = ""

  /// File picker state (triggered from menu)
  var showingDiskPicker: Bool = false
  var diskPickerDrive: Int = 0

  /// Cassette-tape file picker state.
  var showingTapePicker: Bool = false
  var showingCDPicker: Bool = false
  var showingMemoryImagePicker: Bool = false

  /// Context for the selection sheet presented after a mount. nil hides the
  /// sheet. `Identifiable`, so it binds directly to `.sheet(item:)`.
  ///
  /// This one property replaces the former seven `pending*` properties and two
  /// `showing*Picker` flags.
  var pickerContext: DiskPickerContext?

  // MARK: - Compatibility shims for the former pending*/showing* properties
  //
  // Read-only and Bool properties backed by `pickerContext`, so existing View
  // and App code keeps working.

  var pendingDiskImages: [D88Disk] {
    if case .multiImageD88(let disks, _, _, _, _) = pickerContext { return disks }
    return []
  }
  var pendingDiskURL: URL? {
    if case .multiImageD88(_, let url, _, _, _) = pickerContext { return url }
    return nil
  }
  var pendingArchiveEntryName: String? {
    if case .multiImageD88(_, _, let name, _, _) = pickerContext { return name }
    return nil
  }
  var pendingOriginArchiveURL: URL? {
    if case .multiImageD88(_, _, _, let url, _) = pickerContext { return url }
    return nil
  }
  var pendingArchiveEntries: [ArchiveEntry] {
    if case .archiveEntries(let entries, _, _, _) = pickerContext { return entries }
    return []
  }
  var pendingArchiveURL: URL? {
    if case .archiveEntries(_, let url, _, _) = pickerContext { return url }
    return nil
  }
  var pendingArchiveCacheDir: URL? {
    if case .archiveEntries(_, _, let dir, _) = pickerContext { return dir }
    return nil
  }
  var showingImagePicker: Bool {
    get { if case .multiImageD88 = pickerContext { return true } else { return false } }
    set { if !newValue, case .multiImageD88 = pickerContext { pickerContext = nil } }
  }
  var showingArchiveFilePicker: Bool {
    get { if case .archiveEntries = pickerContext { return true } else { return false } }
    set { if !newValue, case .archiveEntries = pickerContext { pickerContext = nil } }
  }

  /// Number of rewind snapshots currently buffered. Observable so the
  /// Rewind menu item's `disabled` binding refreshes when the buffer
  /// fills/clears.
  var rewindSnapshotCount: Int = 0

  /// The emulation loop's copy of `isRewinding`.
  ///
  /// `isRewinding` itself is `@Observable` UI state and must stay on the main
  /// thread; the loop consults this mirror, flipped under `emuQueue` at the
  /// same moment.
  /// Last frame rate handed to the pacer. Emulation-thread only (it lives
  /// inside the `emuQueue` critical section), and only exists so the
  /// main-thread publish happens on change rather than every frame.
  @ObservationIgnored nonisolated(unsafe) var publishedFrameRate: Double = 0.0

  /// Next slice of the current frame on the x1 path
  /// (`runFrameSliceForMetal`). Emulation-thread only, like
  /// `publishedFrameRate`. 0 means the next tick starts a frame.
  @ObservationIgnored nonisolated(unsafe) var frameSliceIndex: Int = 0

  @ObservationIgnored nonisolated(unsafe) var rewindActive: Bool = false

  /// True while the user is holding the rewind key. Drives reverse
  /// playback in the emulation loop and gates audio/recording UI.
  var isRewinding: Bool = false

  /// Ring buffer of save-state snapshots (oldest at index 0). All access
  /// is on the main thread (Metal draw loop + UI events), so no lock is
  /// required.
  @ObservationIgnored nonisolated(unsafe) var rewindSnapshots: [RewindSnapshot] = []

  /// Frame counter feeding `rewindSnapshotInterval` cadence.
  @ObservationIgnored nonisolated(unsafe) var rewindFrameCounter: Int = 0

  /// Counts down draw-frames between snapshot pops during reverse
  /// playback. Driven by `EmulatorViewModel.rewindStepDivider`; a
  /// value of 4 means we pop one snapshot every 4 draws (≈ 1/4 the
  /// raw rate, so 30s of buffered history rewinds in ~4 wall seconds).
  @ObservationIgnored nonisolated(unsafe) var rewindStepCounter: Int = 0

  /// Snapshot count captured when the user pressed the rewind key.
  /// Used to compute "how far back the user has rewound" for the
  /// strip overlay's elapsed-seconds readout.
  @ObservationIgnored var rewindStartSnapshotCount: Int = 0

  /// Thumbnails frozen at hold start so the strip overlay can
  /// render a stable left-to-right timeline against which the
  /// "you are here" marker visibly slides leftward.
  var rewindFrozenThumbnails: [CGImage] = []

  /// Master volume captured at the moment rewind starts so it can be
  /// restored on release.
  @ObservationIgnored var preRewindVolume: Float = 0

  /// Save state sheet
  var showingSaveStateSheet: Bool = false
  var saveStateSheetMode: SaveStateSheetMode = .save
  enum SaveStateSheetMode { case save, load }

  /// Debug audio source toggles
  var fmEnabled: Bool = true {
    didSet { applyDebugAudioMask() }
  }

  var ssgEnabled: Bool = true {
    didSet { applyDebugAudioMask() }
  }

  var adpcmEnabled: Bool = true {
    didSet { applyDebugAudioMask() }
  }

  /// Force YM2203 (OPN) mode — programs see register 0xFF as 0x00
  ///
  /// Set from the Develop menu on the main thread; goes through `emuQueue` for
  /// the same reason the other sound flags do (§3.3(c), §9.6). This one was
  /// named in the plan as taking no queue at all.
  var forceOPNMode: Bool = false {
    didSet {
      let value = forceOPNMode
      emuQueue.async { [weak self] in
        self?.pc88.forceOPNMode = value
      }
    }
  }

  var rhythmEnabled: Bool = true {
    didSet { applyDebugAudioMask() }
  }

  // MARK: - Debugger

  /// Owned debugger instance — always present so breakpoints persist
  /// across Debug Window open/close cycles. Only attached to Machine
  /// while the window is visible, keeping the hot path fast otherwise.
  let debugger = Debugger()
  /// The debug window is open.
  @ObservationIgnored private var debugWindowNeedsDebugger = false
  /// An AI agent has breakpoints set (`EmulatorViewModel+Automation.swift`).
  @ObservationIgnored var automationNeedsDebugger = false
  /// Serves the AI tools while Settings allows it.
  @ObservationIgnored var automationServer: AutomationHTTPServer?

  /// Attach the debugger to the machine. Call when opening the debug window.
  func attachDebugger() {
    debugWindowNeedsDebugger = true
    updateDebuggerAttachment()
  }

  /// Detach the debugger from the machine. Call when closing the debug
  /// window so the hot path returns to full speed. It stays attached while
  /// an AI agent has breakpoints set.
  func detachDebugger() {
    debugWindowNeedsDebugger = false
    updateDebuggerAttachment()
  }

  /// Attach the debugger while either the debug window or an AI agent's
  /// breakpoints need it.
  func updateDebuggerAttachment() {
    let attach = debugWindowNeedsDebugger || automationNeedsDebugger
    emuQueue.async { [pc88, debugger] in
      pc88.debugger = attach ? debugger : nil
    }
  }

  /// Develop menu: load the built-in font, the bundled substitute kanji ROMs
  /// and the bundled rhythm samples even when the user's files exist. Not
  /// persisted; `loadROMs()` applies them, so they take effect at the next
  /// reset.
  var forceBuiltInFont = false
  var forceBuiltInKanji = false
  var forceBuiltInRhythm = false

  /// The core's built-in 8×8 font, captured in `init` before any FONT.ROM
  /// overwrites it, for `forceBuiltInFont`.
  @ObservationIgnored private(set) var builtInFont: [UInt8] = []

  /// Debug-only experiment: suppress text layer overlay while keeping
  /// graphics and attribute-graphics rendering intact.
  var debugTextLayerEnabled: Bool = true {
    didSet {
      syncLoopSettings()
      guard !isRunning else { return }
      renderScreen()
    }
  }

  // MARK: - Internal (shared across extension files)

  /// All Machine access is serialized on this queue — including the run loop.
  ///
  /// `emuQueue` is the mutual-exclusion token that every Machine toucher
  /// takes. The emulation step runs on `EmulationLoop`'s dedicated thread and
  /// takes it too, which is what keeps the `emuQueue.async` writers (debugger
  /// attach/detach, YM2608 debug masks, the Debug window's snapshot capture)
  /// off the running machine.
  ///
  /// Since the emulation thread split, `emuQueue.sync` from the main thread is
  /// a **real cross-thread wait** of up to one machine frame, where it used to
  /// run inline. Heavy operations therefore still `stop()` the loop first.
  ///
  /// **Do not call `emuQueue.sync` from anything reachable inside
  /// `runFrameForMetal`** — the queue is serial, so re-entering it deadlocks.
  /// Equally, nothing reachable from there may *block* on the main thread:
  /// main → emulation may wait, emulation → main must always be `async`.
  let emuQueue = DispatchQueue(label: "com.bubio.bubilator88.emu", qos: .userInteractive)

  /// The emulation thread. Created in `init`, started by `start()`.
  ///
  /// `nonisolated(unsafe)`: set once during initialization and never
  /// reassigned after, so cross-actor reads (from `runEmulationStep` on the
  /// emulation thread) are safe. `EmulationLoop` itself is `@unchecked
  /// Sendable` and synchronizes its own state internally.
  @ObservationIgnored nonisolated(unsafe) private(set) var emulationLoop: EmulationLoop!

  /// Completed frames handed to the Metal view. See `FramePublisher`.
  @ObservationIgnored let framePublisher =
    FramePublisher(pixelCount: PC88.frameBufferSize)

  /// The emulated machine. The debugger and development tools reach its
  /// internals through the `@_spi(Debug)` members (PC88+Debug.swift).
  let pc88: PC88

  /// The 640×400 RGBA frame the emulation loop renders into.
  ///
  /// **Isolation:** owned by the emulation thread, which writes it under
  /// `emuQueue` and hands finished copies to the renderer via
  /// `framePublisher`. The Metal view never reads this buffer — it reads the
  /// published `FrameSlot`. Other readers take a copy through `emuQueue.sync`;
  /// `captureThumbnail()` is the one place that reads it directly, which is
  /// safe only because state saves happen with the run loop stopped.
  @ObservationIgnored nonisolated(unsafe) var pixelBuffer: [UInt8]

  /// UI update throttle counter (emulation thread)
  @ObservationIgnored nonisolated(unsafe) var uiUpdateCounter: Int = 0

  /// Set on the main thread when the translation overlay wants a fresh screen
  /// sample; consumed by the emulation loop on its next 4Hz tick.
  ///
  /// `Atomic` because `TranslationManager` is main-actor state that the
  /// emulation thread must not touch, but the pixel copy it gates has to
  /// happen where the pixel buffer lives.
  @ObservationIgnored let ocrSampleRequested = Atomic<Bool>(false)

  /// Host input (keyboard matrix, bus mouse) posted from the main thread and
  /// applied by the emulation loop at a frame boundary. See `InputEvent`.
  @ObservationIgnored let inputQueue = InputEventQueue()

  /// Display and feedback settings the emulation loop consults every frame.
  ///
  /// They are main-actor UI state, so the loop reads a snapshot instead of the
  /// live properties. `syncLoopSettings()` refreshes it from the main thread
  /// whenever one of the inputs changes; a frame that races the update simply
  /// uses the previous value, exactly as it would have before the split.
  struct LoopSettings {
    var debugTextLayerEnabled = true
    var markTextPixels = false
    var hapticEnabled = false
  }

  @ObservationIgnored nonisolated(unsafe) var loopSettings = LoopSettings()

  /// Refresh `loopSettings` from the live UI state. Main thread only.
  ///
  /// The write goes through `emuQueue` even though a stale frame would be
  /// harmless: the loop reads these fields every frame, and an unsynchronized
  /// write is a data race whatever the semantics. It fires a few times a second
  /// at most.
  func syncLoopSettings() {
    let snapshot = LoopSettings(
      debugTextLayerEnabled: debugTextLayerEnabled,
      markTextPixels: markTextPixelsForDisplay,
      hapticEnabled: Settings.shared.controllerHapticEnabled
    )
    emuQueue.sync { loopSettings = snapshot }
  }

  /// Host-side mirrors of the queued bus-mouse settings, so the corresponding
  /// properties read back what was last set rather than what the machine has
  /// caught up to.
  @ObservationIgnored var mouseEnabledMirror: Bool = false
  @ObservationIgnored var mouseJoyModeMirror: Bool = false

  /// Paste queue that replays clipboard text as simulated keystrokes.
  @ObservationIgnored nonisolated(unsafe) let pasteQueue = TextPasteQueue()
  @ObservationIgnored nonisolated let pasteQueueLock = NSLock()

  /// Types `LOAD "CAS:"` and `RUN` for Tape > Auto Boot. It types through
  /// `pasteQueue` and is ticked next to it; both share `pasteQueueLock`.
  @ObservationIgnored nonisolated(unsafe) let tapeAutoBoot = TapeAutoBoot()

  /// Restores a `.n80` memory image once N-BASIC is up, and types `RUN` if it
  /// needs it. Types through `pasteQueue`, is ticked next to it, and shares
  /// `pasteQueueLock`, so whatever cancels typing (ESC, a reset, a state
  /// load) cancels it.
  @ObservationIgnored nonisolated(unsafe) let memoryImageBoot = MemoryImageBoot()

  /// Plays the key sequence of a clicked control zone; ticked next to the paste
  /// queue. Carries its own lock.
  @ObservationIgnored nonisolated let clickZonePlayer = ClickZonePlayer()

  /// The enabled cheat groups of the active set, run by `applyCheats()` each
  /// frame. Written on `emuQueue` by `syncActiveCheats()`.
  @ObservationIgnored nonisolated(unsafe) var activeCheatCodes: [[PATCode]] = []

  /// The user layout being edited, while the control-zone editor is open. Edits
  /// go to this copy and are written to `ClickZoneStore` as each completes.
  var clickZoneEditingLayout: ClickZoneLayout?
  /// The zone selected in the editor.
  var selectedClickZoneID: UUID?
  /// Whether the editor is recording keys into the selected zone. While it
  /// is, Delete is a key to record rather than "delete the zone".
  var isRecordingClickZoneKeys = false
  /// The zone a controller has focused (see `controlZonesUseController`).
  var focusedClickZoneID: UUID?
  /// Whether emulation was running when the editor paused it.
  @ObservationIgnored var clickZoneEditPausedEmulation = false

  /// Romaji → half-width katakana input mode (host-side IME). When on, typed
  /// letters are converted to kana and injected via `pasteQueue` instead of
  /// reaching the matrix directly. Intentionally NOT persisted — always starts
  /// OFF each launch (a session-only toggle).
  var romajiInputEnabled: Bool = false {
    didSet {
      if !romajiInputEnabled { flushRomajiPending() }
    }
  }
  /// Uncommitted romaji shown by the IME-style overlay ("ky" while typing).
  var romajiPending: String = ""
  /// The incremental converter; mutated only on the main thread (key monitor).
  @ObservationIgnored var romajiConverter = RomajiKanaConverter()

  /// Active timeline-script player (live mode). Driven once per machine
  /// frame from `runFrameForMetal()`, same thread as `tickPasteQueue`.
  @ObservationIgnored nonisolated(unsafe) var scriptPlayer: ScriptPlayer?

  /// A `.b88script` opened (double-click) before the emulator was ready
  /// to play it. Consumed by `consumePendingScript()` from
  /// `ContentView.onAppear`, right after the run loop is started.
  @ObservationIgnored var pendingScriptURL: URL?

  /// A launch request (`bubilator88://boot` URL from FlipDisk, or the
  /// process's own command line) parsed before the emulator was ready to act
  /// on it. Consumed by `consumePendingLaunch()` from `ContentView.onAppear`,
  /// right after the run loop is started. Kept separate from
  /// `pendingScriptURL` (different transport, different consumer) — see
  /// docs/develop/URL_SCHEME.md. Stores the *parsed* request, not the URL, so the
  /// command-line entry point shares the same deferral and apply path.
  @ObservationIgnored var pendingLaunchRequest: LaunchRequest?

  /// A CD opened from Finder before the ROMs were loaded. Consumed by
  /// `consumePendingCD()` from `ContentView.onAppear`.
  @ObservationIgnored var pendingCDURL: URL?

  /// Command-line arguments are honored exactly once, at startup
  /// (`ContentView.onAppear`), so a window re-creation never re-boots the
  /// game the user launched with.
  @ObservationIgnored var didConsumeCommandLine = false

  /// Directory of the script being replayed. Kept so that relative disk paths in
  /// the script can be resolved when each drive's `MountedDiskInfo` is rebuilt
  /// after playback.
  @ObservationIgnored nonisolated(unsafe) var scriptDir: URL?

  /// What each drive's `MountedDiskInfo` was last rebuilt from during live
  /// script playback: the mounted path and image index, or nil for an empty
  /// drive. `tickScriptPlayer()` compares the player's mounts against this every
  /// frame so a mid-script `disk swap` / `disk select` / `disk eject` shows up in
  /// the status bar and the Disk menu right away, not only when playback ends.
  @ObservationIgnored nonisolated(unsafe) var scriptMountSnapshot: [ScriptMountKey?] = [nil, nil]

  /// Identity of one drive's script mount, for change detection only.
  struct ScriptMountKey: Equatable {
    let path: String
    let imageIndex: Int
  }

  /// Active operation recorder. Fed real key/disk events; its `frameIndex`
  /// is advanced once per machine frame from `runFrameForMetal()`.
  @ObservationIgnored nonisolated(unsafe) var scriptRecorder: ScriptRecorder?

  /// Audio output for YM2608 SSG sound
  let audio = AudioOutput()

  /// Multichannel audio recorder (FM/SSG/ADPCM/Rhythm/Mix).
  let audioRecorder = AudioRecorder()

  /// Screen + audio video recorder (mutually exclusive with audioRecorder).
  let videoRecorder = VideoRecorder()

  /// FDD access sound effects
  let fddSound = FDDSound()

  /// Scheduler for write-through D88 write-back. Debounces the dirty
  /// notifications to keep file I/O infrequent.
  let diskWriteBackScheduler = DiskWriteBackScheduler()

  /// Synthesised cassette-rewind sound played while ⌘Z is held.
  let rewindSound = RewindSound()
  let gameController = GameControllerManager()

  /// Translation overlay manager
  let translationManager = TranslationManager()

  /// Toggle translation overlay on/off.
  func toggleTranslation(_ enabled: Bool) {
    if enabled {
      if translationManager.isSessionActive {
        // Re-activation: just show cached results instantly
        translationManager.show()
      } else {
        // First activation: establish session and kick off OCR
        translationManager.isSessionActive = true
        translationManager.prepareTranslation()
        translationManager.show()
        triggerImmediateOCR()
      }
    } else {
      translationManager.hide()
    }
  }

  /// Trigger OCR immediately with current pixel buffer.
  func triggerImmediateOCR() {
    let buffer = emuQueue.sync { Array(pixelBuffer) }
    Task {
      await translationManager.processOCR(pixelBuffer: buffer, width: 640, height: 400)
    }
  }

  #if DEBUG
  /// Debug-only text DMA snapshot auto-dump request, written once after launch.
  @ObservationIgnored nonisolated let textDMASnapshotAutoDumpRequested: Bool = {
    ProcessInfo.processInfo.environment["BUBILATOR88_TEXT_DMA_SNAPSHOT"] != nil
  }()

  @ObservationIgnored nonisolated let textDMASnapshotDumpPath: String = {
    ProcessInfo.processInfo.environment["BUBILATOR88_TEXT_DMA_SNAPSHOT_PATH"]
      ?? "/tmp/bubilator88-text-dma-snapshot.txt"
  }()

  @ObservationIgnored nonisolated let textDMASnapshotTriggerPath: String = {
    ProcessInfo.processInfo.environment["BUBILATOR88_TEXT_DMA_TRIGGER_PATH"]
      ?? "/tmp/bubilator88-text-dma-trigger"
  }()

  @ObservationIgnored nonisolated(unsafe) var textDMASnapshotAutoDumped = false

  #endif

  // MARK: - Init

  init() {
    let machine = PC88()
    self.pc88 = machine
    self.builtInFont = (0...255).flatMap { machine.glyph(for: UInt8($0)) }
    self.pixelBuffer = Array(repeating: 0, count: PC88.frameBufferSize)
    activeClock8MHz = clock8MHz
    pc88.dipSw1 = _bootModeStorage.dipSw1
    // Drive 0 is always empty at init → ROM boot (bit 3 = 1)
    pc88.dipSw2 = _bootModeStorage.dipSw2 | 0x08
    // Set before the reset: the monitor decides the CRTC's reset geometry.
    pc88.monitorType = Settings.shared.monitorType
    pc88.memoryWaitDip = Settings.shared.memoryWaitDip
    // No CD is in yet, so no drive (see `performReset`).
    refreshCDBios()
    pc88.reset()
    pc88.clock8MHz = clock8MHz
    pc88.immersiveOutputEnabled = Settings.shared.immersiveAudio
    pc88.pseudoStereoEnabled = pseudoStereo && !immersiveAudio
    pc88.cdMixEnabled = Settings.shared.cdMix
    audio.pc88 = pc88
    audio.recorder = audioRecorder
    audio.videoRecorder = videoRecorder

    // FDD sounds, played as the drive mechanism events happen.
    pc88.onFDDEvent = { [weak self] drive, event in
      switch event {
      case .seekStep: self?.fddSound.playSeekStep(drive: drive)
      case .access:   self?.fddSound.playReadAccess(drive: drive)
      }
    }

    // The emulation thread. The step takes `emuQueue` exactly as the draw
    // callback used to, and re-checks `shouldRun` under it so `stop()` can
    // guarantee no frame is in flight once it returns.
    emulationLoop = EmulationLoop { [weak self] batch in
      self?.runEmulationStep(frameCount: batch)
    }

    // Wire up the write-back scheduler's writeBack closure.
    diskWriteBackScheduler.writeBack = { [weak self] drive in
      self?.performDiskWriteBack(drive: drive)
    }

    // Take write notifications from SubSystem and schedule them with debouncing.
    pc88.onDiskWritten = { [weak self] drive in
      self?.diskDirtyNotification(drive: drive)
    }

    // The saved filter can name a model that is not on this Mac — removed
    // outside the app, or saved by a version that still bundled it.
    if let model = videoFilter.downloadableModel, !AIModelStore.shared.isInstalled(model) {
      Settings.shared.videoFilter = VideoFilter.none.rawValue
    }

    applyAutomationSetting()
  }

  // MARK: - Execution Control

  /// Metal view reference for start/stop control
  weak var metalView: EmulatorMetalView?

  /// Whether the emulator window is on screen, as the Metal view last saw it.
  @ObservationIgnored private var windowVisible = true

  /// Held while a hidden window keeps running, so App Nap does not throttle
  /// the emulation thread.
  @ObservationIgnored private var backgroundActivity: (any NSObjectProtocol)?

  /// Called by `EmulatorMetalView` whenever the window's occlusion changes.
  func windowVisibilityChanged(_ visible: Bool) {
    windowVisible = visible
    applyBackgroundPolicy()
  }

  /// Decide what a hidden window means. By default the emulator parks until
  /// the window is seen again. With "Keep running in the background" it goes
  /// on, muted unless "Play sound in the background" is also on.
  func applyBackgroundPolicy() {
    let settings = Settings.shared
    let runsHidden = !windowVisible && settings.runInBackground
    emulationLoop.setVisible(windowVisible || settings.runInBackground)

    let mute = runsHidden && !settings.backgroundAudio
    audio.setMuted(mute)
    fddSound.muted = mute

    if runsHidden, backgroundActivity == nil {
      backgroundActivity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Emulating in the background")
    } else if !runsHidden, let activity = backgroundActivity {
      ProcessInfo.processInfo.endActivity(activity)
      backgroundActivity = nil
    }
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    showToast("Running")

    audio.start(spatial: Settings.shared.immersiveAudio)
    applyVolume()
    audio.setRate(emulationSpeed.audioRate)
    if Settings.shared.fddSound {
      fddSound.volume = FDDSound.volume(for: Settings.shared.fddSoundVolumeLevel)
      fddSound.start(outputDeviceUID: Settings.shared.fddSoundDeviceUID)
    }
    if Settings.shared.gameControllerEnabled {
      gameController.start(viewModel: self)
    }

    // The emulation thread paces itself; the Metal view only presents
    // finished frames. `startEmulation()` un-pauses the draw loop and, via
    // `updateDrawLoop()`, feeds the current window visibility to the loop —
    // emulation stays parked while the window is occluded, as it did when the
    // draw loop drove it, unless the user keeps it running in the background.
    syncLoopSettings()
    emulationLoop.setFramesPerStep(emulationSpeed.framesPerDraw)
    emulationLoop.start()
    metalView?.startEmulation()
  }

  /// Restart audio engine to apply new settings (buffer size, spatial mode).
  func restartAudio() {
    guard isRunning else { return }
    audio.stop()
    audio.start(spatial: Settings.shared.immersiveAudio)
    applyVolume()
    audio.setRate(emulationSpeed.audioRate)
  }

  /// Internal tear-down of the run loop. Stops Metal, audio, FDD
  /// sound, and game controller, but preserves all emulator state
  /// (CPU registers, memory, CRTC, YM2608) so the next `start()`
  /// resumes from exactly where we left off. Callers that need
  /// user-visible "pause" semantics should go through `pause()`
  /// instead, which also handles translation OCR and the toast.
  func stop() {
    isRunning = false
    // Park the emulation thread and wait for the in-flight frame. Callers
    // depend on quiescence: `captureThumbnail()` reads `pixelBuffer`
    // directly, save/load and reset replace machine state wholesale.
    emulationLoop.stop { [emuQueue] in emuQueue.sync {} }
    metalView?.stopEmulation()
    audio.stop()
    fddSound.stop()
    gameController.stop()

    fps = 0.0
  }

  /// User-facing pause. Same preserved-state semantics as `stop()`
  /// but with the UX polish: guards against double-pause, surfaces
  /// a "Paused" toast, and when the translation overlay is active
  /// runs one fresh OCR pass on the now-frozen frame so the
  /// overlay reflects the exact moment the user froze — important
  /// during auto-scrolling dialogue where the stale OCR would
  /// otherwise show whatever line was captured up to 3 seconds
  /// earlier. Called from both the Emulator menu Pause button and
  /// the Debug Window's Pause button; they are the same operation.
  ///
  /// Internal callers that need to tear the run loop down as part
  /// of a larger operation (reset, save-state load/save) should
  /// still call `stop()` directly to skip the toast and OCR.
  func pause() {
    guard isRunning else { return }
    stop()
    showToast("Paused")
    if translationManager.isSessionActive {
      triggerImmediateOCR()
    }
  }

  /// User-facing resume from a paused state. Guards against
  /// double-resume and surfaces a "Running" toast. Called from
  /// both the Emulator menu Resume button and the Debug Window's
  /// Run button.
  func resume() {
    guard !isRunning else { return }
    start()
  }

  /// Render one frame synchronously into the pixel buffer and
  /// force the Metal view to upload + draw it once, even while
  /// `isRunning == false`. Used by the debugger's Step button so
  /// the visual effect of executing a single instruction (e.g., a
  /// write to VRAM) becomes visible without resuming the render
  /// loop. No effect when Metal is still running — the normal
  /// draw cycle will pick up the change.
  func renderSingleFrame() {
    renderCurrentFrame(into: &pixelBuffer, blinkCursor: false, debugTextLayerEnabled: debugTextLayerEnabled)
    publishFrame(counted: false)
    metalView?.draw()
  }

  // MARK: - Reset / Quit Dissolve Animation

  /// Self-contained record of an active dissolve animation. Bundling
  /// these fields into one optional value (replacing the half-dozen
  /// parallel `var`s the earlier draft used) lets the SwiftUI overlay
  /// guard on a single optional and makes "no dissolve in flight"
  /// representable as `nil` instead of by-convention.
  struct DissolveSession {
    enum Mode { case forward, reverse }
    enum Trigger { case reset, quit }

    var snapshot: NSImage
    var start: Date
    var mode: Mode
    var duration: TimeInterval
    var trigger: Trigger
    /// Whether emulation was running at the moment the *original*
    /// dissolve started (before any subsequent `stop()` calls).
    /// Survives a takeover (reset → quit) so cancel can resume the
    /// machine to the user's pre-reset state.
    var preWasRunning: Bool

    func progress(at now: Date) -> Double {
      let raw = max(0.0, min(1.0, now.timeIntervalSince(start) / duration))
      return mode == .forward ? raw : (1.0 - raw)
    }
  }

  /// Currently-active dissolve, or nil if no animation is running.
  /// Read by the SwiftUI overlay each frame via TimelineView; a
  /// `.layerEffect` shader uniform isn't animated by `withAnimation`
  /// so we instead derive progress from wall-clock + this session.
  var dissolveSession: DissolveSession?

  /// Pending `DispatchWorkItem`s scheduled by the active dissolve
  /// (deferred reset, cleanup). We keep handles so a new dissolve
  /// taking over can cancel them explicitly — clearer than the
  /// generation-counter approach the earlier draft used.
  private var pendingDissolveTasks: [DispatchWorkItem] = []

  static let resetDissolveDuration: TimeInterval = 1.6
  static let quitDissolveDuration: TimeInterval = 3.2

  private func cancelPendingDissolveTasks() {
    for item in pendingDissolveTasks { item.cancel() }
    pendingDissolveTasks.removeAll()
  }

  private func scheduleDissolveTask(after delay: TimeInterval,
                                    _ block: @escaping () -> Void) {
    let item = DispatchWorkItem(block: block)
    pendingDissolveTasks.append(item)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  /// Start a forward dissolve and freeze emulation. Used when the
  /// user hits Cmd+Q or Cmd+W — the AppDelegate calls this just
  /// before presenting the confirmation sheet so the screen visibly
  /// disintegrates while the dialog is up.
  ///
  /// Stops emulation unconditionally, even if snapshot capture fails
  /// or a prior dissolve is taking over — the user pressed Cmd+Q,
  /// the machine must freeze regardless of overlay state.
  func beginQuitDissolve() {
    let wasRunning = isRunning
    stop()
    cancelPendingDissolveTasks()

    let now = Date()
    if var session = dissolveSession {
      // Take over an existing animation: keep the on-screen image
      // and current progress, but re-anchor the start so the new
      // (slower) quit duration produces the same `pNow` at `now`.
      // `preWasRunning` carries over so cancel resumes the user's
      // original pre-reset state.
      let pNow = session.progress(at: now)
      session.mode = .forward
      session.duration = Self.quitDissolveDuration
      session.trigger = .quit
      session.start = now.addingTimeInterval(-Self.quitDissolveDuration * pNow)
      dissolveSession = session
      return
    }
    guard let snapshot = makeDissolveSnapshot() else { return }
    dissolveSession = DissolveSession(
      snapshot: snapshot,
      start: now,
      mode: .forward,
      duration: Self.quitDissolveDuration,
      trigger: .quit,
      preWasRunning: wasRunning
    )
  }

  /// User dismissed the quit/close sheet — reverse the dissolve and,
  /// once particles have reassembled, resume emulation if it was
  /// running.
  func cancelQuitDissolve() {
    // Only valid for a forward quit dissolve. Ignore stray calls
    // (e.g. a reset dissolve in flight, or a cancel arriving after
    // cleanup already ran).
    guard var session = dissolveSession,
          session.trigger == .quit,
          session.mode == .forward else { return }

    let now = Date()
    let pCancel = session.progress(at: now)
    // Reverse plays at the standard (faster) reset cadence even though
    // the forward quit pass is intentionally slow — the user already
    // changed their mind, no reason to make them wait twice as long.
    let reverseDuration = Self.resetDissolveDuration
    // For reverse mode, progress(t) = 1 - clamp((t - start) / duration, 0, 1).
    // Pick `start` so progress(now) == pCancel and progress reaches 0
    // after `duration * pCancel` more seconds.
    let elapsedNeeded = reverseDuration * (1.0 - pCancel)
    session.mode = .reverse
    session.duration = reverseDuration
    session.start = now.addingTimeInterval(-elapsedNeeded)
    dissolveSession = session

    cancelPendingDissolveTasks()
    let remaining = reverseDuration * pCancel
    let restart = session.preWasRunning
    scheduleDissolveTask(after: remaining + 0.05) { [weak self] in
      guard let self else { return }
      self.dissolveSession = nil
      if restart { self.start() }
    }
  }

  func reset() {
    // Resetting while paused would otherwise freeze the display on the
    // instant-post-reset VRAM/CRTC state — raw, uninitialized-looking
    // garbage that the boot ROM only clears once the CPU actually runs.
    // While running, that instant flashes by within a frame or two before
    // anyone sees it; while paused, nothing ever runs to clear it. Forcing
    // the post-reset restart (without physically starting/stopping audio
    // twice in the process — see forceRun below) means reset always leaves
    // the machine in the same state a normal running reset does.
    let forceRun = !isRunning
    if Settings.shared.resetAnimationEnabled,
       dissolveSession == nil,
       let snapshot = makeDissolveSnapshot() {
      playResetDissolve(snapshot: snapshot, forceRun: forceRun)
    } else {
      performReset(resetTranslation: true, forceRestart: forceRun)
    }
  }

  private func makeDissolveSnapshot() -> NSImage? {
    let buf = emuQueue.sync { Array(pixelBuffer) }
    guard let cg = createCGImage(from: buf) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: 640, height: 400))
  }

  private func playResetDissolve(snapshot: NSImage, forceRun: Bool) {
    let wasRunning = isRunning || forceRun
    stop()
    cancelPendingDissolveTasks()
    dissolveSession = DissolveSession(
      snapshot: snapshot,
      start: Date(),
      mode: .forward,
      duration: Self.resetDissolveDuration,
      trigger: .reset,
      preWasRunning: wasRunning
    )
    // Run the actual reset partway through the animation so the
    // Metal view underneath has already transitioned to the post-reset
    // frame by the time the dissolve completes (otherwise the user
    // briefly sees the pre-reset image after the overlay clears).
    scheduleDissolveTask(after: Self.resetDissolveDuration * 0.4) { [weak self] in
      self?.performReset(resetTranslation: true, forceRestart: wasRunning)
    }
    scheduleDissolveTask(after: Self.resetDissolveDuration + 0.05) { [weak self] in
      self?.dissolveSession = nil
    }
  }

  private func applyBootMode() {
    performReset(resetTranslation: false)
  }

  /// Shared reset core. Uses the current `bootMode` (the status-bar
  /// backing storage) as the single source of truth for DIP switch
  /// values, so the UI label and the actual ROM-visible mode can never
  /// drift — even if Settings.dipSw1/dipSw2Base were left stale by a
  /// previous save-state load or another unusual path.
  func performReset(resetTranslation: Bool, forceRestart: Bool = false) {
    let wasRunning = isRunning || forceRestart
    cancelScriptPlayback()
    cancelScriptRecording()
    stop()
    cancelPasteQueue()
    cancelClickZonePlayer()
    let mode = _bootModeStorage
    let sw1 = mode.dipSw1
    let sw2Base = mode.dipSw2
    // Keep Settings in sync so a user toggling back to the same mode
    // through the UI still sees a consistent stored state.
    if mode != .custom {
      if Settings.shared.dipSw1 != sw1 { Settings.shared.dipSw1 = sw1 }
      if Settings.shared.dipSw2Base != sw2Base { Settings.shared.dipSw2Base = sw2Base }
    }
    let use8MHz = clock8MHz
    let monitorType = Settings.shared.monitorType
    let memoryWaitDip = Settings.shared.memoryWaitDip
    refreshCDBios()
    emuQueue.sync {
      // Auto-select ROM/DISK boot: if drive 0 is empty, set DIP SW2
      // bit 3 to skip the ~30s disk-boot timeout and go straight to
      // BASIC. When a disk is mounted, clear bit 3 for normal IPL boot.
      // (Machine.applyBootStrap is the single source of truth shared with
      // ScriptPlayer / BootTester.)
      pc88.dipSw1 = sw1
      // The CD-ROM drive is there when a CD is in, like a drive the user
      // has connected to use it. It takes effect at the reset below, and the
      // boot strap depends on it.
      pc88.cdDriveInstalled = pc88.isCDMounted
      pc88.applyBootStrap(base: sw2Base)
      // Like the DIP switches, the monitor type only takes effect on reset.
      pc88.monitorType = monitorType
      pc88.memoryWaitDip = memoryWaitDip
      pc88.reset(preserveRAM: true)
      pc88.clock8MHz = use8MHz
      pc88.cpuOverclock = cpuOverclock
    }
    activeClock8MHz = use8MHz
    if romLoaded { loadROMs() }
    if resetTranslation { translationManager.hardReset() }
    // `pc88.reset` cleared the matrix itself.
    heldKeys.removeAll()
    clearRewindBuffer()
    renderScreen()
    if wasRunning { start() }
  }

  // MARK: - Save State

  private static let saveStateDir: URL = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appending(component: "Bubilator88/SaveStates", directoryHint: .isDirectory)
  }()

  private func saveStatePath(slot: Int) -> URL {
    Self.saveStateDir.appending(component: "slot_\(slot).b88s")
  }

  /// Public accessor for sheet view.
  func saveStatePath(forSlot slot: Int) -> URL {
    saveStatePath(slot: slot)
  }

  private var quickSavePath: URL {
    Self.saveStateDir.appending(component: "quicksave.b88s")
  }

  /// App-level metadata saved alongside the machine state.
  struct SaveMeta: Codable {
    var bootMode: String
    var clock8MHz: Bool
    /// Monitor type (DIP SW1 bit 8) the state was captured under.
    ///
    /// It has to travel with the state even though DIP switches do not, and
    /// the difference is that this one has a *consequence* baked into the
    /// serialized machine: the CRTC geometry software programmed after
    /// reading port 0x40 bit 1. Restoring 25×16 = 448 lines into a machine
    /// running at 15,980 Hz yields 35.7Hz — a combination no real machine can
    /// be in, because on a 15kHz monitor the ROM programs 25×8 = 256 instead.
    ///
    /// Optional so states written before 1.5.0 still decode; see
    /// `performLoad` for why they default to 24kHz.
    var monitorType: Int?
    /// Memory wait DIP (SW1-6) the state was captured under. It only changes
    /// the speed, like the clock, and travels for the same reason. Optional
    /// so older states decode; they keep the current setting.
    var memoryWaitDip: Bool?
    var disk0: String?
    var disk1: String?
    var drive0Name: String?
    var drive1Name: String?
    var drive0FileName: String?
    var drive1FileName: String?
    var drive0SourceURL: String?
    var drive1SourceURL: String?
    var drive0ImageIndex: Int?
    var drive1ImageIndex: Int?
    var drive0ArchiveEntry: String?
    var drive1ArchiveEntry: String?
    /// Cassette metadata (nil fields when no tape was mounted). The tape
    /// bytes themselves round-trip via the CMT section in the state file
    /// proper; these are only for restoring the UI's mount display.
    var tapeName: String?
    var tapeSourceURL: String?
    var tapeFormatT88: Bool?
    /// The CD in the drive. Unlike a tape, the disc is not inside the state
    /// file — only the drive's position is — so it is mounted again from here.
    var cdName: String?
    var cdSourceURL: String?
  }

  /// Sidecar paths, read-only: saves stopped writing these once `AMTA` / `THMB`
  /// went inside the `.b88s`. Slots written by older builds still have them.
  private func metaPath(for statePath: URL) -> URL {
    statePath.deletingPathExtension().appendingPathExtension("meta.json")
  }

  private func thumbnailPath(for statePath: URL) -> URL {
    statePath.deletingPathExtension().appendingPathExtension("thumb.png")
  }

  /// App metadata for a state file: from the `AMTA` section when present,
  /// otherwise from the sidecar JSON written by builds before the section
  /// existed. States saved by those builds must keep loading correctly.
  private func loadMeta(for statePath: URL) -> SaveMeta? {
    let data = SaveStateFileAccess.readSection(SaveStateFileAccess.appMetaTag, from: statePath)
      ?? (try? Data(contentsOf: metaPath(for: statePath)))
    guard let data else { return nil }
    return try? JSONDecoder().decode(SaveMeta.self, from: data)
  }

  /// Thumbnail PNG for a state file, with the same in-file-then-sidecar order.
  private func loadThumbnailData(for statePath: URL) -> Data? {
    SaveStateFileAccess.readSection(SaveStateFileAccess.thumbnailTag, from: statePath)
      ?? (try? Data(contentsOf: thumbnailPath(for: statePath)))
  }

  /// Grab a thumbnail straight out of `pixelBuffer`.
  ///
  /// Safe without synchronization only because every caller has already
  /// `stop()`ped the run loop, and `stop()` waits for the in-flight frame
  /// before returning — so the emulation thread is parked and the buffer is
  /// nobody else's.
  private func captureThumbnail() -> Data? {
    let srcWidth = 640
    let srcHeight = 400
    // Create full-size CGImage from pixelBuffer (RGBA)
    let dataProvider = CGDataProvider(data: Data(pixelBuffer) as CFData)!
    guard let fullImage = CGImage(
      width: srcWidth, height: srcHeight,
      bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: srcWidth * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: dataProvider,
      decode: nil, shouldInterpolate: true,
      intent: .defaultIntent
    ) else { return nil }
    // Draw scaled down to 320x200
    let thumbWidth = 320
    let thumbHeight = 200
    guard let ctx = CGContext(
      data: nil, width: thumbWidth, height: thumbHeight,
      bitsPerComponent: 8, bytesPerRow: thumbWidth * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(fullImage, in: CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
    guard let thumbImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: thumbImage)
    return rep.representation(using: .png, properties: [:])
  }

  private func performSave(to path: URL) {
    let wasRunning = isRunning
    if wasRunning { stop() }
    try? writeSaveState(to: path)
    saveStateRevision += 1
    if wasRunning { start() }
    showToast(String(localized: "State saved", comment: ""))
  }

  /// Serializes the machine and its app metadata into `path`. The caller must
  /// have `stop()`ped the run loop: the thumbnail is read straight out of
  /// `pixelBuffer`.
  func writeSaveState(to path: URL) throws {
    // Capture thumbnail on main thread (pixelBuffer access)
    let thumbData = captureThumbnail()
    // Only the serialization needs the machine; the file write must stay
    // outside the critical section. Once the emulation loop owns its own
    // thread, anything held inside `emuQueue` stalls emulation — and disk
    // I/O is exactly the kind of unbounded stall to keep out of it.
    let stateData: [UInt8] = emuQueue.sync {
      let meta = SaveMeta(
        bootMode: bootMode.rawValue,
        clock8MHz: clock8MHz,
        monitorType: pc88.monitorType.rawValue,
        memoryWaitDip: pc88.memoryWaitDip,
        disk0: pc88.mountedDisk(drive: 0)?.name,
        disk1: pc88.mountedDisk(drive: 1)?.name,
        drive0Name: self.drive0Name == "Empty" ? nil : self.drive0Name,
        drive1Name: self.drive1Name == "Empty" ? nil : self.drive1Name,
        drive0FileName: self.drive0FileName,
        drive1FileName: self.drive1FileName,
        drive0SourceURL: self.drive0Info?.sourceURL?.absoluteString,
        drive1SourceURL: self.drive1Info?.sourceURL?.absoluteString,
        drive0ImageIndex: self.drive0Info?.currentImageIndex,
        drive1ImageIndex: self.drive1Info?.currentImageIndex,
        drive0ArchiveEntry: self.drive0Info?.archiveEntryName,
        drive1ArchiveEntry: self.drive1Info?.archiveEntryName,
        tapeName: pc88.isTapeLoaded ? self.tapeName : nil,
        tapeSourceURL: pc88.isTapeLoaded ? self.tapeSourceURL?.absoluteString : nil,
        tapeFormatT88: pc88.isTapeLoaded ? (self.tapeFormat == .t88) : nil,
        cdName: pc88.isCDMounted ? self.cdName : nil,
        cdSourceURL: pc88.isCDMounted ? self.cdSourceURL?.path(percentEncoded: false) : nil
      )
      let metaJSON = try? JSONEncoder().encode(meta)
      // Thumbnail and app metadata go inside the .b88s so the file stands on
      // its own when copied or shared. The `.meta.json` / `.thumb.png` sidecars
      // are no longer written — the Quick Look extensions cover what they were
      // for in Finder — but they are still read as a fallback, and existing
      // ones are never deleted (see loadMeta / loadThumbnailData).
      var extraSections: [(tag: UInt32, data: [UInt8])] = []
      if let metaJSON {
        extraSections.append((tag: SaveStateFileAccess.appMetaTag, data: Array(metaJSON)))
      }
      return pc88.createSaveState(thumbnail: thumbData.map { Array($0) },
                                  extraSections: extraSections)
    }
    try? FileManager.default.createDirectory(at: Self.saveStateDir, withIntermediateDirectories: true)
    try Data(stateData).write(to: path, options: .atomic)
  }

  private func performLoad(from path: URL) {
    guard let fileData = try? Data(contentsOf: path) else {
      showToast(String(localized: "Save state not found", comment: ""))
      return
    }
    do {
      try applySaveState(fileData, from: path)
      showToast(String(localized: "State loaded", comment: ""))
    } catch {
      showToast(saveStateLoadErrorMessage(error))
    }
  }

  /// Replaces the machine with the state in `fileData` and brings the UI and
  /// Settings in line with it. Restarts the run loop if it was running, also
  /// when the load throws. On a throw the machine may be partly restored.
  func applySaveState(_ fileData: Data, from path: URL) throws {
    // Loading replaces the whole machine state, so a live script player /
    // recorder would be operating on a different machine than it began on
    // (corrupt recording, player injecting into the wrong state). Tear them
    // down first — symmetric with performReset.
    cancelScriptPlayback()
    cancelScriptRecording()
    // Typing still queued, and a memory image waiting to be restored, would
    // land on the loaded machine.
    cancelPasteQueue()
    // Loading a save state discards the current disk state, so flush any
    // unsaved disk writes first.
    diskWriteBackScheduler.flushAll()
    let wasRunning = isRunning
    if wasRunning { stop() }
    var loadError: Error?
    emuQueue.sync {
      do {
        try pc88.loadSaveState(Array(fileData))
      } catch {
        loadError = error
      }
    }
    if let loadError {
      if wasRunning { start() }
      throw loadError
    }
    // The state carries its own key matrix, which says nothing about what the
    // user is physically holding. Same reasoning as a rewind.
    releaseAllKeys()
    let meta: SaveMeta? = loadMeta(for: path)
    // Outside the `if let meta` below on purpose. The restored CRTC geometry
    // was chosen by software for one particular monitor; leaving the machine
    // on whatever the picker currently says produces a frame rate no real
    // machine can have (448 lines at 15,980 Hz = 35.7Hz). A state with no app
    // metadata predates 1.5.0, when port 0x40 bit 1 always read 0 — so its
    // geometry was programmed for a 24kHz monitor.
    let restoredMonitor = meta?.monitorType.flatMap(MonitorType.init(rawValue:)) ?? .khz24
    emuQueue.sync { pc88.monitorType = restoredMonitor }
    // Mirror it into Settings the way `clock8MHz` is mirrored, so the picker
    // agrees with the machine and the next Reset does not silently change the
    // frame rate back.
    Settings.shared.monitorType = restoredMonitor
    // The state brings its own extended RAM, or none; match the setting so the
    // next Reset does not install a different size.
    Settings.shared.extramCards = pc88.extRAMCards
    if let meta {
      if let memoryWait = meta.memoryWaitDip {
        emuQueue.sync { pc88.memoryWaitDip = memoryWait }
        Settings.shared.memoryWaitDip = memoryWait
      }
      if let mode = BootMode(rawValue: meta.bootMode) {
        _bootModeStorage = mode
        // Keep Settings.dipSw{1,2}Base in sync with the restored boot
        // mode. The save state doesn't serialize DIP switches, so on
        // the next Reset the ViewModel would otherwise re-apply the
        // previously-selected user mode's DIP values to the bus —
        // making the status bar disagree with the actual mode the
        // ROM boots into (e.g. UI says V2 but the game behaves as V1).
        if mode != .custom {
          Settings.shared.dipSw1 = mode.dipSw1
          Settings.shared.dipSw2Base = mode.dipSw2
          let sw1 = mode.dipSw1
          let sw2 = mode.dipSw2
          emuQueue.sync {
            pc88.dipSw1 = sw1
            pc88.dipSw2 = sw2
          }
        }
      }
      Settings.shared.clock8MHz = meta.clock8MHz
      drive0Name = meta.drive0Name ?? pc88.mountedDisk(drive: 0)?.name ?? "Empty"
      drive1Name = meta.drive1Name ?? pc88.mountedDisk(drive: 1)?.name ?? "Empty"
      drive0FileName = meta.drive0FileName
      drive1FileName = meta.drive1FileName
    } else {
      drive0Name = pc88.mountedDisk(drive: 0)?.name ?? "Empty"
      drive1Name = pc88.mountedDisk(drive: 1)?.name ?? "Empty"
      drive0FileName = nil
      drive1FileName = nil
    }
    // Reconstruct MountedDiskInfo from saved source URL or restored disk
    drive0Info = reconstructDiskInfo(drive: 0, meta: meta)
    drive1Info = reconstructDiskInfo(drive: 1, meta: meta)
    syncActiveCheats()
    drive0WriteProtected = pc88.isWriteProtected(drive: 0)
    drive1WriteProtected = pc88.isWriteProtected(drive: 1)
    // Cassette bytes round-trip inside the state file itself; only the UI's
    // mount display needs restoring here, driven off the engine's own
    // isLoaded rather than the (possibly absent/stale) saved meta.
    //
    // Reading the deck is safe at this point specifically because the loop is
    // stopped and joined around this call — it is not safe from the UI, which
    // is why `isTapeMounted` is a mirrored property rather than a passthrough.
    isTapeMounted = pc88.isTapeLoaded
    if isTapeMounted {
      tapeName = meta?.tapeName ?? "Tape"
      tapeSourceURL = meta?.tapeSourceURL.flatMap { URL(string: $0) }
      tapeFormat = (meta?.tapeFormatT88 ?? false) ? .t88 : .cmt
    } else {
      tapeName = "Empty"
      tapeSourceURL = nil
      tapeFormat = nil
    }
    tapeProgress = pc88.tapeProgress
    restoreCD(from: meta)
    activeClock8MHz = pc88.clock8MHz
    renderScreen()
    clearRewindBuffer()
    if wasRunning { start() }
  }

  private func saveStateLoadErrorMessage(_ error: Error) -> String {
    if let err = error as? SaveStateError {
      switch err {
      case .invalidMagic:
        return String(localized: "Load failed: not a save state file", comment: "")
      case .unsupportedVersion(let v):
        let fmt = String(localized: "Load failed: incompatible save state (v%u)", comment: "")
        return String(format: fmt, v)
      case .missingSections, .sectionTooSmall, .invalidData, .endOfData:
        return String(localized: "Load failed: save state is corrupt", comment: "")
      }
    }
    return String(localized: "Load failed", comment: "")
  }

  /// Reconstruct MountedDiskInfo for a drive after loading a save state.
  /// If the original source file is available, re-parse it for multi-image support.
  /// For archives, re-extract the relevant entry from the archive.
  /// Otherwise, build minimal info from the restored single disk.
  private func reconstructDiskInfo(drive: Int, meta: SaveMeta?) -> MountedDiskInfo? {
    guard let disk = pc88.mountedDisk(drive: drive) else { return nil }
    let fileName = (drive == 0 ? drive0FileName : drive1FileName) ?? "Disk"
    let savedURLString = drive == 0 ? meta?.drive0SourceURL : meta?.drive1SourceURL
    let savedImageIndex = drive == 0 ? meta?.drive0ImageIndex : meta?.drive1ImageIndex
    let archiveEntry = drive == 0 ? meta?.drive0ArchiveEntry : meta?.drive1ArchiveEntry

    if let urlString = savedURLString, let url = URL(string: urlString),
       let data = try? Data(contentsOf: url) {

      // Check if source is an archive
      if let archiveEntries = ArchiveExtractor.extractDiskImages(data) {
        // Extract the archive into the cache to secure a write-back
        // destination. On failure fall back to nil and mount from the in-memory
        // data.
        let cache = DiskCacheManager.shared
        let cacheDir = try? cache.ensureCached(archiveURL: url,
                                               archiveData: data,
                                               entries: archiveEntries)
        if let entryName = archiveEntry {
          // Specific entry within archive
          if let entry = archiveEntries.first(where: { $0.filename == entryName }) {
            let allImages = D88Disk.parseAll(data: Array(cache.resolvedData(for: entry, in: cacheDir)))
            if !allImages.isEmpty {
              let d88Name = (entryName as NSString).deletingPathExtension
              let imageNames = allImages.enumerated().map { i, d in
                d.name.isEmpty ? (allImages.count > 1 ? "\(d88Name) #\(i)" : d88Name) : d.name
              }
              let groups = [DiskImageGroup(d88FileName: d88Name,
                                           startIndex: 0, count: allImages.count)]
              let index = min(savedImageIndex ?? 0, allImages.count - 1)
              let cacheEntryURL = cacheDir.flatMap {
                cache.cachedEntryURL(in: $0, entryName: entryName)
              }
              return MountedDiskInfo(sourceURL: cacheEntryURL,
                                     archiveEntryName: entryName,
                                     originArchiveURL: url,
                                     allImages: allImages, imageNames: imageNames,
                                     currentImageIndex: index, fileName: fileName,
                                     imageGroups: groups)
            }
          }
        } else {
          // Mount 0&1 mode: flatten all entries
          var allDisks: [(disk: D88Disk, name: String)] = []
          var groups: [DiskImageGroup] = []
          for entry in archiveEntries {
            let disks = D88Disk.parseAll(data: Array(cache.resolvedData(for: entry, in: cacheDir)))
            let baseName = (entry.filename as NSString).deletingPathExtension
            groups.append(DiskImageGroup(d88FileName: baseName,
                                         startIndex: allDisks.count, count: disks.count))
            for d in disks {
              allDisks.append((d, d.name.isEmpty ? baseName : d.name))
            }
          }
          if !allDisks.isEmpty {
            let index = min(savedImageIndex ?? 0, allDisks.count - 1)
            return MountedDiskInfo(sourceURL: url,
                                   archiveEntryName: nil,
                                   originArchiveURL: url,
                                   allImages: allDisks.map(\.disk),
                                   imageNames: allDisks.map(\.name),
                                   currentImageIndex: index, fileName: fileName,
                                   imageGroups: groups)
          }
        }
      } else {
        // Direct D88 file (existing logic)
        let allImages = D88Disk.parseAll(data: [UInt8](data))
        if !allImages.isEmpty {
          return makeDirectDiskInfo(allImages: allImages, fileName: fileName,
                                    imageIndex: savedImageIndex ?? 0, sourceURL: url)
        }
      }
    }

    // Fallback: single disk from restored state
    let name = disk.name.isEmpty ? fileName : disk.name
    return MountedDiskInfo(sourceURL: nil,
                           archiveEntryName: nil,
                           originArchiveURL: nil,
                           allImages: [disk], imageNames: [name],
                           currentImageIndex: 0, fileName: fileName,
                           imageGroups: [DiskImageGroup(d88FileName: fileName,
                                                        startIndex: 0, count: 1)])
  }

  // MARK: - Resume

  /// Written on every quit regardless of `Settings.resumeOnLaunch`; the
  /// setting only decides whether the next launch restores it. Kept apart
  /// from the quick-save file and the slots so it never overwrites either.
  private var resumeStatePath: URL {
    Self.saveStateDir.appending(component: "resume.b88s")
  }

  /// Saves the machine for the next launch. Called from
  /// `applicationWillTerminate`, so it neither restarts the run loop nor
  /// shows a toast. Quitting from the menu does not stop emulation first,
  /// hence the `stop()`.
  func saveResumeState() {
    guard romLoaded else { return }
    if isRunning { stop() }
    try? writeSaveState(to: resumeStatePath)
  }

  /// Restores the state saved at the last quit, when the setting asks for it
  /// and nothing was opened at launch: a disk, URL, script or command-line
  /// argument means the user wants that instead. Must run after `loadROMs()`,
  /// whose `installExtRAM` would replace the extended RAM the state restores,
  /// and before `start()`.
  ///
  /// - Returns: the toast to show once the machine is running, or nil when
  ///   nothing was attempted. A toast shown here would be replaced by
  ///   `start()`'s own.
  func restoreResumeStateIfNeeded() -> String? {
    guard Settings.shared.resumeOnLaunch, romLoaded,
          pendingScriptURL == nil, pendingLaunchRequest == nil, pendingCDURL == nil,
          !hasCommandLineLaunch,
          let fileData = try? Data(contentsOf: resumeStatePath) else { return nil }
    do {
      try applySaveState(fileData, from: resumeStatePath)
      return String(localized: "Resumed", comment: "Toast after restoring the state saved at the last quit")
    } catch {
      // A failed load may leave the machine partly restored, including disks
      // the UI does not know about. Nothing was mounted before this point, so
      // ejecting everything and resetting gives an ordinary cold boot.
      emuQueue.sync {
        pc88.ejectDisk(drive: 0)
        pc88.ejectDisk(drive: 1)
        pc88.ejectTape()
        pc88.ejectCD()
      }
      clearCDDisplay()
      performReset(resetTranslation: false)
      return saveStateLoadErrorMessage(error)
    }
  }

  /// Whether the process was launched with arguments that boot something.
  /// Malformed arguments count too: `requestLaunchFromCommandLine()` reports
  /// them, and resuming underneath that alert would be surprising.
  private var hasCommandLineLaunch: Bool {
    do {
      return try LaunchRequest.fromCommandLine() != nil
    } catch {
      return true
    }
  }

  func quickSave() { performSave(to: quickSavePath) }
  func quickLoad() { performLoad(from: quickSavePath) }
  func saveState(slot: Int) {
    lastUsedSlot = slot
    performSave(to: saveStatePath(slot: slot))
  }

  func loadState(slot: Int) {
    lastUsedSlot = slot
    performLoad(from: saveStatePath(slot: slot))
  }

  func hasState(slot: Int) -> Bool {
    FileManager.default.fileExists(atPath: saveStatePath(slot: slot).path)
  }

  var hasQuickSave: Bool {
    _ = saveStateRevision
    return FileManager.default.fileExists(atPath: quickSavePath.path)
  }

  /// Short info line shown below Quick Load in the menu.
  /// Incremented after each quick save to trigger SwiftUI menu refresh.
  var saveStateRevision: Int = 0

  var quickSaveInfo: String {
    _ = saveStateRevision  // observe to trigger refresh
    guard hasQuickSave,
          let attrs = try? FileManager.default.attributesOfItem(atPath: quickSavePath.path),
          let date = attrs[.modificationDate] as? Date else { return "" }
    let fmt = DateFormatter.stable(pattern: "MM/dd HH:mm")
    var parts = [fmt.string(from: date)]
    if let meta = loadMeta(for: quickSavePath) {
      let name0: String? = meta.drive0FileName ?? meta.drive0Name
      let name1: String? = meta.drive1FileName ?? meta.drive1Name
      var names: [String] = []
      if let n = name0, !n.isEmpty { names.append(n) }
      if let n = name1, !n.isEmpty, n != name0 { names.append(n) }
      parts.append(contentsOf: names)
    }
    return parts.joined(separator: " — ")
  }

  var quickSaveLabel: String {
    guard hasQuickSave,
          let attrs = try? FileManager.default.attributesOfItem(atPath: quickSavePath.path),
          let date = attrs[.modificationDate] as? Date else {
      return "Quick Load"
    }
    let fmt = DateFormatter.stable(pattern: "MM/dd HH:mm")
    var label = "Quick Load — \(fmt.string(from: date))"
    if let meta = loadMeta(for: quickSavePath) {
      let disks = [meta.disk0, meta.disk1].compactMap { $0 }.filter { !$0.isEmpty }
      if !disks.isEmpty {
        label += " — \(disks.joined(separator: ", "))"
      }
    }
    return label
  }

  var quickSaveThumbnail: NSImage? {
    guard let data = loadThumbnailData(for: quickSavePath) else { return nil }
    return NSImage(data: data)
  }

  func loadSlotMeta(_ slot: Int) -> SaveMeta? {
    loadMeta(for: saveStatePath(slot: slot))
  }

  func slotThumbnail(_ slot: Int) -> NSImage? {
    guard let data = loadThumbnailData(for: saveStatePath(slot: slot)) else { return nil }
    return NSImage(data: data)
  }

  /// Every slot with its date and disk names, read from the state files once
  /// so the picker can filter and sort without touching the disk again.
  func saveSlotEntries() -> [SaveSlotEntry] {
    SaveSlotList.slots.map { slot in
      let path = saveStatePath(slot: slot)
      let modified = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
      guard modified != nil else { return SaveSlotEntry(slot: slot, modified: nil, diskNames: []) }
      let meta = loadSlotMeta(slot)
      var names: [String] = []
      for name in [meta?.drive0FileName ?? meta?.drive0Name, meta?.drive1FileName ?? meta?.drive1Name] {
        if let name, !name.isEmpty, !names.contains(name) { names.append(name) }
      }
      return SaveSlotEntry(slot: slot, modified: modified, diskNames: names)
    }
  }

  /// Drive 0's file name, which groups the picker's "by game" order.
  var currentGameName: String? {
    drive0FileName ?? (drive0Name == "Empty" ? nil : drive0Name)
  }

  /// Slot last saved to or loaded from, so the Touch Bar can open on it.
  var lastUsedSlot: Int?

  func slotLabel(_ slot: Int) -> String {
    let path = saveStatePath(slot: slot)
    guard FileManager.default.fileExists(atPath: path.path),
          let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
          let date = attrs[.modificationDate] as? Date else {
      return "Slot \(slot) — Empty"
    }
    let fmt = DateFormatter.stable(pattern: "MM/dd HH:mm")
    var label = "Slot \(slot) — \(fmt.string(from: date))"
    if let meta = loadSlotMeta(slot) {
      let disks = [meta.disk0, meta.disk1].compactMap { $0 }.filter { !$0.isEmpty }
      if !disks.isEmpty {
        label += " — \(disks.joined(separator: ", "))"
      }
    }
    return label
  }

  // MARK: - Keyboard

  /// Handle key down event. Maps macOS keyCode to PC-8801 keyboard matrix.
  func keyDown(_ keyCode: UInt16) {
    // ESC during an in-flight clipboard paste cancels the paste and is
    // swallowed, matching X88000M. Otherwise ESC reaches the emulator
    // normally (PC88Key.esc at row 9 / bit 7).
    // Tape Auto Boot and a memory-image load count too: they wait with the
    // queue empty.
    if keyCode == 0x35
      && (!pasteQueue.isEmpty || isTapeAutoBootActive || isMemoryImageBootActive) {
      cancelPasteQueue()
      return
    }
    // The control-zone editor owns the keyboard while it is open: Delete
    // removes the selected zone and nothing reaches the paused machine.
    if isEditingClickZones {
      if (keyCode == 0x33 || keyCode == 0x75) && !isRecordingClickZoneKeys {
        deleteSelectedClickZone()
      }
      return
    }
    // ESC during a control-zone sequence cancels it, like a paste.
    if keyCode == 0x35 && !clickZonePlayer.isIdle {
      cancelClickZonePlayer()
      return
    }
    guard let key = KeyMapping.pc88Key(for: keyCode) else { return }
    // Recording rides along with the event so `ScriptRecorder` stays confined
    // to the emulation thread, in the same order the matrix sees the press.
    postInput(.pressKey(key, record: true))
  }

  func keyUp(_ keyCode: UInt16) {
    guard !isEditingClickZones else { return }
    guard let key = KeyMapping.pc88Key(for: keyCode) else { return }
    postInput(.releaseKey(key, record: true))
  }

  /// Keys the host currently holds down on the emulated keyboard, whichever way
  /// they got there (keyboard, controller, Touch Bar). Mirrors the matrix as
  /// this layer drives it, for UI that has to show a held key.
  ///
  /// Cleared wherever the machine's own matrix is replaced or reset: a state
  /// load and a reset (a rewind goes through `releaseAllKeys()`).
  private(set) var heldKeys: Set<PC88Key> = []

  /// Press a PC-8801 key directly (used by game controller).
  func pressKey(_ key: PC88Key) {
    postInput(.pressKey(key, record: false))
  }

  /// Release a PC-8801 key directly (used by game controller).
  func releaseKey(_ key: PC88Key) {
    postInput(.releaseKey(key, record: false))
  }

  /// Release every held key. Used when a rewind swaps the matrix out from
  /// under whatever the user is physically holding.
  func releaseAllKeys() {
    postInput(.releaseAllKeys)
  }

  // MARK: - Bus mouse

  /// Whether the mouse intercepts OPN I/O port reads.
  /// Mirrors `Settings.shared.mouseEnabled`.
  ///
  /// The getter reads a host-side mirror rather than `machine.mouse`: the
  /// setter only queues the change, so the machine may not have picked it up
  /// yet when the value is read back.
  var mouseModeEnabled: Bool {
    get { mouseEnabledMirror }
    set {
      mouseEnabledMirror = newValue
      postInput(.mouseEnabled(newValue))
    }
  }

  /// Mouse read mode: false = bus mouse (strobed), true = joystick mode.
  /// Mirrors `Settings.shared.mouseJoyMode`.
  var mouseJoyMode: Bool {
    get { mouseJoyModeMirror }
    set {
      mouseJoyModeMirror = newValue
      postInput(.mouseJoyMode(newValue))
    }
  }

  /// Feed host relative mouse movement to the emulated bus mouse.
  func injectMouseMovement(dx: Int, dy: Int) {
    postInput(.mouseMovement(dx: dx, dy: dy))
  }

  /// Set the emulated bus mouse left/right button state.
  func setMouseButton(left: Bool, right: Bool) {
    postInput(.mouseButtons(left: left, right: right))
  }

  // MARK: - Input event plumbing

  /// Queue an input event for the emulation loop.
  ///
  /// While the loop is parked there is no emulation thread to race with and
  /// nothing that would drain the queue, so the event is applied inline —
  /// keys pressed while paused still reach the matrix, as they always have.
  private func postInput(_ event: InputEvent) {
    switch event {
    case .pressKey(let key, _): heldKeys.insert(key)
    case .releaseKey(let key, _): heldKeys.remove(key)
    case .releaseAllKeys: heldKeys.removeAll()
    default: break
    }
    inputQueue.post(event)
    // Draining inline is only safe when nothing else is touching the machine.
    // `isRunning` alone does not establish that: `stop()` clears it *before*
    // joining, so a keystroke landing in that window would mutate the matrix
    // while the final frame is still running. Taking the queue is correct
    // whatever the flag says, and free when the loop really is parked.
    if !isRunning {
      emuQueue.sync { applyPendingInput() }
    }
  }

  /// Apply everything queued to the machine. Called at the frame boundary by
  /// the emulation loop, and inline by `postInput` while the loop is parked.
  nonisolated func applyPendingInput() {
    for event in inputQueue.drain() {
      apply(event)
    }
  }

  /// Apply one input event to the machine. Emulation thread (or main, while
  /// the loop is parked).
  nonisolated func apply(_ event: InputEvent) {
    switch event {
    case .pressKey(let key, let record):
      pc88.pressKey(key)
      // Only real user input is recorded; the script player and the paste
      // queue inject keys that a recording must not capture.
      if record { scriptRecorder?.keyDown(key) }
    case .releaseKey(let key, let record):
      pc88.releaseKey(key)
      if record { scriptRecorder?.keyUp(key) }
    case .releaseAllKeys:
      pc88.releaseAllKeys()
    case .mouseMovement(let dx, let dy):
      pc88.moveMouse(dx: dx, dy: dy)
    case .mouseButtons(let left, let right):
      pc88.setMouseButtons(left: left, right: right)
    case .mouseEnabled(let on):
      pc88.mouseEnabled = on
    case .mouseJoyMode(let on):
      pc88.mouseJoystickMode = on
    }
  }
}

// MARK: - Mounted Disk Info

/// A group of disk images originating from a single D88 file.
nonisolated struct DiskImageGroup {
  let d88FileName: String
  let startIndex: Int
  let count: Int
}

/// Metadata about a mounted disk source for menu-based disk switching.
/// The kind of selection sheet to present right after a mount, along with the
/// payload it needs. One sum type in place of the former eight `pending*`
/// properties, and `Identifiable` so it can be handed straight to SwiftUI's
/// `.sheet(item:)`.
enum DiskPickerContext: Identifiable {
  /// The archive holds several .d88 entries; choose which one to mount.
  case archiveEntries(entries: [ArchiveEntry],
                      archiveURL: URL,
                      cacheDir: URL?,
                      drive: Int)
  /// A single .d88 file holds several banks (images); choose which one to mount.
  case multiImageD88(disks: [D88Disk],
                     sourceURL: URL?,
                     archiveEntryName: String?,
                     originArchiveURL: URL?,
                     drive: Int)

  var id: String {
    switch self {
    case .archiveEntries: return "archiveEntries"
    case .multiImageD88: return "multiImageD88"
    }
  }
}

nonisolated struct MountedDiskInfo: Identifiable, Equatable {
  /// Issued once per mount session, for SwiftUI's `.id()` and `.onChange(of:)`
  /// change detection.
  let id: UUID
  /// Write-back destination. For archive-backed disks this is the .d88 inside
  /// DiskCacheManager's cache; for a directly mounted .d88 it is the original
  /// file.
  let sourceURL: URL?
  /// Entry name within the original archive, before NFC normalization. nil for
  /// a directly mounted .d88.
  let archiveEntryName: String?
  /// URL of the original archive, for archive-backed disks only. Currently used
  /// just to derive `fileName`; using it as the starting point for export and
  /// state restore is planned for Phase 3 onwards.
  let originArchiveURL: URL?
  let allImages: [D88Disk]
  let imageNames: [String]
  var currentImageIndex: Int
  let fileName: String
  let imageGroups: [DiskImageGroup]

  init(sourceURL: URL?, archiveEntryName: String?, originArchiveURL: URL?,
       allImages: [D88Disk], imageNames: [String], currentImageIndex: Int,
       fileName: String, imageGroups: [DiskImageGroup]) {
    self.id = UUID()
    self.sourceURL = sourceURL
    self.archiveEntryName = archiveEntryName
    self.originArchiveURL = originArchiveURL
    self.allImages = allImages
    self.imageNames = imageNames
    self.currentImageIndex = currentImageIndex
    self.fileName = fileName
    self.imageGroups = imageGroups
  }

  /// `D88Disk` is not Equatable, so this compares only the mount session ID and
  /// the display fields — enough for SwiftUI to tell whether it is the same
  /// mount.
  static func == (lhs: MountedDiskInfo, rhs: MountedDiskInfo) -> Bool {
    lhs.id == rhs.id
      && lhs.currentImageIndex == rhs.currentImageIndex
      && lhs.sourceURL == rhs.sourceURL
  }
}
