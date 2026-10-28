import Foundation

/// Recognizes Cargo's debug profiles without executing Cargo, manifests or build scripts.
public enum RustBuildInspector {
    static let ruleID = "rust-debug"
    static let processTokens = ["cargo ", "/cargo", "rustc", "rustdoc", "rust-analyzer"]
    private static let skipped: Set<String> = [
        ".git", ".cargo", "target", "node_modules", ".build", "vendor", ".venv", "venv",
        "dist", "build", "Library", ".cache", ".next", ".nuxt", "coverage"
    ]
    private static let localDataNames: Set<String> = [".git", ".env", ".ssh", ".aws", ".claude", ".codex", ".cargo", ".config", "credentials", "credentials.json", "settings.json", "config.json", ".npmrc", ".mcp.json", "Cargo.toml", "Cargo.lock"]
    private static let dataExtensions: Set<String> = ["db", "sqlite", "sqlite3", "duckdb", "mdb", "sql", "p12", "pfx", "pem", "key", "keystore"]
    private static let configurationExtensions: Set<String> = ["yaml", "yml", "ini", "config", "cfg", "env"]
    private static let sourceExtensions: Set<String> = ["rs", "swift", "py", "js", "ts", "tsx", "jsx", "c", "h", "cpp", "hpp", "sh", "toml"]

    /// Git roots can contain standalone ports or workspace members several levels down.
    /// Keep the existing repository discovery bounded, and never descend into build outputs.
    static func discover(roots: [String], notices: inout [String], directoryLimit: Int = 7_000, depthLimit: Int = 5) -> [String] {
        var queue = roots.sorted().map { ($0, 0) }
        var cursor = 0; var visited = Set<String>(); var projects = Set<String>()
        while cursor < queue.count, visited.count < directoryLimit {
            if Task.isCancelled { break }
            let (path, depth) = queue[cursor]; cursor += 1
            guard !FileTree.hasSymlinkAncestor(path), let stamp = try? FileTree.stamp(path), stamp.isDirectory,
                  visited.insert(path).inserted else { continue }
            if regularFile(path + "/Cargo.toml") { projects.insert(path) }
            guard depth < depthLimit else { continue }
            do {
                for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() {
                    guard !skipped.contains(name), !name.hasPrefix(".") else { continue }
                    let child = path + "/" + name
                    guard let info = try? FileTree.stamp(child), info.isDirectory, info.device == stamp.device else { continue }
                    queue.append((child, depth + 1))
                }
            } catch { notices.append("Não foi possível conferir todos os subprojetos Rust. Escolha uma pasta de projeto mais específica.") }
        }
        if cursor < queue.count, !Task.isCancelled {
            notices.append("A descoberta de subprojetos Rust atingiu o limite de pastas. Escolha raízes mais específicas para cobrir o restante.")
        }
        return projects.sorted()
    }

