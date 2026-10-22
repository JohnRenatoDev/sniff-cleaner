import SwiftUI
import SniffCore

struct ScheduleView: View {
    @Bindable var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Escolha quando analisar ou limpar")).font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text(L("O macOS executa o Sniff em segundo plano. Escolha se ele só analisa ou também limpa os caches permitidos.")).foregroundStyle(.secondary)
                }
                Form {
                    Section {
                        Toggle(L("Ativar agendamento"), isOn: Binding(get: { store.state.preferences.scheduleEnabled }, set: { store.state.preferences.scheduleEnabled = $0; store.applySchedule() }))
                        Picker(L("O que fazer"), selection: $store.state.preferences.scheduleMode) {
                            ForEach(ScheduleMode.allCases, id: \.self) { mode in Text(L(mode.title)).tag(mode) }
                        }.onChange(of: store.state.preferences.scheduleMode) { _, _ in store.applySchedule() }
                        Picker(L("Frequência"), selection: $store.state.preferences.intervalHours) {
                            Text(L("A cada 6 horas")).tag(6); Text(L("Todo dia")).tag(24); Text(L("Toda semana")).tag(168)
                        }.onChange(of: store.state.preferences.intervalHours) { _, _ in store.applySchedule() }
                        LabeledContent(L("Próxima execução"), value: store.state.preferences.scheduleEnabled ? (store.scheduleStatus == "Registrado no macOS" ? Display.date(store.state.preferences.nextRun) : L("Pendente de registro no macOS")) : L("Desativada"))
                        LabeledContent(L("Registro do sistema"), value: L(store.scheduleStatus))
                        if store.needsApproval { Button(L("Permitir nos Ajustes do Sistema…")) { SchedulerService.openSettings() } }
                    } footer: {
                        Text(L("O agendamento funciona com seu usuário conectado e o Mac acordado. O Sniff verifica a cada 15 minutos se há uma tarefa agendada. Ela pode atrasar após repouso, logout ou durante compilações. Mantenha o app nesta pasta. O Sniff executa as tarefas sem privilégios de administrador."))
                    }
                    Section(L("Monitoramento leve")) {
                        Toggle(L("Observar mudanças nos caches"), isOn: Binding(get: { store.state.preferences.monitorEnabled }, set: { store.state.preferences.monitorEnabled = $0; store.applySchedule() }))
                        Text(L("A cada 6 horas, o Sniff compara os metadados das pastas conhecidas. Essa verificação não percorre as subpastas para medir tamanhos nem faz análises constantes.")).font(.caption).foregroundStyle(.secondary)
                        if let date = store.state.preferences.lastMonitor {
                            LabeledContent(L("Última observação"), value: Display.date(date))
                            Text(L("{0} pastas mudaram desde a análise. Analise novamente para medir o tamanho.", store.state.monitorChangedPaths.count)).font(.caption)
                        }
                        Toggle(L("Receber notificações do Sniff"), isOn: Binding(get: { store.state.preferences.notificationsEnabled }, set: { store.setNotifications($0) }))
                    }
                    Section(L("O que pode ser limpo automaticamente")) {
                        Text(L("A limpeza automática usa só caches que podem ser recriados, nas categorias habilitadas nos Ajustes. Worktrees, VMs, compilações, ambientes npx e logs exigem seleção manual. Docker e clones de assinatura ficam apenas para inspeção."))
                        Text(L("Análises agendadas cobrem os caches conhecidos. A análise manual inclui projetos, worktrees e Docker.")).font(.caption).foregroundStyle(.secondary)
                        SettingsLink { Text(L("Escolher categorias…")) }
                    }
                    if let message = store.state.schedulerMessage {
                        Section(L("Última atividade em segundo plano")) {
                            Text(L(message))
                            if let date = store.state.schedulerLastWake { LabeledContent(L("Última verificação do agendamento"), value: Display.date(date)) }
                        }
                    }
                }.formStyle(.grouped)
            }.frame(maxWidth: 790, alignment: .leading).padding(30)
        }.disabled(store.busy).onAppear { store.refreshSchedule() }
    }
}
