import SwiftUI
import UniformTypeIdentifiers
import Bubilator88Core

// MARK: - ROM Loading & Disk Operations

extension EmulatorViewModel {

  // MARK: - ROM Loading

  /// Load ROMs from Application Support directory.
  func loadROMs() {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appending(component: "Bubilator88")

    // Create directory if needed
    try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

    let roms = BIOSFiles.load(from: appSupport)
    for (rom, data) in roms {
      pc88.loadROM(rom, data: data)
    }
    // Develop menu overrides, loaded over whatever the user supplied.
    if forceBuiltInFont {
      pc88.loadROM(.font, data: builtInFont)
    }
    if forceBuiltInKanji {
      for rom in [PC88.ROM.kanji1, .kanji2] {
        if let data = BIOSFiles.loadSubstitute(for: rom) {
          pc88.loadROM(rom, data: data)
        }
      }
    }
    if let dictionary = BIOSFiles.loadDictionary(from: appSupport) {
      pc88.loadDictionaryROM(dictionary)
    }
    if roms.contains(where: { $0.0 == .n88Basic }) {
      romLoaded = true
    } else {
      showAlert(
        title: String(localized: "ROM Not Found", comment: ""),
        message: "N88.ROM not found in \(appSupport.path)"
      )
    }

    // Install extended RAM (capacity from Settings; default 128KB).
    pc88.installExtRAM(cards: Settings.shared.extramCards, banksPerCard: 4)

    // YM2608 rhythm WAV samples (fmgen format: signed 16-bit PCM). A file in
    // Application Support wins; otherwise the bundled stand-in is used so the
    // rhythm part is never silent.
    let rhythmNames = ["BD", "SD", "TOP", "HH", "TOM", "RIM"]
    for (index, name) in rhythmNames.enumerated() {
      let userFile = forceBuiltInRhythm ? nil : appSupport.appending(component: "2608_\(name).WAV")
      let bundled = Bundle.main.url(forResource: "Rhythm_\(name)", withExtension: "wav")
      for url in [userFile, bundled].compactMap({ $0 }) {
        if let wavData = try? Data(contentsOf: url),
           let (samples, sampleRate) = parseWAV(wavData) {
          pc88.loadRhythmSample(index: index, data: samples, sampleRate: sampleRate)
          break
        }
      }
    }
  }

  /// Parse a WAV file and extract signed 16-bit PCM samples.
  private func parseWAV(_ data: Data) -> (samples: [Int16], sampleRate: Int)? {
    guard data.count > 44 else { return nil }
    // Verify RIFF header
    guard data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46 else { return nil }
    // Verify WAVE format
    guard data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45 else { return nil }

    // Find "fmt " and "data" chunks
    var sampleRate = 44100
    var bitsPerSample = 16
    var numChannels = 1
    var dataOffset = 0
    var dataSize = 0

    var offset = 12
    while offset + 8 <= data.count {
      let chunkID = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
      let chunkSize = Int(data[offset+4]) | Int(data[offset+5]) << 8 |
        Int(data[offset+6]) << 16 | Int(data[offset+7]) << 24
      if chunkID == "fmt " {
        numChannels = Int(data[offset+10]) | Int(data[offset+11]) << 8
        sampleRate = Int(data[offset+12]) | Int(data[offset+13]) << 8 |
          Int(data[offset+14]) << 16 | Int(data[offset+15]) << 24
        bitsPerSample = Int(data[offset+22]) | Int(data[offset+23]) << 8
      } else if chunkID == "data" {
        dataOffset = offset + 8
        dataSize = chunkSize
        break
      }
      offset += 8 + chunkSize
      if chunkSize & 1 != 0 { offset += 1 }  // Word-align
    }

    guard dataOffset > 0, bitsPerSample == 16 else { return nil }
    let sampleCount = min(dataSize, data.count - dataOffset) / (2 * numChannels)
    var samples = [Int16](repeating: 0, count: sampleCount)
    for i in 0..<sampleCount {
      let byteOffset = dataOffset + i * 2 * numChannels
      samples[i] = Int16(bitPattern: UInt16(data[byteOffset]) | UInt16(data[byteOffset+1]) << 8)
    }
    return (samples, sampleRate)
  }

  // MARK: - Drive state types

