import AppIntents
import SwiftUI
import UniformTypeIdentifiers
import Bubilator88Core
import Translation

extension UTType {
  static let d88  = UTType(filenameExtension: "d88")!
  static let d77  = UTType(filenameExtension: "d77")!
  static let disk2d  = UTType(filenameExtension: "2d")!
  static let disk2hd = UTType(filenameExtension: "2hd")!
  static let cmt  = UTType(filenameExtension: "cmt")!
  static let t88  = UTType(filenameExtension: "t88")!
  static let n80  = UTType(filenameExtension: "n80")!
  // Declared in Info.plist, so Finder offers the app for them too.
  static let cue  = UTType(importedAs: "com.goldenhawk.cdrwin-cuesheet")
  static let ccd  = UTType(importedAs: "com.elby.clonecd-control")
  static let lzh  = UTType(filenameExtension: "lzh")!
  static let lha  = UTType(filenameExtension: "lha")!
  static let cab  = UTType(filenameExtension: "cab")!
  static let rar  = UTType(filenameExtension: "rar")!
  static let sevenZip = UTType(filenameExtension: "7z")!
  static let m3u  = UTType(filenameExtension: "m3u")!
  static let m3u8 = UTType(filenameExtension: "m3u8")!
}

private let diskFileTypes: [UTType] = [
  .d88, .d77, .disk2d, .disk2hd,   // disk images
  .m3u, .m3u8,                     // multi-disk playlist
  .zip, .lzh, .lha, .cab, .rar, .sevenZip  // archives
]

private let memoryImageFileTypes: [UTType] = [.n80]

private let cdFileTypes: [UTType] = [.cue, .ccd]

private let tapeFileTypes: [UTType] = [
  .cmt, .t88,                      // tape images
  .zip, .lzh, .lha, .cab, .rar, .sevenZip  // archives
]

// MARK: - ContentView

struct ContentView: View {
  @Bindable var viewModel: EmulatorViewModel

