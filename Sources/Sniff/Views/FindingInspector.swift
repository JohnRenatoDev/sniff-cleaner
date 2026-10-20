import SwiftUI
import SniffCore

struct FindingInspector: View {
    let item: Finding
    @Bindable var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                Image(systemName: item.category.symbol).font(.system(size: 26)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    Text(Display.title(item)).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Label(L(item.state.title), systemImage: item.state == .ready ? "checkmark.circle" : item.state == .inUse ? "hand.raised" : "lock")
                        .font(.callout)
                }
                Text(L(item.reason)).font(.callout).fixedSize(horizontal: false, vertical: true)
                Divider()
                info(L("Caminho"), item.path)
                if item.logicalBytes > 0 || item.allocatedBytes > 0 {
                    info(L("Tamanho lógico"), Display.bytes(item.logicalBytes))
                    info(item.partialMeasurement ? L("Alocado parcial (mínimo)") : L("Alocado estimado"), Display.bytes(item.allocatedBytes))
                    if item.sharedLinks || item.category == .signingClone { Text(L("Há blocos compartilhados ou hardlinks. O ganho pode ser menor.")).font(.caption).foregroundStyle(.secondary) }
                }
                info(L("Efeito da limpeza"), L(item.category.regeneration))
                if !item.details.isEmpty {
                    Divider()
                    ForEach(Array(item.details.enumerated()), id: \.offset) { _, detail in Text(L(detail)).font(.caption).textSelection(.enabled) }
                }
                if !item.path.hasPrefix("docker://") {
                    Divider()
                    Button(L("Mostrar no Finder")) { FolderPicker.reveal(item.path) }
                    Button(L("Sempre preservar este caminho")) { store.exclude(item.path) }.disabled(store.busy)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(23)
        }
    }
    private func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