  /// Which drive to mount into. A typed form of the legacy `Int` taken by
  /// `mountDisk(url:drive:)`, which removes the `-1` magic value.
  enum MountTarget {
    case drive(Int)
    case both  // Mount 0&1 mode (formerly drive == -1)

    static func from(legacy drive: Int) -> MountTarget {
      drive == -1 ? .both : .drive(drive)
    }
  }

  /// A snapshot of one drive's display and state. A transient value object for
  /// rewriting several properties as one action on mount, switch or eject.
  nonisolated struct DriveState {
    let name: String
    let fileName: String?
    let info: MountedDiskInfo?
    let writeProtected: Bool

    static let empty =
      DriveState(name: "Empty", fileName: nil, info: nil, writeProtected: false)
  }

  /// Updates all of a drive's display properties — name, fileName, info and
  /// writeProtected — in one function. Collapses the scattered
  /// `if drive == 0 { drive0X = ... } else ...` and makes the intended SwiftUI
  /// Observable invalidation explicit.
  func applyDriveState(_ state: DriveState, drive: Int) {
    if drive == 0 {
      drive0Name = state.name
      drive0FileName = state.fileName
      drive0Info = state.info
      drive0WriteProtected = state.writeProtected
    } else {
      drive1Name = state.name
      drive1FileName = state.fileName
      drive1Info = state.info
      drive1WriteProtected = state.writeProtected
    }
    syncActiveCheats()
  }

  // MARK: - Disk Operations

  /// Open a D88 disk image file (or archive containing D88 files) and mount it.
  /// Multi-image D88 files trigger an image selection sheet.
  /// Archives with multiple D88 files trigger an archive file picker.
  /// The legacy `drive == -1` triggers "Mount 0&1" mode, converted internally to
  /// `MountTarget.both`.
  func mountDisk(url: URL, drive: Int) {
    mountDisk(url: url, target: MountTarget.from(legacy: drive))
  }

  /// Type-safe entry point. Its only job is reading the file and dispatching
  /// between archive and direct; the actual mounting is delegated to
  /// `mountArchive` or `mountDirectD88`.
  func mountDisk(url: URL, target: MountTarget) {
    if M3UPlaylist.isPlaylist(url) {
      mountM3U(url: url, target: target)
      return
    }
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url) else {
      presentDiskLoadErrorAlert(fileName: url.lastPathComponent, reason: .unreadable)
      return
    }
    Settings.shared.addRecentFile(url: url, kind: .disk)

