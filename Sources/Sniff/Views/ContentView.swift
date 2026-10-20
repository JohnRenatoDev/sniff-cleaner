import SwiftUI
import SniffCore

struct ContentView: View {
    @Bindable var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            Group {
                switch store.section {
                case .schedule: ScheduleView(store: store)
                case .history: HistoryView(store: store)
                default: FindingsView(store: store)
                }
            }
            .navigationTitle(store.section.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { store.scan() } label: { Label(L("Analisar"), systemImage: "magnifyingglass") }
                        .keyboardShortcut("r", modifiers: .command).disabled(store.busy)
                        .help(L("Analisar caches, projetos, worktrees e containers sem remover arquivos"))
                }
            }
        }
        .frame(minWidth: 1040, minHeight: 670)
        .sheet(isPresented: $store.reviewing) { ReviewSheet(store: store) }
        .alert(L("O Sniff precisa da sua atenção"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L("Entendi"), role: .cancel) { store.error = nil }
        } message: { Text(L(store.error ?? "")) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { store.refresh() } }
        .onAppear { NativeMenuLocalization.update() }
    }
}
