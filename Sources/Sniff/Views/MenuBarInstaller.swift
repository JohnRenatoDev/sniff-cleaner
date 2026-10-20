import SwiftUI

struct MenuBarInstaller: View {
    let store: AppStore
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            delegate.installMenuBar(store: store, showWindow: { openWindow(id: "main") }, showSettings: { openSettings() })
        }
    }
}
