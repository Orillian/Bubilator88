import SwiftUI
import AppKit
import Synchronization
import UniformTypeIdentifiers
@_spi(Debug) import Bubilator88Core
import Logging

// `nonisolated` so the nonisolated snapshot writers can log; `Logger` is Sendable.
nonisolated private let renderLog = Logger(label: "App.Rendering")

// MARK: - Rendering

extension EmulatorViewModel {

  // MARK: - Frame Rendering

  /// `markTextPixels` tags text-layer pixels so the display shader can exempt
  /// them from scanline dimming. Only the on-screen path passes it; snapshot
  /// and export callers leave it off so their pixels stay untouched.
  nonisolated func renderCurrentFrame(
    into pixelBuffer: inout [UInt8],
    blinkCursor: Bool,
    debugTextLayerEnabled: Bool = true,
    markTextPixels: Bool = false
  ) {
    pc88.render(into: &pixelBuffer, blinkCursor: blinkCursor,
                textLayerEnabled: debugTextLayerEnabled,
                markTextPixels: markTextPixels)
  }

  /// One tick of the emulation loop: run `frameCount` machine frames under
  /// `emuQueue`, unless the loop was parked in the meantime.
  ///
  /// The `shouldRun` re-check has to happen *inside* the critical section.
  /// `stop()` clears the flag and then joins by taking the queue; without the
  /// re-check, a tick that had already decided to run could queue up behind
  /// that barrier and execute after `stop()` returned.
  ///
  /// **Isolation:** this is the entry point onto the emulation thread, so it
  /// and everything it reaches are `nonisolated` — no main-actor state may be
  /// touched from here without hopping.
  nonisolated func runEmulationStep(frameCount: Int) {
    emuQueue.sync {
      guard emulationLoop.shouldRun else { return }
      // At x1 the frame runs in slices, one per tick, so audio reaches the
      // ring in ~4.5ms pieces spread over the frame instead of one ~18ms
      // burst. The fill level has to cover everything that drains before the
      // next write, so a smaller write is what lets a 20ms buffer hold. Fast
      // forward and rewind keep whole frames: latency doesn't matter there.
      let sliced = frameCount == 1 && !rewindActive
      if sliced {
        runFrameSliceForMetal()
      } else {
        runFrameForMetal(frameCount: frameCount)
      }
      // Re-pace from the machine itself rather than a fixed 1/60. The frame
      // rate is a function of the monitor and the CRTC parameters, so it
      // changes when software reprograms the CRTC (a 20-row screen on a 24kHz
      // monitor is 56.4Hz, a 25-row one 55.4Hz) — reading it here keeps the
      // pacer correct without the host having to be told.
      fddSound.updateTapeMotor(running: pc88.isTapeMotorRunning)
      let rate = pc88.frameRate
      if rate > 0 {
        let ticksPerFrame = sliced ? Double(Self.audioSlicesPerFrame) : 1
        emulationLoop.setFrameInterval(1.0 / (rate * ticksPerFrame))
        if abs(rate - publishedFrameRate) > 0.01 {
          publishedFrameRate = rate
          Task { @MainActor [weak self] in self?.targetFrameRate = rate }
        }
      }
    }
  }

  /// Run emulation frame(s) and render the result.
  ///
  /// Called on the emulation thread from `runEmulationStep`, which already
  /// holds `emuQueue`: taking it again (`emuQueue.sync`) from anything
  /// reachable here deadlocks.
  nonisolated func runFrameForMetal(frameCount: Int = 1) {
    // Take host input at the frame boundary, before any machine time passes.
    // This is where key presses used to land anyway — the main thread could
    // only run between draws — so the timing is unchanged.
    applyPendingInput()
    if rewindActive {
      // Snapshots sit on frame boundaries; resume forward play at slice 0.
      frameSliceIndex = 0
      // Reverse playback at 1/Nth the raw step rate so the buffer
      // doesn't drain in a single wall-clock second.
      if rewindStepCounter <= 0 {
        rewindStepCounter = Self.rewindStepDivider - 1
        stepRewindBack()
        renderCurrentFrame(into: &pixelBuffer, blinkCursor: false,
                           debugTextLayerEnabled: loopSettings.debugTextLayerEnabled,
                           markTextPixels: loopSettings.markTextPixels)
        publishFrame()
      } else {
        rewindStepCounter -= 1
      }
      return
    }
    for _ in 0..<frameCount {
      runHostFrame()
    }

    // Drain audio immediately after emulation, before the potentially
    // expensive pixel rendering step, to minimize ring buffer underruns.
    audio.drainSamples()
    finishFrame()
  }

