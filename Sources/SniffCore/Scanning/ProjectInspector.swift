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

    public static func inspect(repositories: [String], preferences: Preferences, processes: ProcessInventory, catalog: RuleCatalog, worktreesOnly: Bool = false, progress: @Sendable (String) -> Void) throws -> [Finding] {
        var findings: [Finding] = []
        for repository in repositories {
            try Task.checkCancellation()
            if worktreesOnly { break }
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
        }
        findings += try WorktreeInspector.inspect(repositories: repositories, preferences: preferences, processes: processes, catalog: catalog, progress: progress)
        return findings
    }
}
