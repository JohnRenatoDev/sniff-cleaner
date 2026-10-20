import SwiftUI
import SniffCore

struct HistoryView: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Histórico de limpeza")).font(.system(size: 27, weight: .semibold, design: .rounded))
            Text(L("Veja o que foi removido, o que foi preservado e quanto o espaço livre do volume mudou.")).foregroundStyle(.secondary)
            if store.state.history.isEmpty {
                Spacer()
                ContentUnavailableView(L("Nenhuma limpeza ainda"), systemImage: "clock.arrow.circlepath", description: Text(L("O resultado da próxima limpeza aparece aqui.")))
                Spacer()
            } else {
                List {
                    ForEach(Array(store.state.history.enumerated()), id: \.offset) { _, report in
                        Section(Display.date(report.date)) {
                            LabeledContent(L("Itens removidos"), value: L("{0} de {1}", report.outcomes.filter(\.removed).count, report.outcomes.count))
                            LabeledContent(L("Tamanho alocado removido"), value: Display.bytes(report.removedAllocated))
                            if let delta = report.netChange {
                                LabeledContent(L("Variação de espaço livre"), value: (delta >= 0 ? "+" : "−") + Display.bytes(abs(delta)))
                            } else { Text(L("Medida de espaço livre indisponível.")) }
                            Text(L("Outros apps também alteram o espaço livre. A soma dos arquivos removidos pode ser diferente dessa variação.")).font(.caption).foregroundStyle(.secondary)
                            ForEach(report.outcomes) { outcome in
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(Display.path(outcome.path), systemImage: outcome.removed ? "checkmark.circle" : "hand.raised").textSelection(.enabled)
                                    Text(L(outcome.message)).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }.listStyle(.inset)
            }
        }.padding(30)
    }
}