  var body: some View {
    VStack(spacing: 0) {
      // Screen area — 640×400 base, scaled by windowScale
      ZStack {
        screenView
        KeyEventView(
          onKeyDown: { viewModel.keyDown($0) },
          onKeyUp: { viewModel.keyUp($0) },
          onTurbo: { viewModel.turboMode = $0 },
          onRomajiKeyDown: { viewModel.handleRomajiKeyDown($0) },
          onMouseMove: { viewModel.injectMouseMovement(dx: $0, dy: $1) },
          onMouseButton: { viewModel.setMouseButton(left: $0, right: $1) },
          onZoneMouseInput: { viewModel.playClickZoneMouseButton($0) },
          mouseCaptureEnabled: Settings.shared.mouseEnabled,
          mouseSensitivity: Settings.shared.mouseSensitivity,
          onCaptureChange: { viewModel.mouseCapturing = $0 }
        )
        .onChange(of: Settings.shared.mouseEnabled, initial: true) { _, newValue in
          viewModel.mouseModeEnabled = newValue
        }
        .onChange(of: Settings.shared.mouseJoyMode, initial: true) { _, newValue in
          viewModel.mouseJoyMode = newValue
        }
        if viewModel.clickZonesAvailable || viewModel.isEditingClickZones {
          GeometryReader { geo in
            ClickZoneOverlayView(viewModel: viewModel, fit: screenFit(for: geo.size))
          }
        }
        if viewModel.translationManager.isSessionActive {
          TranslationOverlayView(
            detectionRects: viewModel.translationManager.isOverlayVisible
              ? viewModel.translationManager.ocrDetectionRects
              : [],
            fit: screenFit(for:)
          )
          .opacity(viewModel.translationManager.isOverlayVisible ? 1 : 0)
          .translationTask(viewModel.translationManager.configuration) { session in
            viewModel.translationManager.setSession(session)
          }
        }
        if viewModel.isRewinding {
          VStack {
            Spacer()
            RewindStripView(viewModel: viewModel)
          }
          .animation(.easeInOut(duration: 0.15),
                     value: viewModel.rewindSnapshotCount)
        }
        if viewModel.romajiInputEnabled && !viewModel.romajiPending.isEmpty {
          VStack {
            Spacer()
            RomajiOverlayView(pending: viewModel.romajiPending)
              .padding(.bottom, 16)
          }
          .allowsHitTesting(false)
          .transition(.opacity)
        }
      }
      .frame(
        minWidth: viewModel.isFullScreen ? nil : CGFloat(640 * viewModel.windowScale),
        maxWidth: viewModel.isFullScreen ? .infinity : CGFloat(640 * viewModel.windowScale),
        minHeight: viewModel.isFullScreen ? nil : CGFloat(400 * viewModel.windowScale),
        maxHeight: viewModel.isFullScreen ? .infinity : CGFloat(400 * viewModel.windowScale)
      )
      .background(Color.black)
      .onDrop(of: [.fileURL], isTargeted: nil) { providers in
        handleDiskDrop(providers: providers)
      }

      if !viewModel.isFullScreen {
        statusBar
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .frame(width: CGFloat(640 * viewModel.windowScale))
          .background(.bar)
      }
    }
    .overlay(alignment: .bottom) {
      if viewModel.isFullScreen && viewModel.showFullScreenOverlay
        && !viewModel.suppressesFullScreenOverlay {
        statusBar
          .frame(maxWidth: 1280)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
          .padding(.bottom, 20)
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.3), value: viewModel.showFullScreenOverlay)
    .onAppear {
      viewModel.loadROMs()
      // Before `start()`, so the machine never runs a frame of a cold boot
      // first; the toast waits until after it so `start()` cannot replace it.
      let resumeToast = viewModel.restoreResumeStateIfNeeded()
      viewModel.renderScreen()
      viewModel.start()
      if let resumeToast { viewModel.showToast(resumeToast) }
      // Only now may Siri and Shortcuts act on the machine: an intent that
      // arrives earlier would save or mount over a machine with no ROMs.
      AppIntentsHost.viewModel = viewModel
      Bubilator88Shortcuts.updateAppShortcutParameters()
      // A `.b88script` double-clicked to launch the app is held until
      // here, so it plays only after ROMs + run loop are live.
      viewModel.consumePendingScript()
      // And a `.cue` / `.ccd` opened the same way.
      viewModel.consumePendingCD()
      // QUASI88-compatible command-line arguments, e.g.
      // `Bubilator88 -v2 game.d88 2`. Evaluated once at launch, and before any
      // `bubilator88://` URL — so if both are given, the URL wins.
      viewModel.requestLaunchFromCommandLine()
      // Same deferral for a `bubilator88://boot` URL that arrived
      // before the run loop was ready (cold launch).
      viewModel.consumePendingLaunch()
    }
    // `NotificationCenter.notifications` rather than `.onReceive`: these were
    // the view layer's only dependency on Combine.
    .task {
      for await _ in NotificationCenter.default.notifications(
        named: NSWindow.willEnterFullScreenNotification) {
        viewModel.isFullScreen = true
      }
    }
    .task {
      for await _ in NotificationCenter.default.notifications(
        named: NSWindow.willExitFullScreenNotification) {
        viewModel.showFullScreenOverlay = false
      }
    }
    .task {
      for await _ in NotificationCenter.default.notifications(
        named: NSWindow.didExitFullScreenNotification) {
        viewModel.isFullScreen = false
      }
    }
    .fileImporter(
      isPresented: $viewModel.showingDiskPicker,
      allowedContentTypes: diskFileTypes,
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result, let url = urls.first {
        viewModel.mountDisk(url: url, drive: viewModel.diskPickerDrive)
      }
    }
    // SwiftUI silently drops all but the last .fileImporter attached
    // to the same view. The tape picker therefore lives on an
    // invisible sibling view via .background.
    .background(
      Color.clear.fileImporter(
        isPresented: $viewModel.showingTapePicker,
        allowedContentTypes: tapeFileTypes,
        allowsMultipleSelection: false
      ) { result in
        if case .success(let urls) = result, let url = urls.first {
          viewModel.mountTape(url: url)
        }
      }
    )
    .background(
      Color.clear.fileImporter(
        isPresented: $viewModel.showingCDPicker,
        allowedContentTypes: cdFileTypes,
        allowsMultipleSelection: false
      ) { result in
        if case .success(let urls) = result, let url = urls.first {
          viewModel.mountCD(url: url)
        }
      }
    )
    .background(
      Color.clear.fileImporter(
        isPresented: $viewModel.showingMemoryImagePicker,
        allowedContentTypes: memoryImageFileTypes,
        allowsMultipleSelection: false
      ) { result in
        if case .success(let urls) = result, let url = urls.first {
          viewModel.loadMemoryImage(url: url)
        }
      }
    )
    // Binding the pickerContext sum type directly keeps which picker is showing
    // and what it contains permanently consistent. `.sheet(item:)` rebuilds the
    // sheet whenever the item's id changes.
    .sheet(item: $viewModel.pickerContext) { context in
      switch context {
      case .multiImageD88(let disks, _, _, _, _):
        DiskImagePickerView(
          images: disks,
          onSelect: { viewModel.mountSelectedImage(index: $0) },
          onCancel: { viewModel.pickerContext = nil }
        )
      case .archiveEntries(let entries, _, _, _):
        ArchiveFilePickerView(
          entries: entries,
          onSelect: { viewModel.mountSelectedArchiveEntry(index: $0) },
          onCancel: { viewModel.pickerContext = nil }
        )
      }
    }
    .sheet(isPresented: $viewModel.showingSaveStateSheet) {
      SaveStateSheetView(viewModel: viewModel)
    }
    // Any dismissal goes through `cancelAIModelDownload()`, which also
    // resumes emulation if the download paused it.
    .sheet(item: Binding(
      get: { viewModel.aiModelDownload },
      set: { if $0 == nil { viewModel.cancelAIModelDownload() } }
    )) { _ in
      AIModelDownloadSheet(viewModel: viewModel)
    }
    .alert(
      viewModel.alertTitle,
      isPresented: $viewModel.alertIsPresented
    ) {
      Button("OK", role: .cancel) { }
    } message: {
      Text(viewModel.alertMessage)
    }
    .overlay(alignment: .bottom) {
      if let message = viewModel.currentToast {
        ToastView(message: message)
          .padding(.bottom, viewModel.isFullScreen ? 60 : 40)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.25), value: viewModel.currentToast != nil)
    .background(TouchBarInstaller(viewModel: viewModel))
  }

