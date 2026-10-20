#if DEBUG
import Foundation
import SniffCore

/// Sample data for repository screenshots. No disk store or cleaning is used.
enum PresentationPreview {
    static var enabled: Bool { CommandLine.arguments.contains("--project-preview") }
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
        return state
    }
}
#endif
