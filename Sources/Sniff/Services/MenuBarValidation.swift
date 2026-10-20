#if DEBUG
import AppKit
import SniffCore

/// Exercises the real executor exclusively against fresh, disposable fixtures.
/// It never saves a scan, preference, or cleanup report in the user's store.
@MainActor
enum MenuBarValidation {
    static func run(store: AppStore, controller: MenuBarController, reportURL: URL) {
        guard !store.busy else { return }
        store.busy = true; store.canCancel = false; store.activity = "Validando a limpeza em arquivos temporários…"
        let initialFrames = controller.displayedAnimationFrames
        Task {
            do {
                let report = try await Task.detached(priority: .utility) {
                    let root = URL(fileURLWithPath: "/private/tmp/sniff-menu-bar-fixture-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: root) }
                    let catalog = RuleCatalog(home: root.path)
                    guard let rule = catalog.rule(id: "codex-install") else { throw SniffError.message("Regra de fixture indisponível.") }
                    let date = Date().addingTimeInterval(-40 * 86_400)
                    var inventory = ProcessInventory(); inventory.complete = true
                    var plan: [Finding] = []
                    for index in 0..<12 {
                        let folder = URL(fileURLWithPath: rule.base).appendingPathComponent("codex-runtime-install-fixture-\(index)")
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let file = folder.appendingPathComponent("fixture.bin")
                        try Data(repeating: 0x2A, count: 4_096).write(to: file)
                        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
                        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
                        plan.append(Scanner(catalog: catalog).inspect(path: folder.path, rule: rule, preferences: Preferences(), processes: inventory))
                    }
                    return CleaningExecutor(catalog: catalog).execute(plan: plan, scannedAt: .now, preferences: Preferences()) { message in
                        Task { @MainActor in store.activity = message }
                    }
                }.value
                store.busy = false; store.activity = ""
                try await Task.sleep(for: .milliseconds(150))
                let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let evidence: [String: Any] = [
                    "fixtureOnly": true,
                    "fixtures": report.outcomes.count,
                    "removedFixtures": report.outcomes.filter(\.removed).count,
                    "outcomes": report.outcomes.map { ["removed": $0.removed, "message": $0.message] },
                    "animationFramesDisplayed": controller.displayedAnimationFrames - initialFrames,
                    "timerStoppedWhenIdle": !controller.isAnimating,
                    "reduceMotion": reducedMotion,
                    "statusItem": controller.validationSnapshot()
                ]
                try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            } catch {
                store.busy = false; store.activity = ""
                store.error = "Validação do ícone: \(error.localizedDescription)"
            }
        }
    }
}
#endif