  /// Slices per frame on the x1 path (`runFrameSliceForMetal`).
  nonisolated static let audioSlicesPerFrame = 4

  /// Run the next slice of the current frame, and render once it ends.
  ///
  /// Same emuQueue contract as `runFrameForMetal`. The per-frame host work
  /// (input, paste, script) happens before slice 0, and the frame-end work
  /// after the slice that ends the frame, so both still sit on the frame
  /// boundary.
  nonisolated func runFrameSliceForMetal() {
    if frameSliceIndex == 0 {
      applyPendingInput()
      beginHostFrame()
    }
    let ended = pc88.runFrameSlice(frameSliceIndex, of: Self.audioSlicesPerFrame)
    audio.drainSamples()
    guard ended else {
      frameSliceIndex += 1
      return
    }
    frameSliceIndex = 0
    endHostFrame()
    finishFrame()
  }

  /// Run one whole machine frame with the host's per-frame work around it.
  /// Under `emuQueue`, like `runFrameForMetal`.
  nonisolated func runHostFrame() {
    beginHostFrame()
    // Finishes a frame the sliced path left part-way (switching to fast
    // forward mid-frame, or an AI agent running frames after a pause):
    // runFrame() stops at the same boundary.
    pc88.runFrame()
    frameSliceIndex = 0
    endHostFrame()
  }

  /// The host work that runs before each machine frame: paste, auto-boot,
  /// script playback and cheats.
  nonisolated func beginHostFrame() {
    tickPasteQueue()
    tickTapeAutoBoot()
    tickMemoryImageBoot()
    tickClickZonePlayer()
    tickScriptPlayer()
    applyCheats()
  }

  /// The host work that runs after each machine frame.
  nonisolated func endHostFrame() {
    // Advance the recording clock in lockstep with machine frames.
    if let r = scriptRecorder { r.frameIndex += 1 }
  }

