import AppKit

/// Builds the menu shown when the Dock icon is right-clicked.
///
/// AppKit asks for the Dock menu every time it opens, so the menu is rebuilt
/// on each call and always reflects the current run state and recent lists.
/// It only calls existing view-model operations and gates them with the same
/// operation locks as the menu bar.
@MainActor
enum DockMenu {
  static func make(viewModel: EmulatorViewModel) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let canEmulate = viewModel.allows(.emulation)
    let pauseTitle = viewModel.isRunning
      ? String(localized: "Pause")
      : String(localized: "Resume")
    menu.addItem(actionItem(title: pauseTitle, enabled: canEmulate) {
      if viewModel.isRunning {
        viewModel.pause()
      } else {
        viewModel.resume()
      }
    })
    menu.addItem(actionItem(title: String(localized: "Reset"), enabled: canEmulate) {
      viewModel.reset()
    })

    menu.addItem(.separator())

    let canMount = viewModel.allows(.media)
    menu.addItem(recentSubmenu(String(localized: "Recent Disks"), kind: .disk, enabled: canMount) {
      viewModel.mountRecentFile($0)
    })
    menu.addItem(recentSubmenu(String(localized: "Recent Tapes"), kind: .tape, enabled: canMount) {
      viewModel.mountRecentTape($0)
    })
    menu.addItem(recentSubmenu(String(localized: "Recent CDs"), kind: .cd, enabled: canMount) {
      viewModel.mountRecentCD($0)
    })

    return menu
  }

  /// A recent-files submenu laid out like the menu bar's Recent Files: the
  /// entries, then an item that clears the list.
  private static func recentSubmenu(_ title: String,
                                    kind: Settings.RecentFileKind,
                                    enabled: Bool,
                                    open: @escaping (RecentDiskEntry) -> Void) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = enabled
    let submenu = NSMenu(title: title)
    submenu.autoenablesItems = false

    let entries = Settings.shared.recentFiles(kind)
    if entries.isEmpty {
      submenu.addItem(actionItem(title: String(localized: "No Recent Files"), enabled: false) {})
    } else {
      for entry in entries {
        let title = "\(entry.displayName) — \(entry.displayDir)"
        submenu.addItem(actionItem(title: title, enabled: enabled) {
          // Bring the window forward so the mounted media is visible.
          NSApp.activate()
          open(entry)
        })
      }
      submenu.addItem(.separator())
      let clearTitle = String(localized: "Clear Recent Files")
      submenu.addItem(actionItem(title: clearTitle, enabled: enabled) {
        Settings.shared.clearRecentFiles(kind: kind)
      })
    }
    item.submenu = submenu
    return item
  }
}

/// Makes a menu item that runs a closure, so the Dock menu needs no
/// responder-chain selectors. The item's `target` is weak, so the action
/// object is kept alive by `representedObject`.
@MainActor
private func actionItem(title: String, enabled: Bool,
                        handler: @escaping @MainActor () -> Void) -> NSMenuItem {
  let action = MenuAction(handler)
  let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
  item.target = action
  item.representedObject = action
  item.isEnabled = enabled
  return item
}

private final class MenuAction: NSObject {
  private let handler: @MainActor () -> Void

  init(_ handler: @escaping @MainActor () -> Void) {
    self.handler = handler
  }

  @objc func run() {
    MainActor.assumeIsolated { handler() }
  }
}
