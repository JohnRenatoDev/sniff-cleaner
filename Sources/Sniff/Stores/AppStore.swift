import SwiftUI
import Observation
import Combine
import SniffCore

@Observable @MainActor
final class AppStore: ObservableObject {
    var state: PersistedState
    var selected = Set<String>()
    var focusedPath: String?
    var section: AppSection = .overview
    var search = ""
    var busy = false
    var canCancel = false
    var activity = ""
    var error: String?
    var reviewing = false
    var lastReport: CleaningReport?
    var scheduleStatus = "Desativado"
    var needsApproval = false
    var language = LanguagePreference.load()
    private let disk = StateStore()
    private var work: Task<Void, Never>?
    init() {
        state = PersistedState()
        do { state = try disk.loadValidated() } catch { self.error = error.localizedDescription }
        if state.preferences.projectRoots.isEmpty {
            let code = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code").path
            if FileManager.default.fileExists(atPath: code), state.lastScan == nil { state.preferences.projectRoots = [code] }
        }
        if error == nil, let lock = try? disk.lock() { try? disk.save(state); withExtendedLifetime(lock) {} }
        applyExclusions()
        refreshSchedule()
    }
    var findings: [Finding] { state.lastScan?.findings ?? [] }
    var visible: [Finding] {
        findings.filter { item in
            let sectionMatches: Bool
            switch section {
            case .overview: sectionMatches = true
            case .ready: sectionMatches = item.state == .ready
            case .preserved: sectionMatches = item.state != .ready
            case .worktrees: sectionMatches = item.category == .worktree || item.category == .build
            case .docker: sectionMatches = item.category == .docker
            case .schedule, .history: sectionMatches = false
            }
            return sectionMatches && (search.isEmpty || L(item.title).localizedCaseInsensitiveContains(search) || item.path.localizedCaseInsensitiveContains(search) || L(item.category.title).localizedCaseInsensitiveContains(search))
        }
    }
    var plan: [Finding] { findings.filter { selected.contains($0.id) && $0.state == .ready && state.preferences.enabledCategories.contains($0.category) } }
    var selectedBytes: Int64 { plan.reduce(0) { $0 + $1.allocatedBytes } }
    var readyBytes: Int64 { findings.filter { $0.state == .ready }.reduce(0) { $0 + $1.allocatedBytes } }
    var readyCount: Int { findings.filter { $0.state == .ready }.count }
    var focused: Finding? { visible.first { $0.path == focusedPath } ?? visible.first }
    func select(_ item: Finding, enabled: Bool) {
        guard item.state == .ready else { return }
        if enabled { selected.insert(item.id); state.preferences.enabledCategories.insert(item.category); savePreferences() }
        else { selected.remove(item.id) }
    }
    func selectRecommended() {
        selected = Set(findings.filter { $0.state == .ready && $0.category.allowsAutomatic && state.preferences.enabledCategories.contains($0.category) }.map(\.id))
    }
    func savePreferences() {
        do {
            let lock = try disk.lock(); defer { withExtendedLifetime(lock) {} }
            var current = disk.load(); current.preferences = state.preferences
            try disk.save(current); state = current; applyExclusions()
        } catch { self.error = error.localizedDescription }
    }
    func refresh() {
        guard !busy else { return }
        language = LanguagePreference.load()
        do { state = try disk.loadValidated(); applyExclusions(); refreshSchedule() }
        catch { self.error = error.localizedDescription }
    }
    func setLanguage(_ language: AppLanguage) {
        LanguagePreference.save(language)
        self.language = language
        NativeMenuLocalization.update()
    }
    func scan() {
        guard !busy else { return }
        busy = true; canCancel = true; activity = "Começando a farejar…"; selected.removeAll(); error = nil
        let disk = disk
        work = Task { [self] in
            do {
                let background = Task.detached(priority: .utility) { [weak self] in
                    let lock = try disk.lock(); defer { withExtendedLifetime(lock) {} }
                    var latest = try disk.loadValidated()
                    let result = try Scanner().scan(preferences: latest.preferences) { message in Task { @MainActor in self?.activity = message } }
                    latest.lastScan = result
                    try disk.save(latest)
                    return result
                }
                let snapshot = try await withTaskCancellationHandler { try await background.value } onCancel: { background.cancel() }
                state = disk.load(); state.lastScan = snapshot
                if let first = visible.first { focusedPath = first.id }
            } catch is CancellationError { activity = "Análise cancelada." }
            catch { self.error = error.localizedDescription }
            busy = false; canCancel = false; activity = ""; work = nil
        }
    }
    func cleanReviewedPlan() {
        guard !busy, let scan = state.lastScan, !plan.isEmpty else { return }
        let approved = plan; let disk = disk
        reviewing = false; busy = true; activity = "Conferindo os itens escolhidos antes de remover…"; error = nil
        work = Task { [self] in
            do {
                let report = try await Task.detached(priority: .utility) { [weak self] in
                    let lock = try disk.lock(); defer { withExtendedLifetime(lock) {} }
                    var latest = try disk.loadValidated()
                    let result = CleaningExecutor().execute(plan: approved, scannedAt: scan.date, preferences: latest.preferences) { message in Task { @MainActor in self?.activity = message } }
                    latest.apply(result)
                    try disk.save(latest)
                    return result
                }.value
                state = disk.load(); lastReport = report; selected.removeAll(); section = .history
            } catch { self.error = error.localizedDescription }
            busy = false; activity = ""; work = nil
        }
    }
    func cancelScan() { if canCancel { work?.cancel() } }
    func exclude(_ path: String) {
        if !state.preferences.exclusions.contains(path) { state.preferences.exclusions.append(path) }
        selected.remove(path)
        savePreferences()
    }
    private func applyExclusions() {
        guard var snapshot = state.lastScan else { return }
        let catalog = RuleCatalog()
        for index in snapshot.findings.indices {
            if let reason = catalog.protectedReason(snapshot.findings[index].path, preferences: state.preferences) {
                snapshot.findings[index].state = .protected; snapshot.findings[index].reason = reason
                selected.remove(snapshot.findings[index].id)
            }
        }
        state.lastScan = snapshot
    }
    func refreshSchedule() {
        let status = SchedulerService.status()
        scheduleStatus = status.title; needsApproval = status.approval
    }
    func applySchedule() {
        state.preferences.nextRun = SchedulePolicy.nextDate(hours: state.preferences.intervalHours)
        savePreferences()
        do {
            try SchedulerService.setEnabled(state.preferences.scheduleEnabled || state.preferences.monitorEnabled)
            refreshSchedule()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.refresh()
            }
        } catch { self.error = "O macOS não registrou o agendador: \(error.localizedDescription)"; refreshSchedule() }
    }
    func setNotifications(_ enabled: Bool) {
        state.preferences.notificationsEnabled = enabled; savePreferences()
        if enabled { NotificationService.requestPermission { [weak self] allowed in
            if !allowed { self?.error = "Notificações não autorizadas pelo macOS. Os resultados continuam no Sniff." }
        } }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview, ready, preserved, worktrees, docker, schedule, history
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: L("Visão geral"); case .ready: L("Pode limpar"); case .preserved: L("Preservado"); case .worktrees: L("Projetos e worktrees"); case .docker: "Docker / OrbStack"; case .schedule: L("Agendamento"); case .history: L("Histórico") }
    }
    var symbol: String {
        switch self { case .overview: "square.grid.2x2"; case .ready: "sparkle"; case .preserved: "lock"; case .worktrees: "arrow.triangle.branch"; case .docker: "shippingbox"; case .schedule: "clock"; case .history: "clock.arrow.circlepath" }
    }
}
