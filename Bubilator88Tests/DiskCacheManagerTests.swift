import Testing
import Foundation
@testable import Bubilator88

struct DiskCacheManagerTests {

  /// Gives each test its own temporary directory as the cache root.
  private func makeTempCache() -> (cache: DiskCacheManager, root: URL) {
    let root = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
      .appending(component: "DiskCacheManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    return (DiskCacheManager(root: root), root)
  }

  private func makeEntry(_ name: String, bytes: [UInt8] = [0xAA, 0xBB]) -> ArchiveEntry {
    ArchiveEntry(filename: name, data: Data(bytes))
  }

  // MARK: - hash

  @Test("computeHash: same data → same hash")
  func hashIsStable() {
    let a = Data(repeating: 0x55, count: 1024)
    let b = Data(repeating: 0x55, count: 1024)
    #expect(DiskCacheManager.computeHash(a) == DiskCacheManager.computeHash(b))
  }

  @Test("computeHash: different size disambiguates same prefix")
  func hashDifferentSizes() {
    let a = Data(repeating: 0, count: 100)
    let b = Data(repeating: 0, count: 200)
    #expect(DiskCacheManager.computeHash(a) != DiskCacheManager.computeHash(b))
    // The size appears as a trailing "-N" on the hash
    #expect(DiskCacheManager.computeHash(a).hasSuffix("-100"))
    #expect(DiskCacheManager.computeHash(b).hasSuffix("-200"))
  }

  // MARK: - sanitizedFileName

  @Test("sanitizedFileName: directory hierarchy is preserved (no collision)")
  func sanitizePreservesHierarchy() {
    // Regression from R1: taking only the basename via lastPathComponent
    // collapses diskA/foo.d88 and diskB/foo.d88 into the same filename.
    let a = DiskCacheManager.sanitizedFileName("diskA/foo.d88")
    let b = DiskCacheManager.sanitizedFileName("diskB/foo.d88")
    #expect(a != b)
    #expect(a == "diskA_foo.d88")
    #expect(b == "diskB_foo.d88")
  }

  @Test("sanitizedFileName: blocks path traversal")
  func sanitizeBlocksTraversal() {
    let s = DiskCacheManager.sanitizedFileName("../../etc/passwd")
    #expect(!s.contains(".."))
    #expect(!s.contains("/"))
  }

  @Test("sanitizedFileName: NFC normalization of composed/decomposed forms")
  func sanitizeNFCNormalization() {
    // Write "が" both precomposed (U+304C) and decomposed (U+304B U+3099)
    let composed = "\u{304C}"            // が (precomposed)
    let decomposed = "\u{304B}\u{3099}"  // か + dakuten combining mark
    let s1 = DiskCacheManager.sanitizedFileName(composed + ".d88")
    let s2 = DiskCacheManager.sanitizedFileName(decomposed + ".d88")
    #expect(s1 == s2)
  }

  @Test("sanitizedFileName: backslash and colon both become underscore")
  func sanitizeBackslashColon() {
    #expect(DiskCacheManager.sanitizedFileName("a\\b:c.d88") == "a_b_c.d88")
  }

  // MARK: - ensureCached / cachedEntryURL

  @Test("ensureCached: same archive twice does not duplicate writes")
  func ensureCachedIdempotent() throws {
    let (cache, root) = makeTempCache()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = URL(filePath: "/tmp/dummy.zip")
    let data = Data(repeating: 0x42, count: 256)
    let entry = makeEntry("foo.d88", bytes: [0x01, 0x02, 0x03])

    let dir1 = try cache.ensureCached(archiveURL: url, archiveData: data, entries: [entry])
    let entryURL = dir1.appending(component: "foo.d88")
    // Between the two calls, inject an overwrite standing in for a write-back
    try Data([0x99]).write(to: entryURL, options: .atomic)
    let modifiedMTime = try FileManager.default.attributesOfItem(atPath: entryURL.path)[.modificationDate] as? Date

    let dir2 = try cache.ensureCached(archiveURL: url, archiveData: data, entries: [entry])
    #expect(dir1 == dir2)

    // The existing entry is not overwritten, so written-back content is preserved
    let bytes = try Data(contentsOf: entryURL)
    #expect(bytes == Data([0x99]))
    let afterMTime = try FileManager.default.attributesOfItem(atPath: entryURL.path)[.modificationDate] as? Date
    #expect(modifiedMTime == afterMTime)
  }

  @Test("ensureCached: entries with same basename across folders do not collide")
  func ensureCachedNoCollisionAcrossFolders() throws {
    let (cache, root) = makeTempCache()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = URL(filePath: "/tmp/dummy.zip")
    let data = Data(repeating: 1, count: 512)
    let entries = [
      makeEntry("diskA/wizardry.d88", bytes: [0xA1]),
      makeEntry("diskB/wizardry.d88", bytes: [0xB1])
    ]
    let dir = try cache.ensureCached(archiveURL: url, archiveData: data, entries: entries)

    let a = try Data(contentsOf: dir.appending(component: "diskA_wizardry.d88"))
    let b = try Data(contentsOf: dir.appending(component: "diskB_wizardry.d88"))
    #expect(a == Data([0xA1]))
    #expect(b == Data([0xB1]))
  }

  @Test("ensureCached: writes source.json with metadata")
  func ensureCachedWritesMetadata() throws {
    let (cache, root) = makeTempCache()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = URL(filePath: "/tmp/x.zip")
    let data = Data(repeating: 7, count: 99)
    let dir = try cache.ensureCached(archiveURL: url, archiveData: data,
                                     entries: [makeEntry("a.d88")])
    let json = try Data(contentsOf: dir.appending(component: "source.json"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let meta = try decoder.decode(DiskCacheManager.SourceMeta.self, from: json)
    #expect(meta.originalPath == "/tmp/x.zip")
    #expect(meta.originalFileSize == 99)
    #expect(meta.entries == ["a.d88"])
  }

  @Test("originalArchivePath: maps a cached file back to its archive")
  func originalArchivePathForCachedFile() throws {
    let (cache, root) = makeTempCache()
    defer { try? FileManager.default.removeItem(at: root) }

    let dir = try cache.ensureCached(archiveURL: URL(filePath: "/games/ys.zip"),
                                     archiveData: Data(repeating: 3, count: 50),
                                     entries: [makeEntry("ys.d88")])
    let cached = try #require(cache.cachedEntryURL(in: dir, entryName: "ys.d88"))
    #expect(cache.originalArchivePath(forCachedFile: cached) == "/games/ys.zip")
    #expect(cache.originalArchivePath(forCachedFile: URL(filePath: "/games/ys.d88")) == nil)
  }

  // MARK: - resolvedData

  @Test("resolvedData: returns cache content when entry is cached")
  func resolvedDataPrefersCache() throws {
    let (cache, root) = makeTempCache()
    defer { try? FileManager.default.removeItem(at: root) }

    let entry = makeEntry("foo.d88", bytes: [0x10, 0x20])
    let url = URL(filePath: "/tmp/x.zip")
    let archiveData = Data(repeating: 0, count: 64)
    let dir = try cache.ensureCached(archiveURL: url, archiveData: archiveData, entries: [entry])

    // Replace the cached file with bytes representing a completed write-back
    let entryURL = dir.appending(component: "foo.d88")
    try Data([0xFF]).write(to: entryURL, options: .atomic)

    let resolved = cache.resolvedData(for: entry, in: dir)
    #expect(resolved == Data([0xFF]))
  }

  @Test("resolvedData: falls back to entry.data when cache is missing")
  func resolvedDataFallback() {
    let (cache, root) = makeTempCache()
    defer { try? FileManager.default.removeItem(at: root) }
    let entry = makeEntry("nope.d88", bytes: [0x42])
    let resolved = cache.resolvedData(for: entry, in: nil)
    #expect(resolved == Data([0x42]))
  }

  // MARK: - enumerateCachedDisks / export

  @Test("enumerate: returns all cached .d88 with origin metadata")
  func enumerateLists() throws {
    let (cache, root) = makeTempCache()
    defer { try? FileManager.default.removeItem(at: root) }

    // An archive that exists
    let existingArchive = root.appending(component: "present.zip")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([0x50, 0x4B]).write(to: existingArchive)
    _ = try cache.ensureCached(archiveURL: existingArchive,
                               archiveData: Data(repeating: 1, count: 64),
                               entries: [makeEntry("a.d88"), makeEntry("b.d88")])

    // An archive that does not exist: only the path is recorded, no file created
    let missingArchive = URL(filePath: "/tmp/nonexistent-\(UUID().uuidString).zip")
    _ = try cache.ensureCached(archiveURL: missingArchive,
                               archiveData: Data(repeating: 2, count: 64),
                               entries: [makeEntry("c.d88")])

    let cached = cache.enumerateCachedDisks()
    #expect(cached.count == 3)
    let present = cached.filter { $0.originalExists }
    let orphan = cached.filter { !$0.originalExists }
    #expect(present.count == 2)
    #expect(orphan.count == 1)
    #expect(orphan.first?.diskURL.lastPathComponent == "c.d88")
  }

  @Test("export: copies all disks when orphansOnly = false")
  func exportAll() throws {
    let (cache, root) = makeTempCache()
    defer { try? FileManager.default.removeItem(at: root) }

    let dest = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
      .appending(component: "export-dest-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dest) }

    let archive = URL(filePath: "/tmp/nonexistent-\(UUID().uuidString).zip")
    _ = try cache.ensureCached(archiveURL: archive,
                               archiveData: Data(repeating: 3, count: 32),
                               entries: [makeEntry("x.d88", bytes: [0x11]),
                                         makeEntry("y.d88", bytes: [0x22])])

    let result = try cache.exportCachedDisks(to: dest, orphansOnly: false)
    #expect(result.exported == 2)
    #expect(result.skipped == 0)
    #expect(FileManager.default.fileExists(atPath: dest.appending(component: "x.d88").path))
    #expect(FileManager.default.fileExists(atPath: dest.appending(component: "y.d88").path))
  }

  @Test("export: orphansOnly skips disks whose archive still exists")
  func exportOrphansOnly() throws {
    let (cache, root) = makeTempCache()
    defer { try? FileManager.default.removeItem(at: root) }

    let dest = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
      .appending(component: "export-dest-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dest) }

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let present = root.appending(component: "p.zip")
    try Data([0]).write(to: present)
    _ = try cache.ensureCached(archiveURL: present,
                               archiveData: Data(repeating: 4, count: 16),
                               entries: [makeEntry("present.d88")])

    let missing = URL(filePath: "/tmp/missing-\(UUID().uuidString).zip")
    _ = try cache.ensureCached(archiveURL: missing,
                               archiveData: Data(repeating: 5, count: 16),
                               entries: [makeEntry("orphan.d88")])

    let result = try cache.exportCachedDisks(to: dest, orphansOnly: true)
    #expect(result.exported == 1)
    #expect(result.skipped == 1)
    #expect(FileManager.default.fileExists(atPath: dest.appending(component: "orphan.d88").path))
    #expect(!FileManager.default.fileExists(atPath: dest.appending(component: "present.d88").path))
  }

  @Test("export: name collisions get -2, -3 suffix")
  func exportNameCollision() throws {
    let (cache, root) = makeTempCache()
    defer { try? FileManager.default.removeItem(at: root) }

    let dest = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
      .appending(component: "export-dest-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dest) }
    // Put a file of the same name there first
    try Data([0xAA]).write(to: dest.appending(component: "dup.d88"))

    // Extract two dup.d88 files from different archives
    let a = URL(filePath: "/tmp/a-\(UUID().uuidString).zip")
    _ = try cache.ensureCached(archiveURL: a,
                               archiveData: Data(repeating: 6, count: 8),
                               entries: [makeEntry("dup.d88", bytes: [0x01])])
    let b = URL(filePath: "/tmp/b-\(UUID().uuidString).zip")
    _ = try cache.ensureCached(archiveURL: b,
                               archiveData: Data(repeating: 7, count: 8),
                               entries: [makeEntry("dup.d88", bytes: [0x02])])

    let result = try cache.exportCachedDisks(to: dest, orphansOnly: false)
    #expect(result.exported == 2)
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: dest.appending(component: "dup.d88").path))   // pre-existing
    #expect(fm.fileExists(atPath: dest.appending(component: "dup-2.d88").path)) // first
    #expect(fm.fileExists(atPath: dest.appending(component: "dup-3.d88").path)) // second
  }

  // MARK: - Archive update (item 6)

  @Test("ensureCached: アーカイブ内容が変わると別キャッシュディレクトリ + 旧キャッシュ保持")
  func ensureCachedHashChangePreservesOldCache() throws {
    let (cache, root) = makeTempCache()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = URL(filePath: "/tmp/game.zip")
    let v1Data = Data(repeating: 0x01, count: 1024)
    let v2Data = Data(repeating: 0x02, count: 1024)

    // Extract v1, then inject a write-back standing in for an in-game save
    let dirV1 = try cache.ensureCached(archiveURL: url, archiveData: v1Data,
                                       entries: [makeEntry("save.d88", bytes: [0x11])])
    let entryV1 = dirV1.appending(component: "save.d88")
    try Data([0xAA, 0xBB]).write(to: entryV1, options: .atomic)

    // Updating the archive changes the content and so the hash, creating a new cache
    let dirV2 = try cache.ensureCached(archiveURL: url, archiveData: v2Data,
                                       entries: [makeEntry("save.d88", bytes: [0x22])])
    #expect(dirV1 != dirV2)

    // The old cache is still there, so the user's save is safe
    #expect(FileManager.default.fileExists(atPath: dirV1.path))
    let preservedV1 = try Data(contentsOf: entryV1)
    #expect(preservedV1 == Data([0xAA, 0xBB]))

    // The new cache holds the new content
    let entryV2 = try Data(contentsOf: dirV2.appending(component: "save.d88"))
    #expect(entryV2 == Data([0x22]))

    // Both cache directories follow the hash naming convention
    #expect(DiskCacheManager.isCacheDirectoryName(dirV1.lastPathComponent))
    #expect(DiskCacheManager.isCacheDirectoryName(dirV2.lastPathComponent))
  }

  // MARK: - uniqueDestinationURL

  @Test("uniqueDestinationURL: handles files without extension")
  func uniqueNoExtension() throws {
    let dir = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
      .appending(component: "UDU-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let first = DiskCacheManager.uniqueDestinationURL(in: dir, baseName: "noext")
    #expect(first.lastPathComponent == "noext")

    try Data().write(to: first)
    let second = DiskCacheManager.uniqueDestinationURL(in: dir, baseName: "noext")
    #expect(second.lastPathComponent == "noext-2")
  }
}