  /// The frame-end half of a loop tick: debugger check, render, publish,
  /// rewind snapshot, recorders and the throttled UI updates.
  nonisolated func finishFrame() {
    // Breakpoint check: when the debugger halted the machine
    // mid-frame, tear the run loop down the same way the user
    // Pause button does. This ensures the cursor blink (which
    // uses wall-clock time, not T-states) also freezes.
    if let dbg = pc88.debugger, dbg.isPaused {
      Task { @MainActor [weak self] in
        self?.pause()
      }
    }

    // Skip the wall-clock cursor blink when the debugger has
    // pinned execution. Otherwise the 60Hz Metal loop would keep
    // toggling the cursor even as T-states stop advancing.
    let blink = !(pc88.debugger?.isPaused ?? false)
    renderCurrentFrame(into: &pixelBuffer, blinkCursor: blink,
                       debugTextLayerEnabled: loopSettings.debugTextLayerEnabled,
                       markTextPixels: loopSettings.markTextPixels)
    publishFrame()

    // Snapshot recording happens after render so the thumbnail
    // captured from `pixelBuffer` matches the state we just saved.
    recordRewindSnapshotIfNeeded()

    // Video recorder frame tap. Emulation speed is locked to x1 while recording,
    // so frameCount is always 1 here — one wall-clock frame = one file frame.
    if videoRecorder.isRecordingFlag {
      videoRecorder.appendFrame(pixelBuffer, width: 640, height: 400)
    }

    #if DEBUG
    dumpTextDMASnapshotIfRequested()

    #endif

    // SSG noise → haptic feedback detection
    let soundState = pc88.soundState
    gameController.detectSSGNoiseHaptic(sound: soundState,
                                        hapticEnabled: loopSettings.hapticEnabled)

    #if DEBUG
    // SSG noise state logging (for haptic feedback research)
    do {
      let snd = soundState
      let mixer = snd.ssgMixer
      let noiseA = (mixer & 0x08) == 0
      let noiseB = (mixer & 0x10) == 0
      let noiseC = (mixer & 0x20) == 0
      if noiseA || noiseB || noiseC {
        let volA = noiseA ? (snd.ssgVolume[0] & 0x1F) : 0
        let volB = noiseB ? (snd.ssgVolume[1] & 0x1F) : 0
        let volC = noiseC ? (snd.ssgVolume[2] & 0x1F) : 0
        let maxVol = max(volA, max(volB, volC))
        let envMode = (snd.ssgVolume[0] & 0x10) != 0 || (snd.ssgVolume[1] & 0x10) != 0 || (snd.ssgVolume[2] & 0x10) != 0
        renderLog.debug("[SSG] noise: A=\(noiseA ? "ON" : "  ") B=\(noiseB ? "ON" : "  ") C=\(noiseC ? "ON" : "  ") | period=\(snd.ssgNoisePeriod) | vol=\(volA)/\(volB)/\(volC) max=\(maxVol) | envShape=\(String(format:"%02X",snd.ssgEnvelopeShape)) envPeriod=\(snd.ssgEnvelopePeriod) envMode=\(envMode)")
      }
    }
    #endif

    // Update disk access indicators (throttled to ~4Hz to reduce SwiftUI overhead)
    uiUpdateCounter += 1
    if uiUpdateCounter >= 15 {
      uiUpdateCounter = 0
      let diskActivity = pc88.takeDiskActivity()
      let d0 = diskActivity[0]
      let d1 = diskActivity[1]
      let cd = pc88.takeCDActivity()
      let tapeProgressSample = pc88.tapeProgress
      // Sampled here, on the thread that owns the deck, for the same reason
      // progress is: the UI must never read `machine.cassette` itself. A
      // rewind can swap the mounted tape out from under the UI, and this is
      // what notices.
      let tapeMountedSample = pc88.isTapeLoaded

      // Capture OCR snapshot if translation enabled (piggyback on 4Hz UI
      // update). `TranslationManager` is main-actor state, so the *decision*
      // is made on the main thread one tick earlier and left here as an
      // atomic request; only the pixel copy happens on the emulation thread.
      let ocrPixelBuffer: [UInt8]? =
        ocrSampleRequested.exchange(false, ordering: .relaxed)
          ? Array(pixelBuffer) : nil

      // `DispatchQueue.main.async`, not `Task { @MainActor }`: this fires from
      // the emulation thread several times a second and the hops must land in
      // the order they were made. Unstructured `Task`s carry no such ordering.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.drive0Access = d0
        self.drive1Access = d1
        if self.cdAccess != cd { self.cdAccess = cd }
        // Written only on change: an Observable property notifies on every
        // set, and a stopped tape would otherwise invalidate views at 4Hz.
        if self.tapeProgress != tapeProgressSample { self.tapeProgress = tapeProgressSample }
        if self.isTapeMounted != tapeMountedSample { self.isTapeMounted = tapeMountedSample }

        // Refresh the loop's snapshot of main-actor UI settings. The display
        // ones also have immediate hooks; this covers the rest (haptics) and
        // acts as a backstop.
        self.syncLoopSettings()

        // Decide whether the next 4Hz tick should sample the screen for OCR.
        if self.translationManager.isSessionActive,
           self.translationManager.shouldRunOCR() {
          self.ocrSampleRequested.store(true, ordering: .relaxed)
        }

        // Trigger OCR translation
        if let ocrPixelBuffer {
          Task {
            await self.translationManager.processOCR(
              pixelBuffer: ocrPixelBuffer,
              width: 640,
              height: 400
            )
          }
        }
      }
    }
  }

  /// Hand the just-rendered contents of `pixelBuffer` to the renderer,
  /// together with the display metadata needed to interpret them.
  ///
  /// `is400LineMode` travels with the frame because the Metal view can no
  /// longer read it off the live bus: that is emulation-thread state, and it
  /// could have changed since this frame was drawn.
  /// - Parameter counted: false for a frame rendered on the main thread while
  ///   the loop is parked, so it does not inflate the FPS readout.
  nonisolated func publishFrame(counted: Bool = true) {
    framePublisher.publish(pixels: pixelBuffer,
                           is400LineMode: pc88.is400LineMode,
                           counted: counted)
  }

  // MARK: - Screen Rendering

  func renderScreen() {
    renderCurrentFrame(into: &pixelBuffer, blinkCursor: false, debugTextLayerEnabled: debugTextLayerEnabled)
    publishFrame(counted: false)

    #if DEBUG
    dumpTextDMASnapshotIfRequested()
    #endif
  }

  // MARK: - Screenshot

  private nonisolated static func imageData(from image: CGImage, format: String) -> Data? {
    let bitmap = NSBitmapImageRep(cgImage: image)
    switch format {
    case "jpeg":
      return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    case "heic":
      let data = NSMutableData()
      guard let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
      CGImageDestinationAddImage(dest, image, nil)
      guard CGImageDestinationFinalize(dest) else { return nil }
      return data as Data
    default:
      return bitmap.representation(using: .png, properties: [:])
    }
  }

  /// Save a screenshot, either to the preset directory (auto-save mode)
  /// or via NSSavePanel (ask-every-time mode). Controlled by
  /// `Settings.screenshotAutoSave`.
  func saveScreenshot() {
    let format = Settings.shared.screenshotFormat
    let ext = format == "jpeg" ? "jpg" : format

    let formatter = DateFormatter.stable(pattern: "yyyyMMdd-HHmmss")
    let defaultName = "Bubilator88-\(formatter.string(from: .now)).\(ext)"

    let url: URL
    if Settings.shared.screenshotAutoSave {
      let dir = Settings.shared.screenshotDirectory
        ?? NSHomeDirectory() + "/Pictures"
      let dirURL = URL(filePath: dir, directoryHint: .isDirectory)
      try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
      url = dirURL.appending(component: defaultName)
    } else {
      let panel = NSSavePanel()
      panel.title = String(localized: "Save Screenshot", comment: "")
      panel.nameFieldStringValue = defaultName
      switch format {
      case "jpeg": panel.allowedContentTypes = [.jpeg]
      case "heic": panel.allowedContentTypes = [.heic]
      default:     panel.allowedContentTypes = [.png]
      }
      panel.canCreateDirectories = true
      guard panel.runModal() == .OK, let chosen = panel.url else { return }
      url = chosen
    }

    guard let data = renderScreenshotData(format: format) else {
      showAlert(
        title: String(localized: "Screenshot Error", comment: ""),
        message: String(localized: "Screenshot failed", comment: "")
      )
      return
    }

    do {
      try data.write(to: url, options: .atomic)
      if Settings.shared.screenshotAutoSave {
        showToast(String(localized: "Screenshot saved", comment: ""))
      }
    } catch {
      showAlert(
        title: String(localized: "Screenshot Error", comment: ""),
        message: error.localizedDescription
      )
    }
  }

  /// Copy the current screen to the system clipboard as a PNG image.
  func copyScreenshotToClipboard() {
    guard let data = renderScreenshotData(format: "png") else {
      showAlert(
        title: String(localized: "Screenshot Error", comment: ""),
        message: String(localized: "Screenshot failed", comment: "")
      )
      return
    }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setData(data, forType: .png)
    showToast(String(localized: "Screenshot copied to clipboard", comment: ""))
  }

  private func renderScreenshotData(format: String) -> Data? {
    // Prefer the Metal filter pipeline — matches what's on screen
    // (CRT phosphor, Enhanced/xBRZ, AI Upscaler, scanlines, etc.).
    if let cgImage = metalView?.captureFilteredImage() {
      return Self.imageData(from: cgImage, format: format)
    }
    // Fallback: raw unfiltered 640×400 (Metal unavailable)
    var buffer = Array(repeating: UInt8(0), count: PC88.frameBufferSize)
    // Reached on the main thread from a menu command, so the render has to take
    // `emuQueue` — it reads GVRAM and text VRAM while the emulation thread is
    // writing them (`RELEASE_1_5_0_PLAN.md` §3.3(e), §9.6).
    let debugTextLayer = debugTextLayerEnabled
    emuQueue.sync {
      renderCurrentFrame(into: &buffer, blinkCursor: false,
                         debugTextLayerEnabled: debugTextLayer)
    }
    return createCGImage(from: buffer).flatMap { Self.imageData(from: $0, format: format) }
  }

  nonisolated func createCGImage(from pixelBuffer: [UInt8]) -> CGImage? {
    let width = PC88.frameWidth
    let height = PC88.frameHeight
    let bytesPerRow = width * 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    return pixelBuffer.withUnsafeBytes { rawBuffer -> CGImage? in
      guard let data = CFDataCreate(nil, rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), rawBuffer.count),
            let provider = CGDataProvider(data: data) else { return nil }
      return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    }
  }

  // MARK: - Memory Dump

  /// Show a save panel and write a full memory dump (main RAM, GVRAM planes,
  /// tvram, sub-CPU RAM, ext RAM if installed) into the selected directory.
  /// The user types a directory name in the save panel; Bubilator88 creates
  /// it and fills it with the cross-emulator dump layout defined in
  /// docs/MEMORY_DUMP_FORMAT.md.
  func dumpMemoryViaSavePanel() {
    let panel = NSSavePanel()
    panel.title = String(localized: "Dump Memory…", comment: "Develop menu memory dump title")
    let stamp = ISO8601DateFormatter().string(from: .now)
      .replacingOccurrences(of: ":", with: "-")
    panel.nameFieldStringValue = "Bubilator88-memdump-\(stamp)"
    panel.canCreateDirectories = true
    let response = panel.runModal()
    guard response == .OK, let url = panel.url else { return }
    do {
      let files = try MemoryDump.write(
        pc88: pc88,
        to: url,
        metadata: [
          "boot_mode": bootMode.rawValue,
          "disk0": drive0FileName ?? "-",
          "disk1": drive1FileName ?? "-",
        ]
      )
      // (dump success confirmation not shown)
      _ = files
    } catch {
      showAlert(
        title: String(localized: "Dump Error", comment: ""),
        message: error.localizedDescription
      )
    }
  }

  #if DEBUG
  // MARK: - Debug Text DMA Snapshot

  func dumpTextDMASnapshotToDefaultPath() {
    let payload = """
    trigger: menu
    \(pc88.textDMADebugSnapshot().debugReport())
    """

    do {
      try payload.write(toFile: textDMASnapshotDumpPath, atomically: true, encoding: .utf8)
      showToast("Text DMA snapshot: \(textDMASnapshotDumpPath)")
    } catch {
      showAlert(
        title: String(localized: "Snapshot Error", comment: ""),
        message: error.localizedDescription
      )
    }
  }

  nonisolated func dumpTextDMASnapshotIfRequested() {
    var triggerReason: String?
    if textDMASnapshotAutoDumpRequested, !textDMASnapshotAutoDumped {
      textDMASnapshotAutoDumped = true
      triggerReason = "startup"
    } else if FileManager.default.fileExists(atPath: textDMASnapshotTriggerPath) {
      triggerReason = "trigger"
      try? FileManager.default.removeItem(atPath: textDMASnapshotTriggerPath)
    }
    guard let triggerReason else { return }

    let report = pc88.textDMADebugSnapshot().debugReport()
    let payload = """
    trigger: \(triggerReason)
    \(report)
    """
    do {
      try payload.write(toFile: textDMASnapshotDumpPath, atomically: true, encoding: .utf8)
      renderLog.debug("TEXT DMA: snapshot written to \(textDMASnapshotDumpPath) [\(triggerReason)]")
    } catch {
      renderLog.error("TEXT DMA: failed to write snapshot to \(textDMASnapshotDumpPath): \(error)")
    }
  }
  #endif
}
