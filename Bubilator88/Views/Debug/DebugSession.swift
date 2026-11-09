import SwiftUI
@_spi(Debug) import Bubilator88Core

/// Owns the live state for the Debug Window.
///
/// - Polls Machine state on the emulator queue and republishes a
///   ``MachineSnapshot`` to the main actor for SwiftUI views.
/// - Hosts UI-side state that is not part of `Debugger` itself
///   (hex viewer cursor, BP entry text fields, etc.).
/// - Forwards user run-control actions (Run / Pause / Step) to the
///   underlying ``Debugger``.
@Observable
@MainActor
final class DebugSession {

  // MARK: - Constants

  /// Number of bytes shown in the disassembly memory window.
  nonisolated private static let disasmWindowBytes = 64

  /// Bytes of leading context shown before the current PC in the
  /// disassembly window. Clamped at low addresses to avoid wrap.
  nonisolated private static let disasmWindowLookback: UInt16 = 8

  // MARK: - Bindings

  let viewModel: EmulatorViewModel
  let settings: DebugSettings

  var debugger: Debugger { viewModel.debugger }

  // MARK: - Snapshot

  var snapshot: MachineSnapshot = .placeholder

  /// Fast-polled run state (50 ms interval) — the single source of truth
  /// for run/pause detection throughout the UI.
  ///
  /// Kept separate from `snapshot.debuggerRunState` so that breakpoint hits
  /// and user-initiated pauses surface immediately without waiting for the
  /// 1-second slow snapshot cycle that runs while the emulator is active.
  private(set) var debuggerRunState: Debugger.RunState = .running

  /// Previous run state used by `reportRunStateTransitionIfNeeded`
  /// to suppress duplicate toasts when the state doesn't change.
  private var lastSeenRunState: Debugger.RunState = .running

  // MARK: - User-controlled view state

  /// Base address shown in the hex viewer.
  var hexBaseAddress: UInt16 = 0x0000 {
    didSet { UserDefaults.standard.set(Int(hexBaseAddress), forKey: DebugSettings.Keys.hexBaseAddress) }
  }

  /// Number of rows × 16 bytes shown in the hex viewer.
  var hexRowCount: Int = 16 {
    didSet { UserDefaults.standard.set(hexRowCount, forKey: DebugSettings.Keys.hexRowCount) }
  }

  /// Whether the disasm pane follows the current PC automatically.
  ///
  /// Set to `false` when the user clicks a row in the Trace pane;
  /// the disasm window then shows bytes around `disasmPinnedAddress`
  /// instead of live PC. Any run-control action (Run/Pause/Step/CPU
  /// switch) resets this back to `true`.
  var disasmFollowsPC: Bool = true

  /// Address the disasm window is pinned to when `disasmFollowsPC`
  /// is false. Meaningless when `disasmFollowsPC` is true.
  var disasmPinnedAddress: UInt16 = 0

  /// Currently selected CPU for the disasm pane.
  var focusedCPU: DebugSettings.FocusedCPU = .main {
    didSet {
      if oldValue != focusedCPU {
        disasmFollowsPC = true
        UserDefaults.standard.set(focusedCPU.rawValue, forKey: DebugSettings.Keys.focusedCPU)
      }
    }
  }

  // MARK: - BP entry form state

  var newBPAddressText: String = ""
  var newBPKind: DebugSettings.NewBPKind = .mainPC {
    didSet { UserDefaults.standard.set(newBPKind.rawValue, forKey: DebugSettings.Keys.newBPKind) }
  }
  /// Optional byte-match filter for memW/ioW breakpoints. Empty
  /// string means "fire on any value".
  var newBPValueText: String = ""

  // MARK: - Init

  init(viewModel: EmulatorViewModel) {
    self.viewModel = viewModel
    self.settings  = DebugSettings()
    let ud = UserDefaults.standard
    if let v = ud.object(forKey: DebugSettings.Keys.hexBaseAddress) as? Int {
      hexBaseAddress = UInt16(max(0, min(65535, v)))
    }
    if let v = ud.object(forKey: DebugSettings.Keys.hexRowCount) as? Int {
      hexRowCount = max(4, min(64, v))
    }
    if let raw = ud.string(forKey: DebugSettings.Keys.focusedCPU),
       let cpu = DebugSettings.FocusedCPU(rawValue: raw) {
      focusedCPU = cpu
    }
    if let raw = ud.string(forKey: DebugSettings.Keys.newBPKind),
       let kind = DebugSettings.NewBPKind(rawValue: raw) {
      newBPKind = kind
    }
  }

