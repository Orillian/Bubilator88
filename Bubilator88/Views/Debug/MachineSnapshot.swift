import Foundation
@_spi(Debug) import Bubilator88Core

/// Immutable snapshot of Machine state, captured on the emulator queue
/// and consumed by SwiftUI views on the main actor.
///
/// Designed as a single value type so views never reach into mutable
/// emulator state directly. The polling mechanism in ``DebugSession``
/// builds these and publishes them to observers.
struct MachineSnapshot: Sendable, Equatable {

  // MARK: - Main CPU registers

  let mainPC:  UInt16
  let mainSP:  UInt16
  let mainAF:  UInt16
  let mainBC:  UInt16
  let mainDE:  UInt16
  let mainHL:  UInt16
  let mainIX:  UInt16
  let mainIY:  UInt16
  let mainAF2: UInt16
  let mainBC2: UInt16
  let mainDE2: UInt16
  let mainHL2: UInt16
  let mainI:   UInt8
  let mainR:   UInt8
  let mainIff1: Bool
  let mainIff2: Bool
  let mainIM:   UInt8
  let mainHalted: Bool

  // MARK: - Sub CPU registers

  let subPC:  UInt16
  let subSP:  UInt16
  let subAF:  UInt16
  let subBC:  UInt16
  let subDE:  UInt16
  let subHL:  UInt16
  let subIX:  UInt16
  let subIY:  UInt16
  let subAF2: UInt16
  let subBC2: UInt16
  let subDE2: UInt16
  let subHL2: UInt16
  let subI:   UInt8
  let subR:   UInt8
  let subHalted: Bool
  let subIff1:   Bool
  let subIff2:   Bool
  let subIM:     UInt8

  // MARK: - Misc

  let totalTStates: UInt64
  let debuggerRunState: Debugger.RunState

  // MARK: - Memory windows

  /// Window of bytes read via Pc88Bus.memRead, centred near the
  /// current main PC. Used by the disassembly pane.
  let mainDisasmWindow: MemoryWindow

  /// Window of bytes read via SubBus.memRead, centred near the
  /// current sub PC. Used by the disassembly pane.
  let subDisasmWindow: MemoryWindow

  /// Arbitrary window for the hex viewer (user-controlled base).
  let hexWindow: MemoryWindow

  /// Empty placeholder used before the first poll completes.
  static let placeholder = MachineSnapshot(
    mainPC: 0, mainSP: 0,
    mainAF: 0, mainBC: 0, mainDE: 0, mainHL: 0,
    mainIX: 0, mainIY: 0,
    mainAF2: 0, mainBC2: 0, mainDE2: 0, mainHL2: 0,
    mainI: 0, mainR: 0,
    mainIff1: false, mainIff2: false, mainIM: 0, mainHalted: false,
    subPC: 0, subSP: 0,
    subAF: 0, subBC: 0, subDE: 0, subHL: 0,
    subIX: 0, subIY: 0,
    subAF2: 0, subBC2: 0, subDE2: 0, subHL2: 0,
    subI: 0, subR: 0,
    subHalted: false, subIff1: false, subIff2: false, subIM: 0,
    totalTStates: 0,
    debuggerRunState: .running,
    mainDisasmWindow: .empty,
    subDisasmWindow: .empty,
    hexWindow: .empty
  )
}

extension Debugger.RunState {
  /// Short label for status display.
  var displayLabel: String {
    switch self {
    case .running: return "RUNNING"
    case .paused(let reason):
      switch reason {
      case .userRequest:   return "PAUSED (User)"
      case .initialLaunch: return "PAUSED (Initial)"
      case .breakpoint:    return "PAUSED (Breakpoint)"
      case .watch:         return "PAUSED (Watch)"
      }
    }
  }
}

/// A contiguous slice of memory captured at snapshot time.
struct MemoryWindow: Sendable, Equatable {
  var baseAddress: UInt16
  var bytes: [UInt8]

  static let empty = MemoryWindow(baseAddress: 0, bytes: [])

  /// Returns the byte at the given absolute address, or `0xFF` if
  /// outside the captured window.
  func read(_ addr: UInt16) -> UInt8 {
    let offset = Int(addr) &- Int(baseAddress)
    guard offset >= 0, offset < bytes.count else { return 0xFF }
    return bytes[offset]
  }

  /// Whether `addr` falls inside the window.
  func contains(_ addr: UInt16) -> Bool {
    let offset = Int(addr) &- Int(baseAddress)
    return offset >= 0 && offset < bytes.count
  }
}
