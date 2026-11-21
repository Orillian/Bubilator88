import AppIntents
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

// Siri and Shortcuts support is deliberately undocumented: linkd runs an
// app's intents only when the app is signed with a Team ID, and release
// builds are ad-hoc signed (`release.yml`), so only self-built copies get it.
// An ad-hoc build fails every intent with LinkDaemon.ProcessRegistry.Error.

/// The view model App Intents act on. `ContentView.onAppear` sets it once the
/// ROMs are loaded and the machine runs; intents, entity queries and the
/// screen export all read it from here.
@MainActor
enum AppIntentsHost {
  static weak var viewModel: EmulatorViewModel?
  /// Entity identifiers of mounted disks, keyed by mount session
  /// (`MountedDiskInfo.id`). Working one out touches the file system, and the
  /// screen annotation asks on every view update.
  static var mountedIdentifiers: [UUID: String] = [:]
}

/// A disk image file, as Siri and Shortcuts see it: the game in the drive or
/// one of the recently used disks.
///
/// The identifier is the file's standardized path, the same key
/// `RecentDiskEntry.filePath` uses, so a mounted disk and its recent-list
/// entry resolve to the same entity.
nonisolated struct DiskImageEntity: AppEntity, Hashable {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Disk Image"
  static let defaultQuery = DiskImageQuery()

  let id: String
  let name: String

  /// The identifier for a disk at `path`: standardized and with symlinks
  /// resolved, so `/tmp/a.d88` from the recent list and the mounted
  /// `/private/tmp/a.d88` are one entity.
  static func identifier(forPath path: String) -> String {
    URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }
  /// The folder for a recent disk, or what else is mounted for the disk in
  /// the drive.
  let detail: String?

  var displayRepresentation: DisplayRepresentation {
    if let detail {
      DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    } else {
      DisplayRepresentation(title: "\(name)")
    }
  }
}

extension DiskImageEntity: Transferable {
  /// The emulator screen as PNG, when this disk is the one in drive 1.
  /// Siri gets the picture of the game through this; no OCR is done.
  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .png) { entity in
      try await MainActor.run {
        guard let viewModel = AppIntentsHost.viewModel,
              viewModel.mountedDiskPath(drive: 0) == entity.id,
              let data = viewModel.screenImageData() else {
          throw EmulatorIntentError.screenUnavailable
        }
        return data
      }
    }
  }
}

/// What the entity query needs to know about the machine, gathered on the
/// main actor so the lookup itself stays a pure function.
nonisolated struct DiskImageCatalog: Sendable {
  struct Mounted: Sendable {
    let path: String
    let name: String
  }

  struct Recent: Sendable {
    let path: String
    let name: String
    let folder: String
  }

  /// Drive 1 and drive 2, in that order; nil for an empty drive.
  var drives: [Mounted?]
  var tapeName: String?
  var recents: [Recent]

  /// Every entity the catalog knows: mounted disks first, then the recent
  /// disks that are not mounted.
  var allEntities: [DiskImageEntity] {
    var result: [DiskImageEntity] = []
    for (index, mounted) in drives.enumerated() {
      guard let mounted, !result.contains(where: { $0.id == mounted.path }) else { continue }
      result.append(DiskImageEntity(id: mounted.path, name: mounted.name,
                                    detail: companionDetail(excludingDrive: index)))
    }
    for recent in recents where !result.contains(where: { $0.id == recent.path }) {
      result.append(DiskImageEntity(id: recent.path, name: recent.name, detail: recent.folder))
    }
    return result
  }

  func entities(for identifiers: [String]) -> [DiskImageEntity] {
    let all = allEntities
    return identifiers.compactMap { id in all.first { $0.id == id } }
  }

  func entities(matching query: String) -> [DiskImageEntity] {
    allEntities.filter { $0.name.localizedStandardContains(query) }
  }

  /// The other drive and the tape, for the subtitle of a mounted disk.
  private func companionDetail(excludingDrive drive: Int) -> String? {
    var parts: [String] = []
    for (index, mounted) in drives.enumerated() where index != drive {
      if let mounted, mounted.path != drives[drive]?.path { parts.append(mounted.name) }
    }
    if let tapeName { parts.append(tapeName) }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }
}

nonisolated struct DiskImageQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [DiskImageEntity] {
    await Self.catalog().entities(for: identifiers)
  }

  func entities(matching string: String) async throws -> [DiskImageEntity] {
    await Self.catalog().entities(matching: string)
  }

  func suggestedEntities() async throws -> [DiskImageEntity] {
    await Self.catalog().allEntities
  }

  @MainActor
  private static func catalog() -> DiskImageCatalog {
    let recents = Settings.shared.recentFiles(.disk).map {
      DiskImageCatalog.Recent(path: DiskImageEntity.identifier(forPath: $0.filePath),
                              name: $0.displayName, folder: $0.displayDir)
    }
    guard let viewModel = AppIntentsHost.viewModel else {
      return DiskImageCatalog(drives: [nil, nil], tapeName: nil, recents: recents)
    }
    return DiskImageCatalog(drives: [viewModel.mountedDisk(drive: 0), viewModel.mountedDisk(drive: 1)],
                            tapeName: viewModel.isTapeMounted ? viewModel.tapeName : nil,
                            recents: recents)
  }
}

extension EmulatorViewModel {
  /// The path of the file the user opened for `drive` (the archive, not the
  /// extracted cache copy), in the form `DiskImageEntity.identifier(forPath:)` gives.
  func mountedDiskPath(drive: Int) -> String? {
    guard let info = drive == 0 ? drive0Info : drive1Info else { return nil }
    if let cached = AppIntentsHost.mountedIdentifiers[info.id] { return cached }
    guard let url = info.originArchiveURL ?? info.sourceURL else { return nil }
    // A disk restored from a save state or resume points into the disk cache
    // with no `originArchiveURL`; map it back to the archive the user opened.
    let path = DiskCacheManager.shared.originalArchivePath(forCachedFile: url) ?? url.path
    let identifier = DiskImageEntity.identifier(forPath: path)
    // Keep only the sessions still in a drive.
    let live = Set([drive0Info?.id, drive1Info?.id].compactMap(\.self))
    AppIntentsHost.mountedIdentifiers = AppIntentsHost.mountedIdentifiers.filter { live.contains($0.key) }
    AppIntentsHost.mountedIdentifiers[info.id] = identifier
    return identifier
  }

  /// Whether `identifier` is already open: in either drive, or a playlist
  /// whose first disk is in drive 1.
  func isDiskOpen(_ identifier: String) -> Bool {
    let mounted = [mountedDiskPath(drive: 0), mountedDiskPath(drive: 1)]
    if mounted.contains(identifier) { return true }
    let url = URL(filePath: identifier)
    guard M3UPlaylist.isPlaylist(url), let first = M3UPlaylist.entryURLs(contentsOf: url)?.first else { return false }
    return mounted[0] == DiskImageEntity.identifier(forPath: first.path)
  }

  fileprivate func mountedDisk(drive: Int) -> DiskImageCatalog.Mounted? {
    guard let path = mountedDiskPath(drive: drive) else { return nil }
    // The full file name, as `RecentDiskEntry.displayName` has it, so a disk
    // keeps one name whether it is mounted or only in the recent list.
    return DiskImageCatalog.Mounted(path: path, name: URL(filePath: path).lastPathComponent)
  }
}
