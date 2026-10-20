import Foundation

public struct Scanner: Sendable {
    public let catalog: RuleCatalog
    public init(catalog: RuleCatalog = .init()) { self.catalog = catalog }
    public func scan(preferences: Preferences, deep: Bool = true, progress: @Sendable (String) -> Void = { _ in }) throws -> ScanSnapshot {
        var snapshot = ScanSnapshot()
        progress("Verificando processos em uso…")
        let processes = ProcessInventory.capture()
        if !processes.complete { snapshot.notices.append("O Sniff não conseguiu verificar todos os processos e preservou os arquivos.") }
        for rule in catalog.rules {
            try Task.checkCancellation()
            progress("Farejando \(rule.category.title)…")
            guard FileManager.default.fileExists(atPath: rule.base) || access(rule.base, F_OK) == 0 else {
                if errno == EACCES || errno == EPERM { snapshot.notices.append("Sem acesso: \(rule.base)") }
                continue
            }
            if FileTree.hasSymlinkAncestor(rule.base) {
                snapshot.findings.append(.init(path: rule.base, title: URL(fileURLWithPath: rule.base).lastPathComponent, category: rule.category, ruleID: rule.id, state: .protected, reason: "Caminho com link simbólico preservado."))
                continue
            }
            do {
                let targets: [String]
                switch rule.layout {
                case .whole: targets = [rule.base]
                case .children(let prefix): targets = try FileManager.default.contentsOfDirectory(atPath: rule.base).sorted().filter { $0.hasPrefix(prefix) }.map { rule.base + "/" + $0 }
                case .logs:
                    targets = try FileTree.read(rule.base, limit: 15_000).filter { !$0.stamp.isDirectory && $0.relativePath.hasSuffix(".log") }.map { rule.base + "/" + $0.relativePath }
                }
                for target in targets {
                    try Task.checkCancellation()
                    snapshot.findings.append(inspect(path: target, rule: rule, preferences: preferences, processes: processes))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { snapshot.findings.append(.init(path: rule.base, title: rule.category.title, category: rule.category, ruleID: rule.id, state: .inaccessible, reason: error.localizedDescription)) }
        }
        if deep {
            progress("Conferindo projetos e worktrees…")
            let repositories = ProjectInspector.discover(roots: preferences.projectRoots + [catalog.home + "/.codex/worktrees", catalog.home + "/.claude/worktrees"], notices: &snapshot.notices)
            snapshot.findings += try ProjectInspector.inspect(repositories: repositories, preferences: preferences, processes: processes, catalog: catalog, progress: progress)
            progress("Conferindo Docker / OrbStack…")
            snapshot.findings += DockerInspector.inspect(notices: &snapshot.notices)
            progress("Conferindo clones de assinatura…")
            snapshot.findings += SigningCloneInspector.inspect(processes: processes, preferences: preferences, notices: &snapshot.notices)
        }
        snapshot.findings.sort { lhs, rhs in
            if lhs.state == .ready && rhs.state != .ready { return true }
            if rhs.state == .ready && lhs.state != .ready { return false }
            return lhs.allocatedBytes > rhs.allocatedBytes
        }
        snapshot.notices.append("Tamanhos alocados são estimativas. APFS, hardlinks, snapshots e outras aplicações podem alterar o ganho líquido.")
        snapshot.notices.append("Uso verificado apenas entre processos visíveis ao seu usuário. O Sniff não encerra aplicações.")
        return snapshot
    }
    public func inspect(path: String, rule: CleaningRule, preferences: Preferences, processes: ProcessInventory) -> Finding {
        var finding = Finding(path: path, title: rule.layoutTitle(path), category: rule.category, ruleID: rule.id, state: .ready, reason: "Este caminho está nas regras de limpeza. O Sniff vai conferir o item de novo antes de remover.")
        do {
            if let reason = catalog.protectedReason(path, preferences: preferences) { finding.state = .protected; finding.reason = reason }
            let manifest = try FileTree.read(path)
            finding.manifest = manifest
            let size = FileTree.sizes(manifest)
            finding.logicalBytes = size.logical; finding.allocatedBytes = size.allocated; finding.sharedLinks = size.shared
            if finding.state == .protected { return finding }
            if let reason = processes.reason(path: path, tokens: rule.processTokens) { finding.state = .inUse; finding.reason = reason; return finding }
            if [.npx, .runtimeInstall, .installer, .logs].contains(rule.category) {
                let days = rule.category == .logs ? preferences.logRetentionDays : preferences.retentionDays
                let cutoff = Date().addingTimeInterval(-Double(max(days, 1)) * 86_400).timeIntervalSince1970
                if manifest.contains(where: { Double($0.stamp.modifiedSeconds) > cutoff }) {
                    finding.state = .protected; finding.reason = "O item teve alterações nos últimos \(days) dias e foi preservado."; return finding
                }
            }
            if rule.category == .npx && containsMCP(path) {
                finding.state = .protected; finding.reason = "Este ambiente contém um pacote MCP. O Sniff o preserva mesmo sem um servidor visível em execução."
            }
            if rule.category == .claudeVM { finding.reason = "Você precisa selecionar esta imagem manualmente. O Claude pode reinstalá-la e vai reconstruir a VM no próximo uso." }
        } catch { finding.state = .inaccessible; finding.reason = error.localizedDescription; finding.manifest = [] }
        return finding
    }
    private func containsMCP(_ path: String) -> Bool {
        let lock = URL(fileURLWithPath: path + "/package-lock.json")
        if let data = try? Data(contentsOf: lock), data.count < 8_000_000, let text = String(data: data, encoding: .utf8) {
            return text.localizedCaseInsensitiveContains("mcp") || text.contains("@modelcontextprotocol")
        }
        // An unrecognized npx environment cannot be proven disposable.
        return true
    }
}

private extension CleaningRule {
    func layoutTitle(_ path: String) -> String {
        switch layout { case .whole: category.title; default: URL(fileURLWithPath: path).lastPathComponent }
    }
}
