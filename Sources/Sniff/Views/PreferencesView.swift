import SwiftUI
import SniffCore

struct PreferencesView: View {
    @Bindable var store: AppStore
    var body: some View {
        TabView {
            general.tabItem { Label(L("Geral"), systemImage: "globe") }
            categories.tabItem { Label(L("Limpeza"), systemImage: "slider.horizontal.3") }
            paths.tabItem { Label(L("Caminhos"), systemImage: "folder") }
            retention.tabItem { Label(L("Retenção"), systemImage: "calendar") }
        }.frame(width: 660, height: 560).padding(12).disabled(store.busy)
    }
    private var general: some View {
        Form {
            Section(L("Idioma")) {
                Picker(L("Idioma"), selection: Binding(get: { store.language }, set: { store.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                }
                Text(L("A troca de idioma vale na hora para as janelas, os avisos e o ícone da barra de menus. Datas e números seguem o idioma escolhido."))
                Text(L("Algumas ações de menus e janelas do macOS mudam de idioma ao reabrir o Sniff.")).foregroundStyle(.secondary)
                Text(L("Se o idioma do macOS não estiver disponível, o Sniff usa inglês.")).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var categories: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(L("O que o Sniff pode limpar")).font(.title3.weight(.semibold))
            Text(L("Habilite uma categoria para poder selecionar seus itens. A limpeza automática usa só categorias com arquivos que podem ser recriados.")).font(.callout).foregroundStyle(.secondary)
            List(Category.allCases) { category in
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(L(category.title), isOn: Binding(get: { store.state.preferences.enabledCategories.contains(category) }, set: { enabled in
                        if enabled { store.state.preferences.enabledCategories.insert(category) }
                        else { store.state.preferences.enabledCategories.remove(category); store.selected.subtract(store.findings.filter { $0.category == category }.map(\.id)) }
                        store.savePreferences()
                    })).disabled([.docker, .signingClone].contains(category))
                    Text(L(category.regeneration)).font(.caption).foregroundStyle(.secondary)
                    Text(category.allowsAutomatic ? L("Pode entrar na limpeza automática se habilitada") : L("Fora da limpeza automática")).font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical, 5)
            }
        }.padding(15)
    }
    private var paths: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(L("Pastas de projetos")).font(.headline); Spacer(); Button(L("Adicionar…")) {
                let values = FolderPicker.choose(title: L("Onde ficam seus projetos?"))
                store.state.preferences.projectRoots = Array(Set(store.state.preferences.projectRoots + values)).sorted(); store.savePreferences()
            } }
            Text(L("O Sniff procura repositórios em até 5 níveis de subpastas. Também consulta os registros do Git para encontrar worktrees fora dessas pastas.")).font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(store.state.preferences.projectRoots, id: \.self) { path in
                    HStack { Text(Display.path(path)).lineLimit(1).truncationMode(.middle); Spacer(); Button { store.state.preferences.projectRoots.removeAll { $0 == path }; store.savePreferences() } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel(L("Remover pasta de projetos {0}", path)) }
                }
            }.frame(height: 145)
            HStack { Text(L("Sempre preservar")).font(.headline); Spacer(); Button(L("Adicionar…")) {
                for path in FolderPicker.choose(title: L("Qual caminho o Sniff deve preservar?"), allowsFiles: true) { store.exclude(path) }
            } }
            Text(L("Se um caminho preservado estiver dentro de um item, o Sniff preserva o item inteiro. Configurações, sessões, credenciais e o runtime principal já são protegidos.")).font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(store.state.preferences.exclusions, id: \.self) { path in
                    HStack { Text(Display.path(path)).lineLimit(1).truncationMode(.middle); Spacer(); Button { store.state.preferences.exclusions.removeAll { $0 == path }; store.savePreferences() } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel(L("Remover exclusão {0}", path)) }
                }
            }
        }.padding(15)
    }
    private var retention: some View {
        Form {
            Section(L("Itens antigos")) {
                Stepper(L("Temporários, instaladores, npx e worktrees: {0} dias", store.state.preferences.retentionDays), value: $store.state.preferences.retentionDays, in: 1...180)
                    .onChange(of: store.state.preferences.retentionDays) { _, _ in store.savePreferences() }
                Stepper(L("Logs: {0} dias", store.state.preferences.logRetentionDays), value: $store.state.preferences.logRetentionDays, in: 7...365)
                    .onChange(of: store.state.preferences.logRetentionDays) { _, _ in store.savePreferences() }
                Text(L("Se algum arquivo foi modificado dentro desse prazo, o Sniff preserva o item inteiro. Caches comuns podem ser recriados e não dependem desse prazo.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Limites desta versão")) {
                Text(L("Worktrees exigem análise e seleção manual. Docker e clones de assinatura ficam apenas para inspeção. Nos projetos, o Sniff reconhece as compilações target do Rust e .build do SwiftPM."))
                Text(L("O Sniff limpa arquivos deixados pelas ferramentas. Isso não corrige vazamento de processos, concorrência do Codex ou kernel panic.")).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
