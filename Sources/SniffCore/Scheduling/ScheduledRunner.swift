import Foundation

public enum ScheduledRunner {
    @discardableResult
    public static func run(store: StateStore = .init(), fixture: Bool = false) throws -> String? {
        let lock = try store.lock()
        defer { withExtendedLifetime(lock) {} }
        var state = try store.loadValidated()
        state.schedulerLastWake = .now
        if fixture {
            state.schedulerMessage = "Helper executado por launchd em fixture; nenhuma limpeza."
            try store.save(state); return state.schedulerMessage
        }
        let catalog = RuleCatalog()
        if state.preferences.monitorEnabled && Date().timeIntervalSince(state.preferences.lastMonitor ?? .distantPast) > 21_600 {
            state.monitorChangedPaths = SchedulePolicy.changedRoots(snapshot: state.lastScan, catalog: catalog)
            state.preferences.lastMonitor = .now
        }
        guard SchedulePolicy.isDue(state.preferences) else { try store.save(state); return nil }
        let processes = ProcessInventory.capture()
        if processes.buildInProgress || !processes.complete {
            state.schedulerMessage = "Adiado: compilação ativa ou verificação de processos incompleta."
            state.preferences.nextRun = .now.addingTimeInterval(3_600)
            try store.save(state); return nil
        }
        let snapshot = try Scanner(catalog: catalog).scan(preferences: state.preferences, deep: false)
        state.lastScan = snapshot
        if state.preferences.scheduleMode == .automatic {
            let plan = snapshot.findings.filter { $0.state == .ready && $0.category.allowsAutomatic && state.preferences.enabledCategories.contains($0.category) }
            let report = CleaningExecutor(catalog: catalog).execute(plan: plan, scannedAt: snapshot.date, preferences: state.preferences, automatic: true)
            state.apply(report)
            let removed = Set(report.outcomes.filter(\.removed).map(\.path))
            state.schedulerMessage = "Limpeza agendada: \(removed.count) itens removidos. Consulte o histórico."
        } else {
            let count = snapshot.findings.filter { $0.state == .ready }.count
            state.schedulerMessage = "Análise agendada concluída: \(count) itens podem ser revisados no Sniff."
        }
        state.preferences.nextRun = SchedulePolicy.nextDate(hours: state.preferences.intervalHours)
        try store.save(state)
        return state.schedulerMessage
    }
}