    if let entries = ArchiveExtractor.extractDiskImages(data) {
      mountArchive(url: url, data: data, entries: entries, target: target)
    } else {
      mountDirectD88(url: url, data: data, target: target)
    }
  }

  // MARK: - Archive mount path

  private func mountArchive(url: URL, data: Data,
                            entries: [ArchiveEntry], target: MountTarget) {
    guard !entries.isEmpty else {
      presentDiskLoadErrorAlert(fileName: url.lastPathComponent, reason: .emptyArchive)
      return
    }
    // If the cache cannot be created, carry on from memory; write-back then
    // falls through to the ModifiedDisks fallback.
    let cache = DiskCacheManager.shared
    let cacheDir: URL?
    do {
      cacheDir = try cache.ensureCached(archiveURL: url, archiveData: data, entries: entries)
    } catch {
      cacheDir = nil
      showAlert(
        title: String(localized: "Disk Cache Unavailable", comment: ""),
        message: error.localizedDescription
      )
    }
    switch target {
    case .both:
      mountArchiveBoth(url: url, entries: entries, cacheDir: cacheDir, cache: cache)
    case .drive(let drive):
      if entries.count == 1 {
        let entry = entries[0]
        let entryURL = cacheDir.flatMap {
          cache.cachedEntryURL(in: $0, entryName: entry.filename)
        }
        mountDiskData(Array(cache.resolvedData(for: entry, in: cacheDir)),
                      name: entry.filename, drive: drive,
                      sourceURL: entryURL, archiveEntryName: entry.filename,
                      originArchiveURL: url)
      } else {
        // Multiple D88 files in archive → show archive file picker
        pickerContext = .archiveEntries(entries: entries, archiveURL: url,
                                        cacheDir: cacheDir, drive: drive)
        diskPickerDrive = drive
      }
    }
  }

  /// Mount 0&1: flatten all D88 images across archive entries, place
  /// images[0] on drive 0 and images[1] on drive 1.
  private func mountArchiveBoth(url: URL, entries: [ArchiveEntry],
                                cacheDir: URL?, cache: DiskCacheManager) {
    var allDisks: [(disk: D88Disk, name: String, entryName: String)] = []
    var groups: [DiskImageGroup] = []
    for entry in entries {
      let disks = D88Disk.parseAll(data: Array(cache.resolvedData(for: entry, in: cacheDir)))
      let baseName = (entry.filename as NSString).deletingPathExtension
      groups.append(DiskImageGroup(d88FileName: baseName,
                                   startIndex: allDisks.count, count: disks.count))
      for disk in disks {
        allDisks.append((disk, disk.name.isEmpty ? baseName : disk.name, entry.filename))
      }
    }
    let allImages = allDisks.map(\.disk)
    let allNames = allDisks.map(\.name)
    let fileName = url.deletingPathExtension().lastPathComponent

    func mountSlot(_ slot: (disk: D88Disk, name: String, entryName: String),
                   drive: Int, imageIndex: Int) {
      let entryURL = cacheDir.flatMap {
        cache.cachedEntryURL(in: $0, entryName: slot.entryName)
      }
      mountDiskImageDirect(DirectMountRequest(
        disk: slot.disk, name: slot.name, drive: drive,
        allImages: allImages, imageNames: allNames, imageIndex: imageIndex,
        sourceURL: entryURL, archiveEntryName: slot.entryName,
        originArchiveURL: url, fileName: fileName, imageGroups: groups
      ))
    }
    if let first = allDisks.first {
      mountSlot(first, drive: 0, imageIndex: 0)
    }
    if allDisks.count >= 2 {
      mountSlot(allDisks[1], drive: 1, imageIndex: 1)
    } else {
      ejectDisk(drive: 1)
    }
  }

  // MARK: - Direct .d88 mount path

  private func mountDirectD88(url: URL, data: Data, target: MountTarget) {
    let disks = D88Disk.parseAll(data: Array(data))
    guard !disks.isEmpty else {
      presentDiskLoadErrorAlert(
        fileName: url.lastPathComponent,
        reason: classifyDiskLoadFailure(data: Array(data))
      )
      return
    }

    switch target {
    case .both:
      mountDiskImage(disks[0], allImages: disks, imageIndex: 0, url: url, drive: 0)
      if disks.count >= 2 {
        mountDiskImage(disks[1], allImages: disks, imageIndex: 1, url: url, drive: 1)
      } else {
        ejectDisk(drive: 1)
      }
    case .drive(let drive):
      if disks.count == 1 {
        mountDiskImage(disks[0], allImages: disks, imageIndex: 0, url: url, drive: drive)
      } else {
        pickerContext = .multiImageD88(disks: disks, sourceURL: url,
                                       archiveEntryName: nil,
                                       originArchiveURL: nil, drive: drive)
        diskPickerDrive = drive
      }
    }
  }

  // MARK: - M3U playlist mount path

  /// Mount disks listed in an `.m3u` playlist. Each non-empty, non-comment
  /// line is a disk image path — absolute, `~`-relative, or relative to the
  /// playlist's own directory. The first entry goes to drive 0 and the
  /// second to drive 1 (Mount 0&1), matching how a 2-disk game boots.
  ///
  /// Each entry is mounted as its own independent source file (its own
  /// `sourceURL` + local image index), NOT flattened into a shared image
  /// list. This keeps disk write-back correct: `DiskWriteBackIO.writeBank`
  /// writes the current image index into `sourceURL`, so a per-file index
  /// must address a bank that actually exists in that file.
  private func mountM3U(url: URL, target: MountTarget) {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    guard let entryURLs = M3UPlaylist.entryURLs(contentsOf: url) else {
      presentDiskLoadErrorAlert(fileName: url.lastPathComponent, reason: .unreadable)
      return
    }
    guard !entryURLs.isEmpty else {
      presentDiskLoadErrorAlert(fileName: url.lastPathComponent, reason: .emptyArchive)
      return
    }
    Settings.shared.addRecentFile(url: url, kind: .disk)

    // Mount one playlist entry as an independent source file. Multi-image
    // entries mount their first image; the user can switch within that
    // drive via the existing image menu. Returns false on read/parse fail.
    func mountEntry(_ fileURL: URL, drive: Int) -> Bool {
      guard let data = try? Data(contentsOf: fileURL) else { return false }
      let disks = D88Disk.parseAll(data: Array(data))
      guard !disks.isEmpty else { return false }
      mountDiskImage(disks[0], allImages: disks, imageIndex: 0,
                     url: fileURL, drive: drive)
      return true
    }

    switch target {
    case .both:
      guard mountEntry(entryURLs[0], drive: 0) else {
        presentDiskLoadErrorAlert(
          fileName: entryURLs[0].lastPathComponent,
          reason: classifyM3UEntryFailure(entryURLs[0])
        )
        return
      }
      if entryURLs.count >= 2, mountEntry(entryURLs[1], drive: 1) {
        // drive 1 mounted from the second entry
      } else {
        ejectDisk(drive: 1)
      }
    case .drive(let drive):
      if !mountEntry(entryURLs[0], drive: drive) {
        presentDiskLoadErrorAlert(
          fileName: entryURLs[0].lastPathComponent,
          reason: classifyM3UEntryFailure(entryURLs[0])
        )
      }
    }
  }

  /// Classify why an `.m3u` entry could not be mounted (file missing vs. not
  /// a valid disk image) so the alert message is accurate.
  private func classifyM3UEntryFailure(_ fileURL: URL) -> DiskLoadFailureReason {
    guard let data = try? Data(contentsOf: fileURL) else { return .unreadable }
    return classifyDiskLoadFailure(data: Array(data))
  }

  /// Mount a D88 from raw bytes (extracted from archive).
  /// `drive` must be 0 or 1 (not -1; Mount 0&1 is handled by the caller).
  private func mountDiskData(_ data: [UInt8], name: String, drive: Int,
                             sourceURL: URL?, archiveEntryName: String? = nil,
                             originArchiveURL: URL? = nil) {
    let disks = D88Disk.parseAll(data: data)
    guard !disks.isEmpty else {
      presentDiskLoadErrorAlert(
        fileName: name,
        reason: classifyDiskLoadFailure(data: data)
      )
      return
    }
    if disks.count == 1 {
      let disk = disks[0]
      let fileName = (name as NSString).deletingPathExtension
      let imageNames = disks.map { $0.name.isEmpty ? fileName : $0.name }
      let groups = [DiskImageGroup(d88FileName: fileName, startIndex: 0, count: disks.count)]
      mountDiskImageDirect(DirectMountRequest(
        disk: disk, name: imageNames[0], drive: drive,
        allImages: disks, imageNames: imageNames, imageIndex: 0,
        sourceURL: sourceURL, archiveEntryName: archiveEntryName,
        originArchiveURL: originArchiveURL,
        fileName: fileName, imageGroups: groups
      ))
    } else {
      // Multi-image D88 inside archive → show image picker
      pickerContext = .multiImageD88(disks: disks,
                                     sourceURL: sourceURL,
                                     archiveEntryName: archiveEntryName,
                                     originArchiveURL: originArchiveURL,
                                     drive: drive)
      diskPickerDrive = drive
    }
  }

  /// Parameters for `mountDiskImageDirect`. Collecting nine arguments into a
  /// struct rules out omitted and transposed arguments, and keeps the call sites
  /// readable.
  struct DirectMountRequest {
    let disk: D88Disk
    let name: String
    let drive: Int
    let allImages: [D88Disk]
    let imageNames: [String]
    let imageIndex: Int
    let sourceURL: URL?
    let archiveEntryName: String?
    let originArchiveURL: URL?
    let fileName: String
    let imageGroups: [DiskImageGroup]
  }

  /// Mount a parsed D88Disk directly to a specific drive with full metadata.
  private func mountDiskImageDirect(_ req: DirectMountRequest) {
    diskWriteBackScheduler.flushNow(drive: req.drive)
    emuQueue.sync {
      pc88.mountDisk(drive: req.drive, disk: req.disk)
    }
    clearRewindBuffer()
    let info = MountedDiskInfo(sourceURL: req.sourceURL,
                               archiveEntryName: req.archiveEntryName,
                               originArchiveURL: req.originArchiveURL,
                               allImages: req.allImages, imageNames: req.imageNames,
                               currentImageIndex: req.imageIndex,
                               fileName: req.fileName, imageGroups: req.imageGroups)
    applyDriveState(
      DriveState(name: req.name, fileName: req.fileName, info: info,
                 writeProtected: req.disk.writeProtected),
      drive: req.drive
    )
    recordDiskMountIfNeeded(drive: req.drive)
  }

  /// Mount the selected file from an archive.
  func mountSelectedArchiveEntry(index: Int) {
    guard index >= 0, index < pendingArchiveEntries.count else { return }
    let entry = pendingArchiveEntries[index]
    let cache = DiskCacheManager.shared
    let entryURL = pendingArchiveCacheDir.flatMap {
      cache.cachedEntryURL(in: $0, entryName: entry.filename)
    }
    let bytes = Array(cache.resolvedData(for: entry, in: pendingArchiveCacheDir))
    let archiveURL = pendingArchiveURL
    // Close the archive picker. If the D88 inside is multi-image, mountDiskData
    // raises `.multiImageD88` again, swapping in the other picker.
    pickerContext = nil
    mountDiskData(bytes, name: entry.filename, drive: diskPickerDrive,
                  sourceURL: entryURL, archiveEntryName: entry.filename,
                  originArchiveURL: archiveURL)
  }

  /// Mount the selected image from a multi-image D88 file.
  func mountSelectedImage(index: Int) {
    guard case .multiImageD88(let disks, let url, let entryName, let originArchive, _)
      = pickerContext,
      index >= 0, index < disks.count else { return }
    let disk = disks[index]
    pickerContext = nil
    mountDiskImage(disk, allImages: disks, imageIndex: index, url: url,
                   drive: diskPickerDrive, archiveEntryName: entryName,
                   originArchiveURL: originArchive)
  }

  /// Builds the `MountedDiskInfo` for a single `.d88` source.
  ///
  /// Centralizes the image names (falling back to `fileName #i` for an empty
  /// name), the single `DiskImageGroup`, and the index clamping rule, so that
  /// manual mounts (`mountDiskImage`), save-state restore
  /// (`reconstructDiskInfo`) and post-playback rebuilds
  /// (`rebuildDriveInfoFromScript`) all share them.
  nonisolated func makeDirectDiskInfo(allImages: [D88Disk], fileName: String, imageIndex: Int,
                                      sourceURL: URL?, archiveEntryName: String? = nil,
                                      originArchiveURL: URL? = nil) -> MountedDiskInfo {
    let imageNames = allImages.enumerated().map { i, d in
      d.name.isEmpty ? (allImages.count > 1 ? "\(fileName) #\(i)" : fileName) : d.name
    }
    let groups = [DiskImageGroup(d88FileName: fileName, startIndex: 0, count: allImages.count)]
    let index = min(max(0, imageIndex), max(0, allImages.count - 1))
    return MountedDiskInfo(sourceURL: sourceURL, archiveEntryName: archiveEntryName,
                           originArchiveURL: originArchiveURL,
                           allImages: allImages, imageNames: imageNames,
                           currentImageIndex: index, fileName: fileName,
                           imageGroups: groups)
  }

  /// Mount entry point with an explicit imageIndex, used only by URL scheme
  /// launches (`bubilator88://boot`).
  ///
  /// Unlike `mountDisk(url:drive:)` it never presents a picker sheet, because the
  /// caller (`performLaunch`) has already validated `disks` and `imageIndex` in
  /// its validation phase. See docs/develop/URL_SCHEME_LAUNCH_PLAN.md §3.6.
  func mountDiskExplicit(disks: [D88Disk], imageIndex: Int, url: URL, drive: Int) {
    mountDiskImage(disks[imageIndex], allImages: disks, imageIndex: imageIndex, url: url, drive: drive)
    Settings.shared.addRecentFile(url: url, kind: .disk)
  }

  private func mountDiskImage(_ disk: D88Disk, allImages: [D88Disk], imageIndex: Int,
                              url: URL?, drive: Int, archiveEntryName: String? = nil,
                              originArchiveURL: URL? = nil) {
    // For non-archive paths, use the source URL as the display name.
    // For archive-derived paths, prefer the original archive name (cache dir
    // names like "abc123-456" are not user-friendly).
    let fileName: String = {
      if let archiveURL = originArchiveURL {
        return archiveURL.deletingPathExtension().lastPathComponent
      }
      return url?.deletingPathExtension().lastPathComponent ?? "Disk"
    }()
    let info = makeDirectDiskInfo(allImages: allImages, fileName: fileName,
                                  imageIndex: imageIndex, sourceURL: url,
                                  archiveEntryName: archiveEntryName,
                                  originArchiveURL: originArchiveURL)
    let displayName = info.imageNames[info.currentImageIndex]
    diskWriteBackScheduler.flushNow(drive: drive)
    emuQueue.sync {
      pc88.mountDisk(drive: drive, disk: disk)
    }
    clearRewindBuffer()
    applyDriveState(
      DriveState(name: displayName, fileName: fileName, info: info,
                 writeProtected: disk.writeProtected),
      drive: drive
    )
    recordDiskMountIfNeeded(drive: drive)
  }

  /// Switch to a different disk image within the same source file.
  func switchDiskImage(drive: Int, index: Int) {
    guard let info = (drive == 0 ? drive0Info : drive1Info),
          index >= 0, index < info.allImages.count else { return }
    diskWriteBackScheduler.flushNow(drive: drive)
    let disk = info.allImages[index]
    emuQueue.sync {
      pc88.mountDisk(drive: drive, disk: disk)
    }
    clearRewindBuffer()
    var updated = info
    updated.currentImageIndex = index
    let displayName = info.imageNames[index]
    applyDriveState(
      DriveState(name: displayName, fileName: info.fileName, info: updated,
                 writeProtected: disk.writeProtected),
      drive: drive
    )
    // `ScriptRecorder` is otherwise only touched on the emulation thread
    // (key events ride the input queue), so main-thread recording of a disk
    // operation goes through the queue.
    emuQueue.sync { scriptRecorder?.diskSelect(drive: drive, image: index) }
  }

  /// Toggle the write-protect flag on the disk mounted in the specified drive.
  /// No-op when the drive is empty.
  func toggleWriteProtect(drive: Int) {
    setWriteProtect(drive: drive, protected: !(drive == 0 ? drive0WriteProtected : drive1WriteProtected))
  }

  /// Set the write-protect flag on the disk mounted in the specified drive.
  /// No-op when the drive is empty.
  func setWriteProtect(drive: Int, protected newValue: Bool) {
    let name = drive == 0 ? drive0Name : drive1Name
    guard name != "Empty" else { return }
    emuQueue.sync {
      pc88.setWriteProtect(drive: drive, protected: newValue)
    }
    if drive == 0 {
      drive0WriteProtected = newValue
    } else {
      drive1WriteProtected = newValue
    }
  }

  func ejectDisk(drive: Int) {
    diskWriteBackScheduler.flushNow(drive: drive)
    emuQueue.sync {
      pc88.ejectDisk(drive: drive)
    }
    clearRewindBuffer()
    applyDriveState(.empty, drive: drive)
    emuQueue.sync { scriptRecorder?.diskEject(drive: drive) }
    // FDD boot is always the default; no need to revert to ROM boot
    // (eject confirmation not shown)
  }

  /// Mount a disk from a recent file entry (resolves bookmark, mounts as 0&1).
  func mountRecentFile(_ entry: RecentDiskEntry, drive: Int = -1) {
    guard let url = entry.resolveBookmark() else {
      Settings.shared.removeRecentFile(entry, kind: .disk)
      showAlert(
        title: String(localized: "File Error", comment: ""),
        message: String(
          localized:           "File no longer accessible. If this disk had written-back save data, you can recover it via Disk > Export Cached Disks...",
          comment: ""
        )
      )
      return
    }
    mountDisk(url: url, drive: drive)
  }

  // MARK: - Cache Export

  /// Implements the "Export Extracted Cache…" menu item. Opens a folder chooser
  /// and copies, with the orphan filter on or off according to the checkbox in
  /// the accessory view.
  func exportCachedDisks() {
    guard let result = CacheExportPanel.run() else { return }

    do {
      let (exported, skipped) = try DiskCacheManager.shared.exportCachedDisks(
        to: result.destination,
        orphansOnly: result.orphansOnly
      )
      let title: String
      let message: String
      if exported == 0 {
        title = String(localized: "No Disks Exported", comment: "")
        if result.orphansOnly && skipped > 0 {
          message = String(
            localized:             "No orphan disks were found (all cached disks still have their original archive).",
            comment: ""
          )
        } else {
          message = String(localized: "There are no cached disks to export.", comment: "")
        }
      } else {
        title = String(localized: "Export Complete", comment: "")
        let fmt = String(localized: "Exported %d disk(s).", comment: "")
        message = String(format: fmt, exported)
      }
      showAlert(title: title, message: message)
    } catch {
      showAlert(
        title: String(localized: "Export Failed", comment: ""),
        message: error.localizedDescription
      )
    }
  }

  // MARK: - Blank Disk Creation

  /// Show save panel and create a formatted blank D88 disk image.
  func createBlankDisk() {
    let panel = NSSavePanel()
    panel.title = String(localized: "Create Blank Disk", comment: "Save panel title")
    panel.nameFieldStringValue = "Blank.d88"
    // There is no system UTType for D88, so fall back to plain data rather than
    // force-unwrapping. Matches how PIOFlowPane guards its own UTType lookup.
    panel.allowedContentTypes = [UTType(filenameExtension: "d88") ?? .data]

    // Disk type picker + BASIC FAT init checkbox as accessory view
    let typePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
    typePopup.addItems(withTitles: ["2D (320KB)", "2DD (640KB)", "2HD (1.2MB)"])
    typePopup.selectItem(at: 1)  // default: 2DD

    let label = NSTextField(labelWithString: String(localized: "Disk Type:", comment: "Blank disk type label"))
    label.sizeToFit()
    let labelWidth = max(70, label.frame.width)

    let fatCheckbox = NSButton(
      checkboxWithTitle: String(
        localized:         "Initialize as N88-BASIC disk",
        comment: "Blank disk FAT init checkbox"
      ),
      target: nil,
      action: nil
    )
    fatCheckbox.state = .on
    fatCheckbox.sizeToFit()
    let checkboxWidth = max(fatCheckbox.frame.width, CGFloat(labelWidth) + 208)

    let containerWidth = max(checkboxWidth + 8, CGFloat(labelWidth) + 216)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 64))
    label.frame = NSRect(x: 4, y: 34, width: labelWidth, height: 20)
    typePopup.frame = NSRect(x: labelWidth + 8, y: 32, width: 200, height: 26)
    fatCheckbox.frame = NSRect(x: 4, y: 6, width: checkboxWidth, height: 20)
    container.addSubview(label)
    container.addSubview(typePopup)
    container.addSubview(fatCheckbox)
    panel.accessoryView = container

    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      let diskType: D88Disk.DiskType
      switch typePopup.indexOfSelectedItem {
      case 0:  diskType = .twoD
      case 2:  diskType = .twoHD
      default: diskType = .twoDD
      }
      let initFAT = fatCheckbox.state == .on
      let diskName = url.deletingPathExtension().lastPathComponent
      let disk = D88Disk.createFormatted(type: diskType, name: diskName, initBasicFAT: initFAT)
      guard let data = disk.serialize() else {
        self?.showAlert(
          title: String(localized: "Disk Error", comment: ""),
          message: String(localized: "Failed to create blank disk", comment: "")
        )
        return
      }
      do {
        try Data(data).write(to: url)
        // Mount into the first empty drive so creating a blank disk
        // doesn't clobber whatever the user already has loaded.
        // Fall back to drive 0 only when both drives are occupied.
        let targetDrive: Int = {
          if self?.drive0Info == nil { return 0 }
          if self?.drive1Info == nil { return 1 }
          return 0
        }()
        self?.mountDisk(url: url, drive: targetDrive)
      } catch {
        self?.showAlert(
          title: String(localized: "Disk Error", comment: ""),
          message: error.localizedDescription
        )
      }
    }
  }

  // MARK: - Disk Load Failure Reporting

  /// Why a disk image could not be loaded. Used to pick a user-facing
  /// explanation for the disk-load error alert.
  enum DiskLoadFailureReason {
    case unreadable         // File could not be read from disk at all.
    case emptyArchive       // Archive extracted but contains no D88 images.
    case t88TapeImage       // File is actually a T88 PC-8801 tape image.
    case notD88             // File is not a D88 and not a recognized archive.
  }

  /// Inspect the raw bytes of a file the user tried to mount to classify
  /// *why* D88 parsing failed, so the alert can give a specific hint
  /// rather than a generic "can't load" message.
  private func classifyDiskLoadFailure(data: [UInt8]) -> DiskLoadFailureReason {
    // Common foot-gun #1: a PC-8801 tape image renamed to .d88. The T88
    // file format starts with the literal "PC-8801 Tape Image(T88)"
    // string in ASCII, so sniff that first — T88 headers can otherwise
    // incidentally pass the D88-header heuristic below because the NUL
    // after "T88)" lands at offset 0x17.
    let t88Signature: [UInt8] = Array("PC-8801 Tape Image(T88)".utf8)
    if data.count >= t88Signature.count &&
      Array(data.prefix(t88Signature.count)) == t88Signature {
      return .t88TapeImage
    }

    return .notD88
  }

  /// Show a disk-load failure alert via the unified notification system.
  private func presentDiskLoadErrorAlert(fileName: String, reason: DiskLoadFailureReason) {
    let title = String(localized: "Can't Load Disk Image", comment: "Disk load failure alert title")
    let bodyFormat: String
    switch reason {
    case .unreadable:
      bodyFormat = String(
        localized:         "\"%@\" could not be read. The file may be missing, unreadable, or on a disconnected volume.",
        comment: "Disk load failure: file unreadable"
      )
    case .emptyArchive:
      bodyFormat = String(
        localized:         "\"%@\" is an archive, but it does not contain any D88 disk images.",
        comment: "Disk load failure: archive contains no D88"
      )
    case .t88TapeImage:
      bodyFormat = String(
        localized:         "\"%@\" is a PC-8801 tape image (T88), not a D88 disk image. Bubilator88 does not support T88 files.",
        comment: "Disk load failure: file is a T88 tape image"
      )
    case .notD88:
      bodyFormat = String(
        localized:         "\"%@\" is not a valid D88 disk image. The header is missing or the file is corrupted.",
        comment: "Disk load failure: file is not a D88"
      )
    }
    showAlert(title: title, message: String(format: bodyFormat, fileName))
  }
}

