import Foundation
import CryptoKit
import Logging

/// Keeps D88 files extracted from an archive (ZIP/LZH/CAB/RAR/7z) in a disk cache,
/// so they can be reused as the destination for write-through write-back.
///
/// Cache layout:
/// ```
/// <root>/<hash>/
///   ├── source.json         metadata about the original archive
///   ├── <entry1>.d88        extracted D88, entry name normalized to NFC
///   └── <entry2>.d88
/// ```
///
/// The hash is the first 16 hex digits of `SHA256(archiveData)`, a `-`, and the
/// file size — collision resistance plus cheap screening by size.
///
/// Extraction happens only on the first mount; later mounts use the cached files
/// directly. Write-back targets those cached files and never touches the
/// original archive.
///
/// Implemented as a struct with a swappable `root` so unit tests can inject an
/// instance pointing at a temporary directory.
nonisolated struct DiskCacheManager {

  /// Contents of `source.json`.
  struct SourceMeta: Codable {
    let originalPath: String
    let originalFileSize: Int
    let entries: [String]
    let lastAccessedAt: Date
  }

  enum CacheError: Error, LocalizedError {
    case directoryCreationFailed(URL, underlying: Error)
    case entryWriteFailed(name: String, underlying: Error)
    case metadataWriteFailed(URL, underlying: Error)

    var errorDescription: String? {
      switch self {
      case .directoryCreationFailed(let url, let err):
        return "Failed to create cache directory at \(url.path): \(err.localizedDescription)"
      case .entryWriteFailed(let name, let err):
        return "Failed to write cache entry \"\(name)\": \(err.localizedDescription)"
      case .metadataWriteFailed(let url, let err):
        return "Failed to write cache metadata at \(url.path): \(err.localizedDescription)"
      }
    }
  }

  /// Cache root. Defaults to
  /// `~/Library/Application Support/Bubilator88/disks/`。
  var root: URL

  static let shared = DiskCacheManager(root: Self.defaultRoot)

  /// Shared JSONEncoder, writing `Date` as ISO8601.
  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
  }()

  private static let log = Logger(label: "App.DiskCache")

  private static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()

  static var defaultRoot: URL {
    URL.applicationSupportDirectory
      .appending(component: "Bubilator88", directoryHint: .isDirectory)
      .appending(component: "disks", directoryHint: .isDirectory)
  }

  // MARK: - Public API

  /// Extracts an archive into the cache, on first use only. If it is already
  /// extracted this just updates lastAccessedAt.
  ///
  /// - Parameters:
  ///   - archiveURL: URL of the original archive, recorded as metadata.
  ///   - archiveData: The whole archive as bytes, used to compute the hash.
  ///   - entries: The extracted entries, as returned by
  ///     `ArchiveExtractor.extractDiskImages`.
  /// - Returns: URL of the cache directory.
  /// - Throws: `CacheError` if the directory cannot be created or an entry
  ///   cannot be written. A failed metadata write only logs a warning and still
  ///   counts as success: the disk files themselves are intact, so write-back
  ///   remains usable.
  func ensureCached(archiveURL: URL,
                    archiveData: Data,
                    entries: [ArchiveEntry]) throws -> URL {
    let dir = cacheDirectoryURL(for: archiveData)

    do {
      try FileManager.default.createDirectory(at: dir,
                                              withIntermediateDirectories: true)
    } catch {
      throw CacheError.directoryCreationFailed(dir, underlying: error)
    }

    var writtenNames: [String] = []
    for entry in entries {
      let name = Self.sanitizedFileName(entry.filename)
      writtenNames.append(name)
      let url = dir.appending(component: name)
      if FileManager.default.fileExists(atPath: url.path) { continue }
      do {
        try entry.data.write(to: url, options: .atomic)
      } catch {
        throw CacheError.entryWriteFailed(name: name, underlying: error)
      }
    }

    let meta = SourceMeta(originalPath: archiveURL.path,
                          originalFileSize: archiveData.count,
                          entries: writtenNames,
                          lastAccessedAt: Date())
    do {
      try writeSourceMeta(meta, to: dir)
    } catch {
      Self.log.warning("source.json write failed: \(String(describing: error))")
    }

    return dir
  }

  /// Background variant of `ensureCached`, for when the SHA256 computation and
  /// writing several megabytes should not block the main thread.
  func ensureCachedDetached(archiveURL: URL,
                            archiveData: Data,
                            entries: [ArchiveEntry]) async throws -> URL {
    try await Task.detached(priority: .userInitiated) { [self] in
      try self.ensureCached(archiveURL: archiveURL,
                            archiveData: archiveData,
                            entries: entries)
    }.value
  }

  /// Returns the URL of a given entry inside an existing cache directory.
  func cachedEntryURL(in cacheDir: URL, entryName: String) -> URL? {
    let normalized = Self.sanitizedFileName(entryName)
    let url = cacheDir.appending(component: normalized)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// Resolves the bytes to mount. Reads from the cache when a file of the same
  /// name is there, so a previous write-back is picked up; otherwise falls back
  /// to the in-memory `entry.data`.
  func resolvedData(for entry: ArchiveEntry, in cacheDir: URL?) -> Data {
    if let dir = cacheDir,
       let entryURL = cachedEntryURL(in: dir, entryName: entry.filename),
       let cached = try? Data(contentsOf: entryURL) {
      return cached
    }
    return entry.data
  }

  /// The archive a cached `.d88` was extracted from, as recorded in its
  /// directory's `source.json`. Nil for a file outside the cache or when the
  /// metadata cannot be read.
  func originalArchivePath(forCachedFile url: URL) -> String? {
    let dir = url.deletingLastPathComponent()
    guard Self.isCacheDirectoryName(dir.lastPathComponent),
          dir.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
          let data = try? Data(contentsOf: dir.appending(component: "source.json")),
          let meta = try? Self.decoder.decode(SourceMeta.self, from: data)
    else { return nil }
    return meta.originalPath
  }

  /// Computes the cache directory URL without creating it.
  func cacheDirectoryURL(for archiveData: Data) -> URL {
    root.appending(component: Self.computeHash(archiveData), directoryHint: .isDirectory)
  }

  /// Information about a single disk file held in the cache.
  struct CachedDisk {
    /// URL of the `.d88` inside the cache.
    let diskURL: URL
    /// Path of the original archive as recorded in `source.json`, or nil if
    /// none was recorded.
    let originalArchivePath: String?
    /// Whether the original archive still exists. False when
    /// `originalArchivePath` is nil.
    let originalExists: Bool
  }

  /// Walks every cache directory under `root` and returns all the `.d88` files
  /// they contain, skipping directories whose `source.json` cannot be read.
  /// Used by the export feature.
  func enumerateCachedDisks() -> [CachedDisk] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: root,
                                                    includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])
    else { return [] }

    var result: [CachedDisk] = []
    for cacheDir in entries {
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: cacheDir.path, isDirectory: &isDir), isDir.boolValue
      else { continue }
      // Only directories matching `<16hex>-<digits>` count as caches, so a
      // folder the user happens to have put under root is not mistaken for one.
      guard Self.isCacheDirectoryName(cacheDir.lastPathComponent) else { continue }

      let originalPath: String? = {
        let metaURL = cacheDir.appending(component: "source.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? Self.decoder.decode(SourceMeta.self, from: data)
        else { return nil }
        return meta.originalPath
      }()
      let originalExists = originalPath.map { fm.fileExists(atPath: $0) } ?? false

      let files = (try? fm.contentsOfDirectory(at: cacheDir,
                                               includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles])) ?? []
      for file in files where file.lastPathComponent != "source.json" {
        result.append(CachedDisk(diskURL: file,
                                 originalArchivePath: originalPath,
                                 originalExists: originalExists))
      }
    }
    return result
  }

  /// Copies the enumerated cache disks into a folder.
  /// - Parameters:
  ///   - destination: Destination folder, assumed to exist.
  ///   - orphansOnly: When true, copies only those whose original archive is gone.
  /// - Returns: The number actually written, and the number the filter excluded.
  /// - Throws: If a copy fails. Anything already copied is left in place.
  func exportCachedDisks(to destination: URL, orphansOnly: Bool) throws -> (exported: Int, skipped: Int) {
    let fm = FileManager.default
    var exported = 0
    var skipped = 0

    for cached in enumerateCachedDisks() {
      if orphansOnly && cached.originalExists {
        skipped += 1
        continue
      }
      let destURL = Self.uniqueDestinationURL(in: destination,
                                              baseName: cached.diskURL.lastPathComponent)
      try fm.copyItem(at: cached.diskURL, to: destURL)
      exported += 1
    }
    return (exported, skipped)
  }

  /// Whether a name matches the `<16hex>-<size>` form `computeHash` produces.
  static func isCacheDirectoryName(_ name: String) -> Bool {
    let parts = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    let hex = parts[0]
    let size = parts[1]
    guard hex.count == 16, hex.allSatisfy({ $0.isHexDigit }) else { return false }
    return !size.isEmpty && size.allSatisfy({ $0.isASCII && $0.isNumber })
  }

  /// Returns a destination URL that does not collide with an existing file. If
  /// `foo.d88` is taken it tries `foo-2.d88`, `foo-3.d88`, and so on.
  static func uniqueDestinationURL(in directory: URL, baseName: String) -> URL {
    let fm = FileManager.default
    let url = directory.appending(component: baseName)
    if !fm.fileExists(atPath: url.path) { return url }

    let ext = (baseName as NSString).pathExtension
    let stem = (baseName as NSString).deletingPathExtension
    var n = 2
    while true {
      let candidate = ext.isEmpty
        ? directory.appending(component: "\(stem)-\(n)")
        : directory.appending(component: "\(stem)-\(n).\(ext)")
      if !fm.fileExists(atPath: candidate.path) { return candidate }
      n += 1
    }
  }

  // MARK: - Internal helpers (static, pure functions)

  /// The first 16 hex digits of the SHA256, a `-`, and the byte count.
  static func computeHash(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "\(hex.prefix(16))-\(data.count)"
  }

  /// Makes an entry name safe to use as a filename.
  /// - Normalizes to NFC
  /// - Replaces directory separators (`/`, `\`) with `_`, keeping the hierarchy
  ///   visible so names stay distinct
  /// - Replaces colons with `_`
  /// - Rewrites `..` as `__` to prevent path traversal
  static func sanitizedFileName(_ raw: String) -> String {
    let normalized = raw.precomposedStringWithCanonicalMapping
    return normalized
      .replacingOccurrences(of: "..", with: "__")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "\\", with: "_")
      .replacingOccurrences(of: ":", with: "_")
  }

  private func writeSourceMeta(_ meta: SourceMeta, to dir: URL) throws {
    let url = dir.appending(component: "source.json")
    let data = try Self.encoder.encode(meta)
    try data.write(to: url, options: .atomic)
  }
}
