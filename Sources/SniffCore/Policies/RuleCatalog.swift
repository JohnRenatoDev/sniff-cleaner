import Foundation

public struct CleaningRule: Sendable {
    public enum Layout: Sendable { case whole, children(prefix: String), logs }
    public var id: String
    public var category: Category
    public var base: String
    public var layout: Layout
    public var processTokens: [String]
    public init(_ id: String, _ category: Category, _ base: String, _ layout: Layout = .whole, _ tokens: [String] = []) {
        self.id = id; self.category = category; self.base = base; self.layout = layout; self.processTokens = tokens
    }
    public func matches(_ path: String) -> Bool {
        switch layout {
        case .whole: return path == base
        case .children(let prefix): return URL(fileURLWithPath: path).deletingLastPathComponent().path == base && URL(fileURLWithPath: path).lastPathComponent.hasPrefix(prefix)
        case .logs: return FileTree.contains(base, path) && path != base && URL(fileURLWithPath: path).pathExtension == "log"
        }
    }
}

public struct RuleCatalog: Sendable {
    public let home: String
    public var rules: [CleaningRule] {
        func p(_ relative: String) -> String { home + "/" + relative }
        return [
            .init("npm", .npm, p(".npm/_cacache"), .whole, ["npm install", "npm ci", "npm exec"]),
            .init("npx", .npx, p(".npm/_npx"), .children(prefix: ""), ["npx "]),
            .init("uv", .uv, p(".cache/uv"), .whole, ["uv sync", "uv pip", "uv tool", "uv cache"]),
            .init("bun", .bun, p(".bun/install/cache"), .whole, ["bun install", "bun add"]),
            .init("pnpm-cache", .pnpm, p("Library/Caches/pnpm"), .whole, ["pnpm install", "pnpm add"]),
            .init("pnpm-store", .pnpm, p("Library/pnpm/store"), .children(prefix: ""), ["pnpm install", "pnpm add"]),
            .init("pip", .pip, p("Library/Caches/pip"), .whole, ["pip install", "pip3 install"]),
            .init("pip-xdg", .pip, p(".cache/pip"), .whole, ["pip install", "pip3 install"]),
            .init("node-gyp", .nodeGyp, p("Library/Caches/node-gyp"), .whole, ["node-gyp", "npm install", "npm ci"]),
            .init("go", .go, p("Library/Caches/go-build"), .whole, ["go build", "go test", "go run"]),
            .init("typescript", .typescript, p("Library/Caches/typescript"), .whole, ["tsc", "typescript"]),
            .init("swiftpm", .swiftPM, p("Library/Caches/org.swift.swiftpm"), .whole, ["swift build", "swift package", "swift-frontend", "xcodebuild"]),
            .init("brew", .homebrew, p("Library/Caches/Homebrew"), .whole, ["brew install", "brew upgrade", "brew fetch"]),
            .init("nuget", .nuget, p(".local/share/NuGet/http-cache"), .whole, ["dotnet restore", "dotnet build", "nuget"]),
            .init("cargo-cache", .cargo, p(".cargo/registry/cache"), .whole, ["cargo build", "cargo test", "cargo fetch", "rustc"]),
            .init("gradle", .gradle, p(".gradle/caches"), .children(prefix: ""), ["gradle", "GradleDaemon"]),
            .init("codex-install", .runtimeInstall, p(".cache/codex-runtimes"), .children(prefix: "codex-runtime-install-"), ["codex-runtime-install"]),
            .init("codex-updater", .installer, p("Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"), .children(prefix: ""), ["Updater.app", "Autoupdate"]),
            .init("granola-updater", .installer, p("Library/Caches/@granolaelectron-updater/pending"), .children(prefix: ""), ["granola-updater"]),
            .init("bitwarden-updater", .installer, p("Library/Caches/bitwarden-updater"), .children(prefix: ""), ["bitwarden-updater"]),
            .init("antigravity-updater", .installer, p("Library/Caches/antigravity-updater"), .children(prefix: ""), ["antigravity-updater"]),
            .init("codex-log", .logs, p(".codex/log"), .logs),
            .init("codex-app-log", .logs, p("Library/Logs/com.openai.codex"), .logs),
            .init("claude-log", .logs, p("Library/Logs/Claude"), .logs),
            .init("claude-vm", .claudeVM, p("Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img"), .whole, ["Claude", "claudevm", "Virtualization"])
        ]
    }
    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.home = FileTree.canonical(home) }
    public func rule(id: String) -> CleaningRule? { rules.first { $0.id == id } }
    public func protectedReason(_ path: String, preferences: Preferences) -> String? {
        let paths = [".codex/sessions", ".codex/sqlite", ".codex/auth.json", ".claude", ".ssh", ".aws", ".config", ".cache/codex-runtimes/codex-primary-runtime", "Library/Application Support/Sniff"]
        for relative in paths where FileTree.contains(home + "/" + relative, path) { return "Dados, configurações ou runtime principal protegidos." }
        for excluded in preferences.exclusions {
            let resolved = FileTree.canonical(excluded)
            if FileTree.contains(resolved, path) || FileTree.contains(path, resolved) { return "Preservado por uma exclusão sua: \(excluded)" }
        }
        return nil
    }
    public func validates(_ finding: Finding, preferences: Preferences) -> Bool {
        if let rule = rule(id: finding.ruleID), rule.category == finding.category { return rule.matches(finding.path) }
        if finding.ruleID == "rust-target", finding.category == .build {
            let parent = URL(fileURLWithPath: finding.path).deletingLastPathComponent().path
            return finding.path == parent + "/target" && FileManager.default.fileExists(atPath: parent + "/Cargo.toml") && preferences.projectRoots.contains { FileTree.contains(FileTree.canonical($0), parent) }
        }
        if finding.ruleID == "swift-build", finding.category == .build {
            let parent = URL(fileURLWithPath: finding.path).deletingLastPathComponent().path
            return finding.path == parent + "/.build" && FileManager.default.fileExists(atPath: parent + "/Package.swift") && preferences.projectRoots.contains { FileTree.contains(FileTree.canonical($0), parent) }
        }
        // Signing clones remain inspection-only in v0.1; they cannot enter the executor.
        return false
    }
}