  // MARK: - Lifecycle

  /// Slow-path poll: rebuilds the full MachineSnapshot.
  private var pollTask: Task<Void, Never>?
  /// Fast-path poll: checks runState only (50 ms), triggers
  /// immediate refresh on pause and updates `debuggerRunState`.
  private var runStateTask: Task<Void, Never>?

  /// Begin polling and attach the debugger to Machine.
  ///
  /// Note: we do **not** auto-pause the emulator here. SwiftUI's
  /// `UtilityWindow` is instantiated eagerly and fires `onAppear`
  /// even when the window is hidden, which means this method runs
  /// at every app launch regardless of whether the user actually
  /// opened the Debug Window. Auto-pausing here would freeze the
  /// emulator on cold launch. The user breaks explicitly via the
  /// Pause button in the toolbar.
  func start() {
    viewModel.attachDebugger()
    refresh()  // immediate first snapshot

    // Fast-path: polls only debugger.runState every 50 ms.
    // Detects breakpoint hits immediately and triggers a full refresh
    // on the running→paused transition. This keeps toolbar buttons and
    // per-pane auto-refresh responsive without running the heavy
    // snapshot capture at 20 Hz.
    runStateTask?.cancel()
    runStateTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled, let self else { break }
        let newState = self.debugger.runState
        guard newState != self.debuggerRunState else { continue }
        self.debuggerRunState = newState
        self.reportRunStateTransitionIfNeeded(newState)
        if case .paused = newState { self.refresh() }
      }
    }

    // Slow-path: builds the full MachineSnapshot for display.
    // 1 s while running  (registers change too fast to read at full speed),
    // 500 ms while paused (enough for interactive inspection).
    // A pause transition additionally triggers an immediate refresh via
    // the fast-path above, so the first post-pause snapshot is instant.
    pollTask?.cancel()
    pollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        let interval: Duration
        if let self {
          interval = self.debugger.isPaused ? .milliseconds(500) : .milliseconds(1000)
        } else { break }
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled, let self else { break }
        self.refresh()
      }
    }
  }

  /// Stop polling and detach the debugger.
  func stop() {
    runStateTask?.cancel()
    runStateTask = nil
    pollTask?.cancel()
    pollTask = nil
    viewModel.applyDebugChannelMask(.all)
    viewModel.detachDebugger()
  }

  // MARK: - Snapshot capture

  /// Capture a snapshot on the emulator queue and publish it back to the
  /// main actor.
  ///
  /// The capture runs off the main thread, but it is not free of it: the run
  /// loop holds `emuQueue` for each frame, so this block waits for a frame
  /// boundary and the next frame waits for this block. That is the point —
  /// reading Z80/VRAM state while `machine.runFrame()` mutates it is a data
  /// race. At the 0.5–1 s poll cadence the cost is a single delayed frame.
  func refresh() {
    let hexBase = hexBaseAddress
    let hexCount = hexRowCount * 16
    let pinnedMain: UInt16? = (focusedCPU == .main && !disasmFollowsPC) ? disasmPinnedAddress : nil
    let pinnedSub:  UInt16? = (focusedCPU == .sub  && !disasmFollowsPC) ? disasmPinnedAddress : nil
    let disasmEnabled = settings.disasmEnabled
    let pc88 = viewModel.pc88
    let debugger = self.debugger
    viewModel.emuQueue.async { [weak self] in
      let snap = Self.captureSnapshot(
        pc88: pc88,
        debugger: debugger,
        hexBase: hexBase,
        hexCount: hexCount,
        pinnedMainDisasm: pinnedMain,
        pinnedSubDisasm: pinnedSub,
        disasmEnabled: disasmEnabled
      )
      Task { @MainActor [weak self] in
        guard let self else { return }
        if snap != self.snapshot {
          self.snapshot = snap
        }
      }
    }
  }

  /// Build a snapshot from the current machine state. Pure: takes
  /// only what it needs as parameters so it can run on any thread.
  ///
  /// When `pinnedMainDisasm` / `pinnedSubDisasm` is non-nil, the
  /// corresponding disasm window is built from that address instead
  /// of the live PC — used when the user has clicked a row in the
  /// Trace pane to navigate back in history.
  nonisolated private static func captureSnapshot(
    pc88: PC88,
    debugger: Debugger,
    hexBase: UInt16,
    hexCount: Int,
    pinnedMainDisasm: UInt16?,
    pinnedSubDisasm: UInt16?,
    disasmEnabled: Bool
  ) -> MachineSnapshot {
    let cpu = pc88.registers(of: .main)
    let sub = pc88.registers(of: .sub)

    let mainBase = clampedBase(pc: pinnedMainDisasm ?? cpu.pc)
    let subBase  = clampedBase(pc: pinnedSubDisasm  ?? sub.pc)

    let mainDisasm: MemoryWindow
    let subDisasm: MemoryWindow
    if disasmEnabled {
      mainDisasm = readWindow(
        base: mainBase,
        length: disasmWindowBytes,
        read: { pc88.readMemory(.main, $0) }
      )
      subDisasm = readWindow(
        base: subBase,
        length: disasmWindowBytes,
        read: { pc88.readMemory(.sub, $0) }
      )
    } else {
      // Disasm disabled: skip the 128 bus reads and hand the pane an
      // empty window. The pane's `computeLines` bails out on empty
      // input, so no decoding runs either.
      mainDisasm = MemoryWindow(baseAddress: mainBase, bytes: [])
      subDisasm  = MemoryWindow(baseAddress: subBase,  bytes: [])
    }
    let hex = readWindow(
      base: hexBase,
      length: hexCount,
      read: { pc88.readMemory(.main, $0) }
    )

    return MachineSnapshot(
      mainPC: cpu.pc,
      mainSP: cpu.sp,
      mainAF: cpu.af, mainBC: cpu.bc, mainDE: cpu.de, mainHL: cpu.hl,
      mainIX: cpu.ix, mainIY: cpu.iy,
      mainAF2: cpu.af2, mainBC2: cpu.bc2, mainDE2: cpu.de2, mainHL2: cpu.hl2,
      mainI: cpu.i, mainR: cpu.r,
      mainIff1: cpu.iff1, mainIff2: cpu.iff2,
      mainIM: cpu.im, mainHalted: cpu.halted,
      subPC: sub.pc, subSP: sub.sp,
      subAF: sub.af, subBC: sub.bc, subDE: sub.de, subHL: sub.hl,
      subIX: sub.ix, subIY: sub.iy,
      subAF2: sub.af2, subBC2: sub.bc2, subDE2: sub.de2, subHL2: sub.hl2,
      subI: sub.i, subR: sub.r,
      subHalted: sub.halted, subIff1: sub.iff1, subIff2: sub.iff2, subIM: sub.im,
      totalTStates: pc88.totalTStates,
      debuggerRunState: debugger.runState,
      mainDisasmWindow: mainDisasm,
      subDisasmWindow: subDisasm,
      hexWindow: hex
    )
  }

  /// Clamp the disassembly window base so it never wraps around the
  /// 16-bit address space when the current PC is near 0x0000.
  nonisolated private static func clampedBase(pc: UInt16) -> UInt16 {
    pc < disasmWindowLookback ? 0 : pc &- disasmWindowLookback
  }

  nonisolated private static func readWindow(
    base: UInt16,
    length: Int,
    read: (UInt16) -> UInt8
  ) -> MemoryWindow {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(length)
    for i in 0..<length {
      bytes.append(read(base &+ UInt16(i)))
    }
    return MemoryWindow(baseAddress: base, bytes: bytes)
  }

  // MARK: - Run control actions

  func resume() {
    disasmFollowsPC = true
    debugger.resume()
    debuggerRunState = .running   // immediate UI update; fast-path confirms at next tick
    viewModel.resume()
    refresh()
  }

  func pause() {
    debugger.pauseRequest(reason: .userRequest)
    debuggerRunState = .paused(reason: .userRequest)  // immediate UI update
    viewModel.pause()
    refresh()
  }

  /// Advance the main CPU by exactly one instruction while Metal
  /// and audio remain stopped. The tick runs on the emu queue for
  /// thread-safety, then we render one frame manually so a VRAM
  /// write executed by the stepped instruction becomes visible.
  func stepMain() {
    disasmFollowsPC = true
    // Ensure the emulator is halted before stepping. If the user
    // hit Step while running, treat it as "pause then step".
    if viewModel.isRunning {
      viewModel.pause()
    }
    let vm = viewModel
    vm.emuQueue.async { [weak self] in
      vm.pc88.stepInstruction(.main)
      Task { @MainActor [weak self] in
        guard let self else { return }
        vm.renderSingleFrame()
        self.refresh()
      }
    }
  }

  /// Advance the sub CPU by exactly one instruction. SubSystem
  /// exposes `runSubCPU(maxTStates:)` which will stop on the next
  /// instruction boundary once at least one instruction has run.
  func stepSub() {
    disasmFollowsPC = true
    if viewModel.isRunning {
      viewModel.pause()
    }
    let vm = viewModel
    vm.emuQueue.async { [weak self] in
      vm.pc88.stepInstruction(.sub)
      Task { @MainActor [weak self] in
        guard let self else { return }
        vm.renderSingleFrame()
        self.refresh()
      }
    }
  }

  /// Detect transitions into a paused-by-breakpoint state and
  /// surface them as a Toast. The run/pause button handlers
  /// already toast their own transitions; this covers the
  /// "emulator hit a BP on its own" case where the transition
  /// originates from the emu queue.
  private func reportRunStateTransitionIfNeeded(_ newState: Debugger.RunState) {
    defer { lastSeenRunState = newState }
    guard lastSeenRunState != newState else { return }
    if case .paused(let reason) = newState {
      switch reason {
      case .breakpoint, .watch:
        viewModel.showToast("Breakpoint hit")
      case .userRequest, .initialLaunch:
        break
      }
    }
  }

  /// Pin the disassembly window to an address captured from the
  /// trace history. Also switches the CPU picker if needed.
  func jumpDisasm(to address: UInt16, cpu: DebugSettings.FocusedCPU) {
    focusedCPU = cpu
    disasmPinnedAddress = address
    disasmFollowsPC = false
    refresh()
  }

  // MARK: - GVRAM viewer state

  /// Raw GVRAM plane bytes (3 × 16 KB), updated by ``captureGVRAM()``.
  /// Access only on main actor.
  var gvramBlue:  [UInt8] = []
  var gvramRed:   [UInt8] = []
  var gvramGreen: [UInt8] = []

  /// True when the captured snapshot is in 400-line monochrome mode.
  /// In that mode: Blue = upper 200 lines, Red = lower 200 lines, Green unused.
  var gvram400LineMode: Bool = false

  /// Expanded 8-entry palette at capture time (index = (G<<2)|(R<<1)|B).
  /// Used by GVRAMPane Composite mode to apply the hardware palette.
  var gvramPalette: [(r: UInt8, g: UInt8, b: UInt8)] = Array(repeating: (0, 0, 0), count: 8)

  /// Monotonically-increasing counter bumped after each GVRAM capture.
  /// GVRAMPane observes this to know when to rebuild its CGImage.
  var gvramVersion: Int = 0

  /// Fetch the three GVRAM bitplanes, line-mode flag, and palette on the
  /// emulator queue and publish them back to the main actor.
  /// Increments `gvramVersion` on completion.
  func captureGVRAM() {
    let pc88 = viewModel.pc88
    viewModel.emuQueue.async { [weak self] in
      let capture = pc88.captureGVRAM()
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.gvramBlue        = capture.blue
        self.gvramRed         = capture.red
        self.gvramGreen       = capture.green
        self.gvram400LineMode = capture.is400LineMode
        self.gvramPalette     = capture.palette
        self.gvramVersion &+= 1
      }
    }
  }

  // MARK: - Text VRAM viewer state

  /// Rendered RGBA8 frame — text layer only (dark-gray background).
  /// 640×200 in normal mode, 640×400 in 400-line mode.
  /// Produced on the emu queue by ``captureTextVRAM()``.
  var textVRAMImageData: Data?

  /// True when the last capture was in 400-line mode → image is 640×400.
  var textVRAMHireso: Bool = false

  /// Raw character codes (cols × rows). Kept for the attribute decode panel.
  var textVRAMChars: [UInt8] = []

  /// Raw attribute bytes (cols × rows). Kept for the attribute decode panel.
  var textVRAMAttrs: [UInt8] = []

  /// Number of displayed columns (40 or 80).
  var textVRAMCols: Int = 80

  /// Number of displayed rows (typically 20 or 25).
  var textVRAMRows: Int = 25

  /// CRTC cursor column (character units, -1 = none).
  var textVRAMCursorX: Int = -1

  /// CRTC cursor row (character units, -1 = none).
  var textVRAMCursorY: Int = -1

  /// Whether the CRTC cursor is currently enabled.
  var textVRAMCursorEnabled: Bool = false

  /// Bumped each time a text VRAM capture completes.
  var textVRAMVersion: Int = 0

  /// Render the text layer into an RGBA buffer on the emu queue and publish
  /// the result to the main actor. Increments `textVRAMVersion` on completion.
  ///
  /// All font rendering runs on the emu queue so `FontROM` is accessed from its
  /// home thread; only the finished `Data` is transferred back to main.
  func captureTextVRAM() {
    let pc88 = viewModel.pc88
    viewModel.emuQueue.async { [weak self] in
      // Dark grey behind the text, so text cells stand out from graphics
      // masked to black.
      let capture = pc88.captureTextVRAM(backgroundGray: 0x1A)
      let imageData = Data(capture.image)

      Task { @MainActor [weak self] in
        guard let self else { return }
        self.textVRAMImageData     = imageData
        self.textVRAMHireso        = capture.is400LineMode
        self.textVRAMChars         = capture.characters
        self.textVRAMAttrs         = capture.attributes
        self.textVRAMCols          = capture.columns
        self.textVRAMRows          = capture.rows
        self.textVRAMCursorX       = capture.cursorX
        self.textVRAMCursorY       = capture.cursorY
        self.textVRAMCursorEnabled = capture.cursorEnabled
        self.textVRAMVersion      &+= 1
      }
    }
  }

  // MARK: - BP mutation helpers
  //
  // Wrap every Debugger mutation in a session method so that bumping
  // `bpVersion` (an `@Observable`-tracked property) causes SwiftUI to
  // re-render BreakpointPane even though `Debugger` itself is not
  // `@Observable`.

  private(set) var bpVersion: Int = 0

  func removeBreakpoint(id: UUID) {
    debugger.remove(id: id)
    bpVersion &+= 1
  }

  func removeAllBreakpoints() {
    debugger.removeAll()
    bpVersion &+= 1
  }

  func setBreakpointEnabled(_ enabled: Bool, id: UUID) {
    debugger.setEnabled(enabled, id: id)
    bpVersion &+= 1
  }

  /// Bulk toggle: enable or disable every registered breakpoint in one shot.
  /// Iterates over the existing per-BP API rather than adding a new
  /// `Debugger` entry point so the emu core stays unchanged.
  func setAllBreakpointsEnabled(_ enabled: Bool) {
    for bp in debugger.breakpoints {
      debugger.setEnabled(enabled, id: bp.id)
    }
    bpVersion &+= 1
  }

  /// Aggregate enable state: true only when every breakpoint is enabled.
  /// Empty list is treated as enabled so the bulk toggle starts in the
  /// "armed" visual state.
  var allBreakpointsEnabled: Bool {
    let bps = debugger.breakpoints
    return bps.isEmpty || bps.allSatisfy { $0.isEnabled }
  }

  // MARK: - Live-refresh task factory

  /// Returns a self-cancelling `Task` that calls `action` every 500 ms
  /// while the emulator is running, and exits automatically on pause.
  ///
  /// The caller stores the returned `Task` and cancels it on view
  /// disappear. This deduplicates the boilerplate shared between
  /// `GVRAMPane` and `TextVRAMPane`.
  @MainActor
  func makeLiveRefreshTask(action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { break }
        guard let self else { break }
        // Use the fast-polled property so a pause stops the loop
        // within 50 ms rather than waiting for the next snapshot.
        if case .paused = self.debuggerRunState { break }
        action()
      }
    }
  }

  // MARK: - BP form actions

  func addNewBreakpoint() {
    guard let addr = Self.parseHex(newBPAddressText) else { return }
    let kind: Breakpoint.Kind
    switch newBPKind {
    case .mainPC: kind = .mainPC(addr)
    case .subPC:  kind = .subPC(addr)
    case .memR:   kind = .memoryRead(addr)
    case .memW:   kind = .memoryWrite(addr)
    case .ioR:    kind = .ioRead(addr & 0xFF)
    case .ioW:    kind = .ioWrite(addr & 0xFF)
    }
    // Value filter is only meaningful for write-side BPs. Parse
    // as a byte (high bits ignored); empty string leaves it nil.
    let valueFilter: UInt8? = {
      guard kind.supportsValueFilter,
            let word = Self.parseHex(newBPValueText) else { return nil }
      return UInt8(word & 0xFF)
    }()
    debugger.add(Breakpoint(kind: kind, valueFilter: valueFilter))
    bpVersion &+= 1
    newBPAddressText = ""
    newBPValueText = ""
  }

  /// Parse `1234`, `0x1234`, or `1234H` into a 16-bit address.
  static func parseHex(_ s: String) -> UInt16? {
    var trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
      trimmed = String(trimmed.dropFirst(2))
    } else if trimmed.hasSuffix("H") || trimmed.hasSuffix("h") {
      trimmed = String(trimmed.dropLast())
    }
    return UInt16(trimmed, radix: 16)
  }
}
