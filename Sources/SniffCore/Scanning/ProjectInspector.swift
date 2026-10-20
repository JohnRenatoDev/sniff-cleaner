import Foundation

public enum ProjectInspector {
    public static func discover(roots: [String], notices: inout [String]) -> [String] {
        let skip: Set<String> = ["node_modules", "target", ".build", ".git", "vendor", ".venv", "venv", "dist", "build", "Library", ".cache"]
        var queue = roots.map { (FileTree.canonical($0), 0) }; var seen = Set<String>(); var repositories = Set<String>(); var visited = 0
        while !queue.isEmpty, visited < 7_000 {
            let (path, depth) = queue.removeFirst()
            guard seen.insert(path).inserted, let stamp = try? FileTree.stamp(path), stamp.isDirectory, !FileTree.hasSymlinkAncestor(path) else { continue }
            visited += 1
            if FileManager.default.fileExists(atPath: path + "/.git") { repositories.insert(path); continue }
            if FileManager.default.fileExists(atPath: path + "/Cargo.toml") || FileManager.default.fileExists(atPath: path + "/Package.swift") { repositories.insert(path) }
            guard depth < 5 else { continue }
            do {
                for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() where !skip.contains(name) {
                    if name.hasPrefix(".") && ![".claude", ".codex"].contains(name) { continue }
                    queue.append((path + "/" + name, depth + 1))
                }
            } catch { notices.append("Pasta de projeto sem acesso: \(path)") }
        }
        if visited >= 7_000 { notices.append("Descoberta de projetos limitada a 7.000 pastas. Escolha raízes mais específicas para cobrir o restante.") }
        return repositories.sorted()
    }

    public static func inspect(repositories: [String], preferences: Preferences, processes: ProcessInventory, catalog: RuleCatalog, progress: @Sendable (String) -> Void) throws -> [Finding] {
        var findings: [Finding] = []; var seen = Set<String>()
        for repository in repositories {
            try Task.checkCancellation()
            progress("Conferindo \(URL(fileURLWithPath: repository).lastPathComponent)…")
            for (output, marker, id) in [("target", "Cargo.toml", "rust-target"), (".build", "Package.swift", "swift-build")] {
                let path = repository + "/" + output
                if FileManager.default.fileExists(atPath: repository + "/" + marker), FileManager.default.fileExists(atPath: path), preferences.projectRoots.contains(where: { FileTree.contains(FileTree.canonical($0), path) }) {
                    let rule = CleaningRule(id, .build, path, .whole, ["cargo build", "cargo test", "rustc", "swift-frontend", "swift build", "xcodebuild"])
                    var item = Scanner(catalog: catalog).inspect(path: path, rule: rule, preferences: preferences, processes: processes)
                    item.title = URL(fileURLWithPath: repository).lastPathComponent + " / " + output
                    findings.append(item)
                }
            }
            let list = git(repository, ["worktree", "list", "--porcelain", "-z"])
            guard list.status == 0 else { continue }
            let paths = list.output.components(separatedBy: "\0").filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) }
            for path in paths.dropFirst() where seen.insert(path).inserted {
                try Task.checkCancellation()
                progress("Inspecionando worktree \(URL(fileURLWithPath: path).lastPathComponent)…")
                guard FileManager.default.fileExists(atPath: path), !FileTree.hasSymlinkAncestor(path) else {
                    findings.append(.init(path: path, title: URL(fileURLWithPath: path).lastPathComponent, category: .worktree, ruleID: "worktree-review", state: .review, reason: "Registro sem diretório presente ou caminho com symlink. Nenhuma remoção.")); continue
                }
                var item = Finding(path: path, title: URL(fileURLWithPath: path).lastPathComponent, category: .worktree, ruleID: "worktree-review", state: .review, reason: "Worktree preservada. Arquivamento com preservação de estado ainda exige revisão.")
                let status = git(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
                let ignored = git(path, ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"])
                let branch = git(path, ["symbolic-ref", "--short", "HEAD"])
                let upstream = ["upstream", "origin"].compactMap { remote -> String? in
                    let result = git(path, ["symbolic-ref", "--quiet", "refs/remotes/\(remote)/HEAD"])
                    return result.status == 0 ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                }.first
                item.details.append("Branch: \(branch.status == 0 ? branch.output.trimmingCharacters(in: .whitespacesAndNewlines) : "HEAD destacado")")
                item.details.append(status.status == 0 ? (status.output.isEmpty ? "Git sem alterações locais ou untracked." : "Há alterações locais ou arquivos untracked. Preservar.") : "Estado do Git não pôde ser verificado.")
                if ignored.status == 0 {
                    let files = ignored.output.components(separatedBy: "\0").filter { !$0.isEmpty }
                    item.details.append("\(files.count) arquivos ignorados; podem conter configuração, estado ou bancos.")
                    item.details += files.prefix(6).map { "Ignorado: " + $0 }
                } else { item.details.append("Arquivos ignorados não puderam ser enumerados.") }
                if let upstream {
                    let count = git(path, ["rev-list", "--count", "\(upstream)..HEAD"])
                    item.details.append("Principal registrada: \(upstream). Referência local; nenhum fetch executado.")
                    item.details.append(count.status == 0 ? "Commits exclusivos frente a essa referência: \(count.output.trimmingCharacters(in: .whitespacesAndNewlines))." : "Não foi possível comparar commits.")
                } else { item.details.append("Branch principal real não registrada no Git local. Não presumida como main/master.") }
                if let reason = processes.reason(path: path) { item.state = .inUse; item.reason = reason }
                if let reason = catalog.protectedReason(path, preferences: preferences) { item.state = .protected; item.reason = reason }
                // Worktree manifests are not persisted: inspection cannot accidentally become a deletion plan.
                do {
                    let size = try FileTree.boundedMeasurement(path)
                    item.logicalBytes = size.logical; item.allocatedBytes = size.allocated; item.sharedLinks = size.shared; item.partialMeasurement = size.partial
                    if size.partial { item.details.append("Tamanho parcial: medição limitada por tempo e arquivos. O valor exibido é um mínimo, não o total da worktree.") }
                }
                catch { item.details.append("Tamanho não concluído: \(error.localizedDescription)") }
                findings.append(item)
            }
        }
        return findings
    }
    private static func git(_ path: String, _ arguments: [String]) -> CommandResult {
        Command.run("/usr/bin/git", ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", path] + arguments, timeout: 12)
    }
}
