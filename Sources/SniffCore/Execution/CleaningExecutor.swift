import Foundation

public struct CleaningExecutor: Sendable {
    public var catalog: RuleCatalog
    private let useCheck: @Sendable (Finding) -> String?
    public init(catalog: RuleCatalog = .init(), useCheck: (@Sendable (Finding) -> String?)? = nil) {
        self.catalog = catalog
        self.useCheck = useCheck ?? { finding in
            let inventory = ProcessInventory.capture()
            let tokens = catalog.rule(id: finding.ruleID)?.processTokens ?? ["rustc", "swift-frontend", "xcodebuild", "cargo build", "swift build"]
            return inventory.reason(path: finding.path, tokens: tokens)
        }
    }
    public func execute(plan: [Finding], scannedAt: Date, preferences: Preferences, automatic: Bool = false, progress: @Sendable (String) -> Void = { _ in }) -> CleaningReport {
        var report = CleaningReport()
        report.availableBefore = FileTree.available(catalog.home)
        var acceptedPaths: [String] = []
        for finding in plan {
            progress("Limpando \(finding.title)…")
            var outcome = RemovalOutcome(path: finding.path, removed: false, message: "Preservado.", allocatedBytes: 0)
            do {
                try Task.checkCancellation()
                guard Date().timeIntervalSince(scannedAt) < 900, Date().timeIntervalSince(scannedAt) >= -30 else { throw SniffError.message("A análise venceu. Analise novamente antes de limpar.") }
                guard finding.state == .ready, !finding.manifest.isEmpty, catalog.validates(finding, preferences: preferences) else { throw SniffError.message("Item fora das regras de remoção reconhecidas.") }
                guard preferences.enabledCategories.contains(finding.category), !automatic || finding.category.allowsAutomatic else { throw SniffError.message("Categoria não autorizada para esta limpeza.") }
                guard !acceptedPaths.contains(where: { FileTree.contains($0, finding.path) || FileTree.contains(finding.path, $0) }) else { throw SniffError.message("Item duplicado ou contido em outro item do plano.") }
                if let reason = catalog.protectedReason(finding.path, preferences: preferences) { throw SniffError.message(reason) }
                let current = try FileTree.read(finding.path)
                guard current == finding.manifest else { throw SniffError.message("Conteúdo mudou desde a análise. Preservado; analise novamente.") }
                if finding.category == .npx && NpxPolicy.mustPreserve(finding.path) {
                    throw SniffError.message("Ambiente npx com MCP ou conteúdo não verificável. Item preservado.")
                }
                if [.npx, .runtimeInstall, .installer, .logs].contains(finding.category) {
                    let days = finding.category == .logs ? preferences.logRetentionDays : preferences.retentionDays
                    let cutoff = Date().addingTimeInterval(-Double(max(days, 1)) * 86_400).timeIntervalSince1970
                    guard !current.contains(where: { Double($0.stamp.modifiedSeconds) > cutoff }) else { throw SniffError.message("Retenção alterada ou item recente. Preservado.") }
                }
                if let reason = useCheck(finding) { throw SniffError.message(reason) }
                // Usage checks can take time. Revalidate again immediately before unlinking.
                guard try FileTree.read(finding.path) == finding.manifest else { throw SniffError.message("Item mudou durante a verificação de uso. Preservado.") }
                acceptedPaths.append(finding.path)
                try SecureRemoval.remove(path: finding.path, manifest: finding.manifest)
                outcome.removed = true; outcome.allocatedBytes = FileTree.sizes(current).allocated; outcome.message = "Removido após revalidação."
            } catch let partial as SecureRemoval.PartialFailure {
                outcome.partiallyRemoved = true; outcome.allocatedBytes = partial.allocatedBytes
                outcome.message = "Limpeza parcial. Alguns arquivos foram removidos; analise novamente. " + partial.reason
            } catch is CancellationError { outcome.message = "Cancelado; item preservado." }
            catch { outcome.message = error.localizedDescription }
            report.outcomes.append(outcome)
        }
        report.availableAfter = FileTree.available(catalog.home)
        return report
    }
}