    static func inspect(project: String, preferences: Preferences, processes: ProcessInventory, catalog: RuleCatalog) throws -> [Finding] {
        let target = project + "/target"
        guard regularFile(project + "/Cargo.toml"), !FileTree.hasSymlinkAncestor(target),
              let root = try? FileTree.stamp(target), root.isDirectory else { return [] }
        var paths = [target + "/debug"]
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: target) else {
            return [.init(path: target, title: "Rust / " + URL(fileURLWithPath: project).lastPathComponent, category: .build, ruleID: ruleID, state: .inaccessible,
                          reason: "Não foi possível conferir os perfis Rust. Conteúdo preservado.")]
        }
        for name in children.sorted() where isTriple(name) {
            let triple = target + "/" + name
            guard let stamp = try? FileTree.stamp(triple), stamp.isDirectory, !FileTree.hasSymlinkAncestor(triple) else { continue }
            paths.append(triple + "/debug")
        }
        var findings: [Finding] = []
        for path in paths where (try? FileTree.stamp(path)) != nil {
            try Task.checkCancellation()
            let rule = CleaningRule(ruleID, .build, path, .whole, processTokens)
            var item = Scanner(catalog: catalog).inspect(path: path, rule: rule, preferences: preferences, processes: processes)
            let relative = String(path.dropFirst(project.count + 1))
            item.title = "Rust / " + URL(fileURLWithPath: project).lastPathComponent + " / " + relative
            item.details += [project + "/Cargo.toml", "Inclui dependências compiladas, cache incremental e saída de build scripts.",
                             "Perfis release, fontes, Cargo.lock e toolchains são preservados.",
                             "A próxima compilação debug terá que reconstruir estes arquivos."]
            if item.state == .ready || item.state == .inUse {
                if let reason = preservationReason(item, preferences: preferences) {
                    item.state = .protected; item.reason = reason
                } else if let reason = usageReason(item, processes: processes) {
                    item.state = .inUse; item.reason = reason
                } else {
                    item.reason = "Artefatos de compilação Rust sem uso visível. Selecione manualmente para limpar."
                }
            }
            findings.append(item)
        }
        return findings
    }

    /// Only the default debug profile and target triples are recognized. Never target/ itself.
    static func project(for finding: Finding) -> String? {
        guard finding.ruleID == ruleID, finding.category == .build else { return nil }
        let path = URL(fileURLWithPath: finding.path)
        guard path.lastPathComponent == "debug" else { return nil }
        let parent = path.deletingLastPathComponent()
        let target: URL
        if parent.lastPathComponent == "target" { target = parent }
        else {
            guard isTriple(parent.lastPathComponent), parent.deletingLastPathComponent().lastPathComponent == "target" else { return nil }
            target = parent.deletingLastPathComponent()
        }
        let project = target.deletingLastPathComponent().path
        guard finding.path == project + "/target/" + (parent == target ? "debug" : parent.lastPathComponent + "/debug") else { return nil }
        return project
    }

    static func recognizes(_ finding: Finding, preferences: Preferences) -> Bool {
        guard let project = project(for: finding), !FileTree.hasSymlinkAncestor(finding.path),
              regularFile(project + "/Cargo.toml"),
              preferences.projectRoots.contains(where: { root in
                  !FileTree.hasSymlinkAncestor(root) && FileTree.contains(FileTree.canonical(root), project)
              }),
              directory(finding.path + "/deps"), directory(finding.path + "/.fingerprint") else { return false }
        return true
    }

    /// Repeated by the executor; a ready flag or an old serialized plan is not authority.
    static func preservationReason(_ finding: Finding, preferences: Preferences) -> String? {
        guard recognizes(finding, preferences: preferences), let project = project(for: finding) else {
            return "A pasta não corresponde a um perfil debug reconhecido do Cargo dentro das raízes escolhidas. Preservada."
        }
        for entry in finding.manifest where !entry.relativePath.isEmpty {
            let path = entry.relativePath as NSString
            let parts = path.pathComponents
            let fileExtension = path.pathExtension.lowercased()
            if entry.stamp.isSymlink || (!entry.stamp.isDirectory && entry.stamp.mode & 0o170000 != 0o100000) ||
                parts.contains(where: { localDataNames.contains($0) || $0.hasPrefix(".env.") }) ||
                dataExtensions.contains(fileExtension) || configurationExtensions.contains(fileExtension) ||
                [".db-wal", ".db-shm", ".sqlite-wal", ".sqlite-shm", ".sqlite3-wal", ".sqlite3-shm"].contains(where: entry.relativePath.hasSuffix) ||
                (fileExtension == "json" && ![".fingerprint", "build"].contains(parts.first ?? "")) ||
                (sourceExtensions.contains(fileExtension) && parts.first != "build") {
                return "Há fontes, dados locais, credenciais ou links nesta pasta de compilação. Conteúdo preservado."
            }
        }
        // Check index paths only: no status, filters, hooks, fetch or Cargo execution.
        let git = ["--no-pager", "--no-optional-locks", "--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", project]
        var ancestor = project
        var hasRepository = false
        while ancestor != "/" {
            if (try? FileTree.stamp(ancestor + "/.git")) != nil {
                if FileTree.hasSymlinkAncestor(ancestor + "/.git") { return "O Git não confirmou que estes artefatos são ignorados e não rastreados. Conteúdo preservado." }
                hasRepository = true; break
            }
            ancestor = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
        }
        if hasRepository {
            let relative = String(finding.path.dropFirst(project.count + 1))
            let tracked = Command.run("/usr/bin/git", git + ["ls-files", "-z", "--", relative], timeout: 8)
            let ignored = Command.run("/usr/bin/git", git + ["check-ignore", "-q", "--", relative], timeout: 8)
            if tracked.status != 0 || tracked.timedOut || !tracked.output.isEmpty || ignored.status != 0 || ignored.timedOut {
                return "O Git não confirmou que estes artefatos são ignorados e não rastreados. Conteúdo preservado."
            }
        }
        return nil
    }

    static func usageReason(_ finding: Finding, processes: ProcessInventory) -> String? {
        guard let project = project(for: finding) else { return "Perfil Rust não reconhecido. Item preservado." }
        return processes.reason(path: project, tokens: processTokens, manifest: finding.manifest)
    }

    private static func regularFile(_ path: String) -> Bool {
        guard !FileTree.hasSymlinkAncestor(path), let stamp = try? FileTree.stamp(path) else { return false }
        return stamp.mode & 0o170000 == 0o100000
    }
    private static func directory(_ path: String) -> Bool {
        guard !FileTree.hasSymlinkAncestor(path), let stamp = try? FileTree.stamp(path) else { return false }
        return stamp.isDirectory
    }
    private static func isTriple(_ name: String) -> Bool {
        name.contains("-") && name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }
}