  private func handleDiskDrop(providers: [NSItemProvider]) -> Bool {
    guard viewModel.allows(.media),
          providers.count == 1, let provider = providers.first else { return false }
    let acceptedExts: Set<String> = [
      "d88", "d77", "2d", "2hd",
      "m3u", "m3u8", "n80", "cue", "ccd", "cmt", "t88",
      "zip", "lzh", "lha", "cab", "rar", "7z"
    ]
    _ = provider.loadObject(ofClass: URL.self) { url, _ in
      guard let url else { return }
      if url.pathExtension.lowercased() == "pat" {
        Task { @MainActor in viewModel.importCheatFile(url: url) }
        return
      }
      guard acceptedExts.contains(url.pathExtension.lowercased()) else { return }
      if url.pathExtension.lowercased() == "n80" {
        Task { @MainActor in viewModel.loadMemoryImage(url: url) }
        return
      }
      if ["cue", "ccd"].contains(url.pathExtension.lowercased()) {
        Task { @MainActor in viewModel.mountCD(url: url) }
        return
      }
      // An archive still goes to the disk drive: it could hold either.
      if ["cmt", "t88"].contains(url.pathExtension.lowercased()) {
        Task { @MainActor in viewModel.mountTape(url: url) }
        return
      }
      Task { @MainActor in
        viewModel.mountDisk(url: url, drive: -1)
      }
    }
    return true
  }

  /// Where the emulator image sits in a container of `size`, matching the
  /// Metal view's fullscreen scaling mode.
  private func screenFit(for size: CGSize) -> ScreenFit {
    ScreenFit(container: size,
              mode: viewModel.isFullScreen ? Settings.shared.fullscreenScaling : .fit)
  }

