#if DEBUG
import Foundation
import SniffCore

/// Sample data for repository screenshots. No disk store or cleaning is used.
enum PresentationPreview {
    static var enabled: Bool { CommandLine.arguments.contains("--project-preview") }
    static var worktrees: Bool { enabled && CommandLine.arguments.contains("--worktree-preview") }
    static func state() -> PersistedState {
        var state = PersistedState(), scan = ScanSnapshot()
        let megabyte: Int64 = 1_048_576
        let caches: [(SniffCore.Category, String, Int64)] = [
            (.npm, "~/.npm/_cacache", 1_280), (.pnpm, "~/Library/pnpm/store/v3", 920),
            (.uv, "~/Library/Caches/uv", 610), (.cargo, "~/.cargo/registry/cache", 480)
        ]
        for (category, path, size) in caches {
            scan.findings.append(Finding(path: path, title: category.title, category: category, ruleID: "presentation-only", state: .ready,
                                         reason: "Regra reconhecida; será verificada novamente antes de remover.", logicalBytes: size * megabyte, allocatedBytes: size * megabyte))
        }
        scan.findings.append(Finding(path: "~/.npm/_npx/example-mcp", title: "MCP environment", category: .npx, ruleID: "presentation-only", state: .protected,
                                     reason: "Ambiente npx com MCP ou conteúdo não verificável. Item preservado.", allocatedBytes: 84 * megabyte))
        scan.findings.append(Finding(path: "~/Code/example-app/.build", title: "example-app / .build", category: .build, ruleID: "presentation-only", state: .inUse,
                                     reason: "Build in progress. Sniff keeps these files while the compiler is running.", allocatedBytes: 340 * megabyte))
        state.lastScan = scan
        if worktrees {
            scan.findings = []
            let examples: [(String, FindingState, WorktreeStatus, String)] = [
                ("old-ui-review", .ready, .idle, "Sem uso visível, alterações locais ou commits pendentes. Worktree disponível para revisão manual."),
                ("pending-api-work", .protected, .pendingCommits, "Há commits não publicados ou ainda não integrados à principal. Worktree preservada."),
                ("active-session", .inUse, .inUse, "Um processo em execução faz referência a este caminho.")
            ]
            for (index, example) in examples.enumerated() {
                let (name, findingState, status, reason) = example
                var item = Finding(path: "~/Code/example-app/.claude/worktrees/" + name, title: name,
                    category: .worktree, ruleID: "presentation-only", state: findingState, reason: reason,
                    logicalBytes: Int64(700 - index * 150) * megabyte, allocatedBytes: Int64(700 - index * 150) * megabyte)
                item.worktree = WorktreeAssessment(repository: "~/Code/example-app", status: status, branch: "refs/heads/" + name)
                item.worktree?.unpublishedCommits = status == .pendingCommits ? 2 : 0
                item.worktree?.unmergedCommits = status == .pendingCommits ? 2 : 0
                item.details = ["Branch: " + name, "Commits não publicados: \(status == .pendingCommits ? 2 : 0).",
                    "A comparação usa referências locais do Git; o servidor não foi consultado."]
                scan.findings.append(item)
            }
            state.lastScan = scan
        }
        return state
    }
}
#endif
