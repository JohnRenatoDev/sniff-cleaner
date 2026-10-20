import SwiftUI
import SniffCore
import SniffIdentity

struct SidebarView: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                SniffingDog().frame(width: 64, height: 48)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sniff").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text(L("Limpeza de caches e sobras")).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 15).padding(.top, 19).padding(.bottom, 21)
            List(selection: $store.section) {
                ForEach([AppSection.overview, .ready, .preserved]) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
                Section(L("Inspecionar")) {
                    ForEach([AppSection.worktrees, .docker]) { section in Label(section.title, systemImage: section.symbol).tag(section) }
                }
                Section {
                    ForEach([AppSection.schedule, .history]) { section in Label(section.title, systemImage: section.symbol).tag(section) }
                }
            }.listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 7) {
                Label(L("Seus dados ficam no Mac."), systemImage: "lock.shield").font(.caption)
                Text(L("A limpeza automática preserva código, sessões e bancos de dados.")).font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 218, max: 250)
    }
}