  /// Tells Siri which disk the game on screen comes from. A separate empty
  /// view so that `.id` can rebuild the activity on every disk change
  /// without rebuilding the Metal view.
  private var screenActivity: some View {
    let path = viewModel.mountedDiskPath(drive: 0)
    return Color.clear
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .userActivity("com.bubio.Bubilator88.playing", isActive: path != nil) { activity in
        activity.title = viewModel.currentGameName
        activity.appEntityIdentifier = path.map {
          EntityIdentifier(for: DiskImageEntity.self, identifier: $0)
        }
      }
      .id(path)
      // The disks Siri can name in "Open … in Bubilator88" follow what is
      // mounted and the recent list, which a mount also updates.
      .onChange(of: viewModel.drive0Info?.id) { Bubilator88Shortcuts.updateAppShortcutParameters() }
      .onChange(of: viewModel.drive1Info?.id) { Bubilator88Shortcuts.updateAppShortcutParameters() }
  }

  @ViewBuilder
  private var screenView: some View {
    ZStack {
      MetalScreenViewWrapper(viewModel: viewModel)
      screenActivity
      if let session = viewModel.dissolveSession {
        GeometryReader { geo in
          // Match Metal view's aspect-fit (and integer scaling in
          // fullscreen) so the overlay aligns with the actual
          // displayed image and doesn't stretch into the letterbox.
          let frame = screenFit(for: geo.size).imageFrame
          let w = frame.width
          let h = frame.height
          let x = frame.minX
          let y = frame.minY

          TimelineView(.animation) { ctx in
            let p = session.progress(at: ctx.date)
            ZStack {
              // Solid black behind the dissolving image so
              // (a) the frozen Metal view doesn't peek through
              // dispersed regions, and (b) when the dissolve
              // completes the screen reads as "fully gone"
              // instead of flashing back to the original.
              Color.black
              Image(nsImage: session.snapshot)
                .resizable()
                .interpolation(.none)
                .layerEffect(
                  ShaderLibrary.thanosDissolve(
                    .float2(Float(w), Float(h)),
                    .float(Float(p))
                  ),
                  maxSampleOffset: CGSize(width: 200, height: 200)
                )
            }
            .frame(width: w, height: h)
            .offset(x: x, y: y)
          }
        }
        .allowsHitTesting(false)
      }
    }
  }

