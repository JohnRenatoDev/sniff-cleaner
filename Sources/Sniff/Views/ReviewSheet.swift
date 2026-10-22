import SwiftUI
import SniffCore
import SniffIdentity

struct ReviewSheet: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Revise antes de limpar")).font(.title2.weight(.semibold))
                    Text(L("{0} · {1} alocados estimados", Display.items(store.plan.count), Display.bytes(store.selectedBytes))).foregroundStyle(.secondary)
                }
                Spacer()
                SniffingDog().frame(width: 100, height: 65)
            }
            Text(L("O Sniff vai remover os caminhos abaixo definitivamente. Você pode precisar baixar dependências ou compilar de novo. Antes de remover, o Sniff verifica cada item e preserva os que mudaram ou estão em uso."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if store.plan.contains(where: { $0.category == .worktree }) {
                Text(L("A pasta local da worktree será removida. O Sniff mantém os branches e o repositório principal."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            List(store.plan) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(Display.title(item)).fontWeight(.medium); Spacer(); Text(Display.bytes(item.allocatedBytes)).monospacedDigit() }
                    Text(item.path).font(.caption).textSelection(.enabled)
                    Text(L(item.category.regeneration)).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 5)
            }.frame(minHeight: 200, maxHeight: 340)
            Text(L("O Sniff vai medir a mudança no espaço livre do volume. O resultado pode ser diferente da soma acima por causa do APFS, dos snapshots e da atividade de outros apps.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Voltar"), role: .cancel) { store.reviewing = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Remover {0}", Display.items(store.plan.count)), role: .destructive) { store.cleanReviewedPlan() }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 650)
    }
}