// MARK: - Disk Write-Back (Phase 1: write-through for standalone .d88)

extension EmulatorViewModel {

  /// Entry point called from `SubSystem.onDiskWritten`.
  ///
  /// It is called from the emulation thread, so it always hops to the MainActor
  /// before touching the scheduler, which is `@MainActor`.
  nonisolated func diskDirtyNotification(drive: Int) {
    Task { @MainActor [weak self] in
      self?.diskWriteBackScheduler.schedule(drive: drive)
    }
  }

  /// The actual write, called by the scheduler. Assumes the main thread.
  func performDiskWriteBack(drive: Int) {
    // Take the snapshot and test-and-clear dirty in **one emuQueue.sync**.
    // Doing them as two separate syncs lets a write in between set dirty=true,
    // only for the later `dirty = false` to swallow it — the known Phase 2 race.
    //
    // Clearing dirty up front means a write that arrives while this one is in
    // flight is guaranteed to be written back on the scheduler's next firing.
    // dirty is restored only if the write fails.
    let snapshot: [UInt8]? = emuQueue.sync { pc88.takeDirtyDiskImage(drive: drive) }
    guard let bankBytes = snapshot else { return }

    let info = (drive == 0 ? drive0Info : drive1Info)
    let sourceURL = info?.sourceURL
    let imageIndex = info?.currentImageIndex ?? 0

    // Choose the write-back destination.
    // Since Phase 2, sourceURL points at the cached .d88 even for archive-backed
    // disks, so both cases can be written the same way.
    // - Write to sourceURL when there is one
    // - Otherwise fall back to the recovery directory
    guard let writeURL = sourceURL else {
      DiskWriteBackIO.writeBankToRecovery(
        bankBytes: bankBytes,
        fileName: info?.fileName ?? "disk\(drive)",
        drive: drive,
        recoveryDir: DiskWriteBackIO.defaultRecoveryDirectory
      )
      return
    }

    do {
      try DiskWriteBackIO.writeBank(bankBytes: bankBytes,
                                    imageIndex: imageIndex,
                                    url: writeURL)
    } catch {
      // Write failed: restore dirty so it can be retried, and fall back to recovery.
      emuQueue.sync {
        pc88.markDiskDirty(drive: drive)
      }
      DiskWriteBackIO.writeBankToRecovery(
        bankBytes: bankBytes,
        fileName: info?.fileName ?? "disk\(drive)",
        drive: drive,
        recoveryDir: DiskWriteBackIO.defaultRecoveryDirectory
      )
      showAlert(
        title: String(localized: "Disk Write Failed", comment: ""),
        message: error.localizedDescription
      )
    }
  }
}
