import SwiftUI
import SniffCore
import SniffIdentity

struct FindingsView: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            header
            if store.state.lastScan == nil && !store.busy {
                Spacer()
                ContentUnavailableView {
                    Label(L("Faça a primeira análise"), systemImage: "magnifyingglass")
                } description: {
                    Text(L("O Sniff procura sobras conhecidas de ferramentas e agentes.\nVocê revisa cada caminho antes de limpar."))
                } actions: {
                    Button(L("Analisar este Mac")) { store.scan() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                Spacer()
            } else {
                Divider()
                HStack(spacing: 0) {
                    findingsList
                    if let focused = store.focused {
                        Divider()
                        FindingInspector(item: focused, store: store).id(focused.id).frame(width: 277)
                    }
                }
            }
            Divider()
            footer
        }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.busy ? L("Farejando…") : store.state.lastScan == nil ? L("Veja o que dá para limpar") : L("Escolha o que quer limpar"))
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                if store.busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L(store.activity)).foregroundStyle(.secondary)
                        if store.canCancel { Button(L("Cancelar")) { store.cancelScan() }.buttonStyle(.link) }
                    }
                } else if let date = store.state.lastScan?.date {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Display.bytes(store.readyBytes)).font(.system(size: 24, weight: .medium)).monospacedDigit()
                        Text(store.readyCount == 1 ? L("estimados em 1 item que pode ser limpo") : L("estimados em {0} itens que podem ser limpos", Display.number(store.readyCount))).foregroundStyle(.secondary)
                    }
                    Text(L("Última análise: {0}", Display.date(date))).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("Encontre caches e arquivos temporários de ferramentas e agentes."))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            SniffingDog(active: store.busy).frame(width: 140, height: 95).padding(.trailing, 10)
        }.padding(.horizontal, 30).padding(.vertical, 27)
    }
    private var findingsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.section == .overview ? L("Resultados da análise") : store.section.title).font(.headline)
                Text(Display.number(store.visible.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.section == .worktrees {
                    Button(L("Analisar worktrees")) { store.scan(worktreesOnly: true) }.disabled(store.busy)
                }
                Menu {
                    Button(L("Selecionar caches permitidos")) { store.selectRecommended() }
                    Button(L("Desmarcar tudo")) { store.selected.removeAll() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().disabled(store.busy)
            }.padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 10)
            if store.section == .worktrees {
                Picker(L("Filtrar worktrees"), selection: $store.worktreeFilter) {
                    ForEach(WorktreeFilter.allCases) { filter in Text(filter.title).tag(filter) }
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 10)
                Text(L("Worktrees em uso, com alterações, dados locais ou commits pendentes são preservadas."))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            TextField(L("Filtrar por ferramenta ou caminho"), text: $store.search)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 20).padding(.bottom, 12)
                .accessibilityLabel(L("Filtrar resultados"))
            List(selection: $store.focusedPath) {
                ForEach(store.visible) { item in
                    FindingRow(item: item, store: store).tag(item.id)
                        .contextMenu {
                            if !item.path.hasPrefix("docker://") {
                                Button(L("Mostrar no Finder")) { FolderPicker.reveal(item.path) }
                                Button(L("Preservar este caminho")) { store.exclude(item.path) }
                            }
                        }
                }
            }.listStyle(.inset).overlay {
                if store.visible.isEmpty && !store.busy { ContentUnavailableView(L("Nenhum item aqui"), systemImage: "checkmark", description: Text(L("A análise pode encontrar itens em outras seções."))) }
            }
            if let notice = store.state.lastScan?.notices.first, !store.busy {
                Text(L(notice)).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
        }.frame(minWidth: 340)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !store.plan.isEmpty {
                    Text(L(store.plan.count == 1 ? "{0} selecionado · {1} estimados" : "{0} selecionados · {1} estimados", Display.items(store.plan.count), Display.bytes(store.selectedBytes))).font(.callout.weight(.medium))
                    Text(L("Você revisa os caminhos no próximo passo.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("Nada será removido sem sua escolha.")).font(.callout)
                    Text(L("Última limpeza: {0}", Display.date(store.state.history.first?.date))).font(.caption).foregroundStyle(.secondary)
                }
                if let delta = store.state.history.first?.netChange {
                    Text(L("Variação de espaço livre: {0}{1}", delta >= 0 ? "+" : "−", Display.bytes(abs(delta)))).font(.caption).foregroundStyle(.secondary)
                }
                if store.state.preferences.scheduleEnabled {
                    Text(store.scheduleStatus == "Registrado no macOS" ? L("Próximo agendamento: {0}", Display.date(store.state.preferences.nextRun)) : L("Agendamento aguarda registro no macOS")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(L("Revisar limpeza…")) { store.reviewing = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(store.busy || store.plan.isEmpty)
        }.padding(.horizontal, 26).padding(.vertical, 17)
    }
}

private struct FindingRow: View {
    let item: Finding
    @Bindable var store: AppStore
    var body: some View {
        HStack(spacing: 11) {
            Toggle(L("Selecionar {0}", Display.title(item)), isOn: Binding(get: { store.selected.contains(item.id) }, set: { store.select(item, enabled: $0) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(item.state != .ready || store.busy)
            Image(systemName: item.category.symbol).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 23)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Display.title(item)).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(item.manifest.isEmpty && item.allocatedBytes == 0 ? "—" : (item.partialMeasurement ? "≥ " : "") + Display.bytes(item.allocatedBytes)).monospacedDigit().font(.callout)
                }
                Text(Display.path(item.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(L(item.state.title)).font(.caption2).foregroundStyle(item.state == .ready ? Color.secondary : Color.primary.opacity(0.65))
            }
        }.padding(.vertical, 7).contentShape(Rectangle())
    }
}
