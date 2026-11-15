import Foundation

/// Generates byte-for-byte references using the pinned core's own formatter.
@main
struct BlankDiskTemplates {
  static func main() throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    for (label, type) in [("2D", D88Disk.DiskType.twoD), ("2DD", .twoDD), ("2HD", .twoHD)] {
      for basic in [false, true] {
        let disk = D88Disk.createFormatted(type: type, name: "", initBasicFAT: basic)
        guard let bytes = disk.serialize() else { fatalError("Cannot serialize blank disk") }
        let name = "\(label)-\(basic ? "basic" : "erased").d88"
        try Data(bytes).write(to: directory.appendingPathComponent(name))
      }
    }
  }
}
