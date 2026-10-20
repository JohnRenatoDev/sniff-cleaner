import SwiftUI

@main
struct SniffInstallerApp: App {
    @NSApplicationDelegateAdaptor(InstallerDelegate.self) private var delegate
    @StateObject private var store = InstallerStore()
    var body: some Scene {
        WindowGroup("Install Sniff") { InstallerView(store: store).background { InstallerDelegateLink(store: store, delegate: delegate) } }
            .windowResizability(.contentSize).defaultPosition(.center)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class InstallerDelegate: NSObject, NSApplicationDelegate {
    weak var store: InstallerStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { store?.installing == true ? .terminateCancel : .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { store?.installing != true }
}

private struct InstallerDelegateLink: NSViewRepresentable {
    let store: InstallerStore
    let delegate: InstallerDelegate
    func makeNSView(context: Context) -> NSView { delegate.store = store; return NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {}
}
