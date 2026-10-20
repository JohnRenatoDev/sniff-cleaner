import SwiftUI
import SniffCore
import SniffIdentity

struct InstallerView: View {
    @Bindable var store: InstallerStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sniff").font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(ProductInfo.version).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker(store.text("Language"), selection: $store.language) {
                    Text("English").tag(AppLanguage.english)
                    Text("Português").tag(AppLanguage.portuguese)
                    Text("Español").tag(AppLanguage.spanish)
                    Text(store.text("Use macOS language")).tag(AppLanguage.system)
                }.labelsHidden().fixedSize().disabled(store.installing || store.result != nil)
            }.padding(.horizontal, 30).padding(.top, 24)
            HStack(spacing: 24) {
                SniffingDog(active: store.result == nil).frame(width: 210, height: 145)
                    .accessibilityLabel(store.text("Sniff, a dog sniffing and wagging its tail"))
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.text(store.result == nil ? "Install Sniff" : "Sniff is ready")).font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text(store.text(store.result == nil ? "Review development caches and temporary files before cleaning them up." : "Sniff is installed and ready to open.")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 30).padding(.vertical, 16)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                if let result = store.result {
                    Label(store.text("Installed successfully"), systemImage: "checkmark.circle.fill").font(.headline)
                    Text(store.displayPath(result.application.path)).font(.callout).textSelection(.enabled)
                    if let command = result.command {
                        Text(store.displayPath(command.path)).font(.caption).textSelection(.enabled)
                        Text(store.text("If your shell does not include this folder, add it to PATH:")).font(.caption).foregroundStyle(.secondary)
                        Text("export PATH=\"$HOME/.local/bin:$PATH\"").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.text("Install to")).font(.caption).foregroundStyle(.secondary)
                            Text(store.displayPath(store.destination.path)).lineLimit(1).truncationMode(.middle).font(.callout)
                        }
                        Spacer()
                        Button(store.text("Choose…")) { store.chooseFolder() }.disabled(store.installing)
                    }
                    Toggle(store.text("Install the sniff command"), isOn: $store.installCLI).disabled(store.installing)
                    Text(store.displayPath(store.commandPath)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(store.text("Your existing settings and scan history stay in place. No cleanup runs during installation.")).font(.caption).foregroundStyle(.secondary)
                }
                if store.installing { HStack(spacing: 10) { ProgressView().controlSize(.small); Text(store.activity).font(.callout) } }
                if let error = store.error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(30)
            Spacer(minLength: 0)
            Divider()
            HStack {
                if store.preview { Text(store.text("Preview build. Locally signed; not notarized by Apple.")).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: 370, alignment: .leading) }
                Spacer()
                if store.result != nil {
                    Button(store.text("Done")) { NSApp.terminate(nil) }
                    Button(store.text("Open Sniff")) { store.openApplication() }.buttonStyle(.borderedProminent)
                } else {
                    Button(store.text("Install Sniff")) { store.install() }.buttonStyle(.borderedProminent).disabled(store.installing)
                }
            }.controlSize(.large).padding(.horizontal, 30).padding(.vertical, 20)
        }.frame(width: 700, height: 530).environment(\.locale, store.language.locale)
    }
}
