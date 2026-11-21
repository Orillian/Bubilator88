import Foundation
import Testing
@testable import Bubilator88

struct DiskImageCatalogTests {

  private let catalog = DiskImageCatalog(
    drives: [.init(path: "/games/ys.d88", name: "ys.d88"),
             .init(path: "/games/ys-user.d88", name: "ys-user.d88")],
    tapeName: nil,
    recents: [.init(path: "/games/ys.d88", name: "ys.d88", folder: "~/games"),
              .init(path: "/games/sorcerian.zip", name: "sorcerian.zip", folder: "~/games")]
  )

  @Test func mountedDisksComeFirstAndRecentsAreNotDuplicated() {
    #expect(catalog.allEntities.map(\.id) == ["/games/ys.d88", "/games/ys-user.d88", "/games/sorcerian.zip"])
  }

  @Test func mountedDiskSubtitleNamesTheOtherDrive() {
    #expect(catalog.allEntities[0].detail == "ys-user.d88")
    #expect(catalog.allEntities[2].detail == "~/games")
  }

  @Test func sameDiskInBothDrivesHasNoSubtitle() {
    let both = DiskImageCatalog(drives: [.init(path: "/a.d88", name: "a.d88"), .init(path: "/a.d88", name: "a.d88")],
                                tapeName: nil, recents: [])
    #expect(both.allEntities.count == 1)
    #expect(both.allEntities[0].detail == nil)
  }

  @Test func tapeAppearsInSubtitle() {
    let withTape = DiskImageCatalog(drives: [.init(path: "/a.d88", name: "a.d88"), nil],
                                    tapeName: "game.cmt", recents: [])
    #expect(withTape.allEntities[0].detail == "game.cmt")
  }

  @Test func lookupByIdentifierKeepsOrderAndDropsUnknown() {
    let found = catalog.entities(for: ["/games/sorcerian.zip", "/missing.d88", "/games/ys.d88"])
    #expect(found.map(\.id) == ["/games/sorcerian.zip", "/games/ys.d88"])
  }

  @Test func identifierResolvesSymlinks() throws {
    // Symlinks resolve only for files that exist, so build a real one.
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? fm.removeItem(at: dir) }
    let real = dir.appending(component: "real")
    try fm.createDirectory(at: real, withIntermediateDirectories: true)
    fm.createFile(atPath: real.appending(component: "game.d88").path, contents: Data())
    let link = dir.appending(component: "link")
    try fm.createSymbolicLink(at: link, withDestinationURL: real)

    let viaLink = DiskImageEntity.identifier(forPath: link.appending(component: "game.d88").path)
    let direct = DiskImageEntity.identifier(forPath: real.appending(component: "game.d88").path)
    #expect(viaLink == direct)
    // `/private/var/...` (how a resolved bookmark reports it) matches too.
    #expect(DiskImageEntity.identifier(forPath: "/private" + direct) == direct)
  }

  @Test func nameSearchIsCaseInsensitive() {
    #expect(catalog.entities(matching: "SORC").map(\.id) == ["/games/sorcerian.zip"])
  }
}
