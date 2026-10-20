import SwiftUI
import SniffCore

@main
enum SniffEntry {
    static func main() async {
        if CommandLine.arguments.contains("--scheduled") {
            let preferences = StateStore().load().preferences
            let announcesWork = SchedulePolicy.isDue(preferences)
            if announcesWork { ScheduledActivity.post(active: true, cleaning: preferences.scheduleMode == .automatic) }
            defer { if announcesWork { ScheduledActivity.post(active: false, cleaning: preferences.scheduleMode == .automatic) } }
            do {
                let message = try ScheduledRunner.run()
                if let message, StateStore().load().preferences.notificationsEnabled { await NotificationService.post(message) }
            } catch { FileHandle.standardError.write(Data("Sniff: \(error.localizedDescription)\n".utf8)) }
            return
        }
        SniffApp.main()
    }
}

struct SniffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()
    var body: some Scene {
        let _ = store.language
        WindowGroup("Sniff", id: "main") {
            ContentView(store: store)
                .environment(\.locale, store.language.locale).id(store.language)
                .background { MenuBarInstaller(store: store, delegate: delegate) }
        }
            .defaultSize(width: 1220, height: 790)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandMenu(L("Limpeza")) {
                    Button(L("Analisar este Mac")) { store.scan() }.keyboardShortcut("r", modifiers: .command).disabled(store.busy)
                    Button(L("Revisar limpeza…")) { store.reviewing = true }.disabled(store.busy || store.plan.isEmpty)
                    Button(L("Preservar um caminho…")) { for path in FolderPicker.choose(title: L("Preservar caminho"), allowsFiles: true) { store.exclude(path) } }.disabled(store.busy)
                }
            }
        Settings { PreferencesView(store: store).environment(\.locale, store.language.locale).id(store.language) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var menuBar: MenuBarController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NativeMenuLocalization.install()
    }
    func installMenuBar(store: AppStore, showWindow: @escaping () -> Void, showSettings: @escaping () -> Void) {
        guard menuBar == nil else { return }
        menuBar = MenuBarController(store: store, showWindow: showWindow, showSettings: showSettings)
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--validate-menu-bar"),
           CommandLine.arguments.indices.contains(index + 1), let menuBar {
            MenuBarValidation.run(store: store, controller: menuBar, reportURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        #endif
    }
    func applicationWillTerminate(_ notification: Notification) { menuBar?.invalidate() }
}