  private var statusBar: some View {
    HStack(spacing: 8) {
      // Boot Mode + CPU Clock (grouped)
      HStack(spacing: 4) {
        Menu {
          ForEach(EmulatorViewModel.BootMode.standardCases, id: \.self) { mode in
            Button(mode.rawValue) { viewModel.bootMode = mode }
          }
        } label: {
          Text(viewModel.bootMode.shortLabel)
            .bold()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

        Menu {
          Button("8 MHz") { viewModel.clock8MHz = true }
          Button("4 MHz") { viewModel.clock8MHz = false }
        } label: {
          Text(viewModel.activeClock8MHz ? "8MHz" : "4MHz")
            .monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }

      // Drive 2 + Drive 1 (real hardware order)
      HStack(spacing: 4) {
        driveLED(access: viewModel.drive1Access)
        driveMenu(drive: 1, name: viewModel.drive1Name, info: viewModel.drive1Info)
        driveLED(access: viewModel.drive0Access)
        driveMenu(drive: 0, name: viewModel.drive0Name, info: viewModel.drive0Info)
      }

      // Cassette tape (shown when enabled in Display settings)
      if Settings.shared.showTapeInStatusBar {
        tapeMenu
      }

      // CD-ROM (shown when enabled in Display settings)
      if Settings.shared.showCDInStatusBar {
        HStack(spacing: 4) {
          driveLED(access: viewModel.cdAccess)
          cdMenu
        }
      }

      Spacer()

      // Mouse capture indicator (shown only while the host cursor is
      // captured for bus-mouse input). Control+Esc releases it.
      if viewModel.mouseCapturing {
        Image(systemName: "computermouse.fill")
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(Color.accentColor)
          .font(.system(size: 18))
          .help(String(localized: "Mouse captured — press Control+Esc to release",
                       comment: "Status bar mouse capture indicator tooltip"))
          .accessibilityLabel(Text(String(localized: "Mouse captured",
                                          comment: "Status bar mouse capture indicator accessibility label")))
      }

      // Script playback indicator (shown only while a timeline script is playing)
      if viewModel.isPlayingScript {
        Button {
          viewModel.cancelScriptPlayback()
        } label: {
          Image(systemName: "play.diamond")
            .symbolRenderingMode(.hierarchical)
            .symbolEffect(.wiggle.byLayer, options: .repeat(.periodic(delay: 1.0)))
            .foregroundStyle(.green)
            .font(.system(size: 20))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Stop script playback",
                     comment: "Status bar script playback button tooltip"))
      }

      // Operation-recording indicator (distinct from the red A/V record
      // dots and the green playback diamond: indigo "compose" glyph).
      if viewModel.isRecordingScript {
        Button {
          viewModel.stopScriptRecordingAndSave()
        } label: {
          Image(systemName: "square.and.pencil.circle.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.indigo)
            .font(.system(size: 20))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Stop recording and save script",
                     comment: "Status bar operation-recording button tooltip"))
      }

      // Recording indicator (shown only while recording)
      if viewModel.audioRecorder.isRecording {
        Button {
          viewModel.stopRecording()
        } label: {
          Image(systemName: "record.circle.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.red)
            .font(.system(size: 20))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Stop audio recording",
                     comment: "Status bar record button tooltip"))
      }

      if viewModel.videoRecorder.isRecording {
        Button {
          viewModel.stopVideoRecording()
        } label: {
          Image(systemName: "video.circle.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.red)
            .font(.system(size: 20))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Stop video recording (speed locked at 1×)",
                     comment: "Status bar video record button tooltip"))
      }

      // Volume slider (right-aligned, before translation icon)
      HStack(spacing: 4) {
        Image(systemName: "speaker.fill")
          .foregroundStyle(.secondary)
        Slider(
          value: $viewModel.volume,
          in: 0...1
        )
        .frame(width: 60)
        Image(systemName: "speaker.wave.3.fill")
          .foregroundStyle(.secondary)
      }
      .help(String(format: String(localized: "Volume: %lld%%",
                                  comment: "Volume slider tooltip"),
                   viewModel.volumePercent))

      Button {
        viewModel.toggleTranslation(!viewModel.translationManager.isEnabled)
      } label: {
        Image(systemName: "translate")
          .font(.system(size: 18))
          .foregroundStyle(viewModel.translationManager.isEnabled ? Color.accentColor : Color.secondary)
      }
      .buttonStyle(.borderless)
      .help("Translation Overlay (⌘T)")

      HStack(spacing: 4) {
        Text(String(format: "%.0f fps", viewModel.fps))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(minWidth: 40, alignment: .trailing)
          .help(fpsTooltip)
        Circle()
          .fill(viewModel.turboMode ? Color.orange :
            viewModel.isRunning ? Color.green : Color.gray)
          .frame(width: 8, height: 8)
      }
    }
    .font(.caption)
    .lineLimit(1)
  }

  /// Tooltip for the status bar fps readout: the VSYNC rate the machine is
  /// actually pacing to, plus the memory wait DIP state.
  private var fpsTooltip: String {
    let monitor = Settings.shared.monitorType == .khz24 ? "24 kHz" : "15 kHz"
    let wait = Settings.shared.memoryWaitDip
      ? String(localized: "Memory wait: On", comment: "Status bar fps tooltip")
      : String(localized: "Memory wait: Off", comment: "Status bar fps tooltip")
    guard viewModel.targetFrameRate > 0 else {
      return String(format: String(localized: "VSYNC rate \u{2014} %@",
                                   comment: "Status bar fps tooltip"), wait)
    }
    return String(format: String(localized: "VSYNC: %.2f Hz (%@ monitor) \u{2014} %@",
                                 comment: "Status bar fps tooltip"),
                  viewModel.targetFrameRate, monitor, wait)
  }

  private func driveMenu(drive: Int, name: String, info: MountedDiskInfo?) -> some View {
    let fileName = drive == 0 ? viewModel.drive0FileName : viewModel.drive1FileName

    return Menu {
      Text("Drive \(drive + 1)").disabled(true)
      Divider()
      Button("Mount...") {
        viewModel.diskPickerDrive = drive
        viewModel.showingDiskPicker = true
      }
      Button("Eject") {
        viewModel.ejectDisk(drive: drive)
      }
      .disabled(name == "Empty")

      let wp = drive == 0 ? viewModel.drive0WriteProtected : viewModel.drive1WriteProtected
      Button(wp ? "Write Protect ✓" : "Write Protect") {
        viewModel.toggleWriteProtect(drive: drive)
      }
      .disabled(name == "Empty")

      if name != "Empty", let fileName {
        Divider()
        Text(fileName).disabled(true)
      }

      if let info {
        let multiGroup = info.imageGroups.count > 1
        ForEach(info.imageGroups, id: \.startIndex) { group in
          if multiGroup {
            Text(group.d88FileName).disabled(true)
          }
          ForEach(0..<group.count, id: \.self) { offset in
            let index = group.startIndex + offset
            Button {
              viewModel.switchDiskImage(drive: drive, index: index)
            } label: {
              let imgName = info.imageNames[index]
              if index == info.currentImageIndex {
                Text(multiGroup ? "  \(imgName) ✓" : "\(imgName) ✓")
              } else {
                Text(multiGroup ? "  \(imgName)" : imgName)
              }
            }
          }
        }
      }

    } label: {
      HStack(spacing: 3) {
        Image("FloppyDisk")
          .renderingMode(.template)
          .resizable()
          .frame(width: 12, height: 12)
          .foregroundStyle(name == "Empty" ? .tertiary : .secondary)
        Text(name)
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(name == "Empty" ? .tertiary : .secondary)
      }
    }
    .menuStyle(.borderlessButton)
    .help("Drive \(drive + 1)")
  }

  @ViewBuilder
  private var cdMenu: some View {
    Menu {
      Text(viewModel.cdName).disabled(true)

      Divider()

      Button {
        viewModel.showingCDPicker = true
      } label: {
        Label("Open...", systemImage: "doc")
      }

      Button {
        viewModel.ejectCD()
      } label: {
        Label("Eject", systemImage: "eject")
      }
      .disabled(!viewModel.isCDMounted)
    } label: {
      HStack(spacing: 3) {
        Image(systemName: "opticaldisc")
          .resizable()
          .frame(width: 12, height: 12)
          .foregroundStyle(viewModel.isCDMounted ? .secondary : .tertiary)
        Text(viewModel.cdName)
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(viewModel.isCDMounted ? .secondary : .tertiary)
      }
    }
    .menuStyle(.borderlessButton)
    .help("CD-ROM")
  }

  /// Tooltip detail: the tape name, with its position once one is mounted.
  /// Kept a single string so the tooltip stays the one `Tape: %@` catalog key.
  private var tapeTooltipDetail: String {
    viewModel.isTapeMounted
      ? "\(viewModel.tapeName) : \(viewModel.tapePositionLabel)" : viewModel.tapeName
  }

  @ViewBuilder
  private var tapeMenu: some View {
    let loaded = viewModel.isTapeMounted
    Menu {
      Text(viewModel.tapeName).disabled(true)

      Divider()

      Button {
        viewModel.showingTapePicker = true
      } label: {
        Label("Open...", systemImage: "doc")
      }

      Toggle("Auto Boot", isOn: viewModel.tapeAutoBootBinding)

      Button {
        viewModel.rewindTape()
      } label: {
        Label("Rewind", systemImage: "backward.end")
      }
      .disabled(!loaded)

      Button {
        viewModel.ejectTape()
      } label: {
        Label("Eject", systemImage: "eject")
      }
      .disabled(!loaded)
    } label: {
      HStack(spacing: 3) {
        Image("Cassete")
          .renderingMode(.template)
          .resizable()
          .frame(width: 12, height: 12)
        if loaded {
          // Lowest priority: the tooltip carries the same figure, so this is
          // the first thing to give way when the bar runs short of room.
          Text(viewModel.tapePositionLabel)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .layoutPriority(-1)
        }
      }
    }
    .menuStyle(.borderlessButton)
    .help("Tape: \(tapeTooltipDetail)")
  }

  private func driveLED(access: Bool) -> some View {
    Circle()
      .fill(access ? Color.red : Color.gray)
      .frame(width: 8, height: 8)
      .animation(access ? nil : .easeOut(duration: 0.2), value: access)
  }

}
