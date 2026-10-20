import AppKit
import SniffCore

/// AppKit supplies these standard menus outside the SwiftUI locale environment.
@MainActor
enum NativeMenuLocalization {
    private static var observers: [any NSObjectProtocol] = []
    private static var updating = false
    private static let keys = [
        "About Sniff", "Settings…", "Services", "Hide Sniff", "Hide Others", "Show All", "Quit Sniff",
        "Edit", "Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All", "View", "Window", "Help",
        "Minimize", "Zoom", "Bring All to Front", "Enter Full Screen", "Exit Full Screen", "Show Sidebar", "Hide Sidebar"
    ]
    static func install() {
        guard observers.isEmpty else { return }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // Menu tracking has its own run-loop mode. Apply synchronously on the main
                // queue so labels update before tracking rather than after the menu closes.
                MainActor.assumeIsolated { update() }
            })
        }
        update()
    }
    static func update() {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        func localize(_ menu: NSMenu) {
            if let key = keys.first(where: { key in
                menu.title == key || Localization.catalogs.values.contains { $0[key] == menu.title }
            }) { menu.title = L(key) }
            for item in menu.items {
                if let key = keys.first(where: { key in
                    item.title == key || Localization.catalogs.values.contains { $0[key] == item.title }
                }) { item.title = L(key) }
                if let submenu = item.submenu { localize(submenu) }
            }
        }
        if let menu = NSApp.mainMenu { localize(menu) }
    }
}
