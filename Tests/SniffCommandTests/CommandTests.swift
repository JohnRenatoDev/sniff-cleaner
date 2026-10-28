import Foundation
import Testing
import SniffCore
@testable import SniffCommands

struct CommandFixture {
    let root: URL
    let home: URL
    let store: StateStore
    let catalog: RuleCatalog
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/sniff-cli-tests-" + UUID().uuidString)
        home = root.appendingPathComponent("home"); store = StateStore(directory: root.appendingPathComponent("state")); catalog = RuleCatalog(home: home.path)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    func make(_ path: String, content: String = "disposable fixture") throws -> URL {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file); return file
    }
    var runner: CLIRunner { CLIRunner(environment: CLIEnvironment(catalog: catalog, store: store, captureProcesses: { var inventory = ProcessInventory(); inventory.complete = true; return inventory })) }
    func request(_ args: [String]) throws -> CLIRequest { var request = try CLIRequest.parse(args); request.language = .english; return request }
    func dispose() { precondition(root.path.hasPrefix("/private/tmp/sniff-cli-tests-")); try? FileManager.default.removeItem(at: root) }
}

@Test func scanPlanAndExplicitCleanupOnlyRemoveFixtureFiles() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    let cache = try fixture.make(".npm/_cacache/fixture")
    let source = try fixture.make("project/source.swift", content: "preserve source")
    let scan = try fixture.runner.run(fixture.request(["scan", "--quick", "--json"]))
    #expect(scan.status == 0 && FileManager.default.fileExists(atPath: cache.path))
    #expect(try JSONSerialization.jsonObject(with: Data(scan.output.utf8)) is [String: Any])
    let plan = fixture.root.appendingPathComponent("review.json")
    _ = try fixture.runner.run(fixture.request(["plan", "--category", "npm", "--output", plan.path]))
    #expect((try FileManager.default.attributesOfItem(atPath: plan.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(throws: (any Error).self) { try fixture.runner.run(fixture.request(["clean", "--plan", plan.path])) }
    #expect(FileManager.default.fileExists(atPath: cache.path))
    let result = try fixture.runner.run(fixture.request(["clean", "--plan", plan.path, "--yes", "--json"]))
    #expect(result.status == 0)
    #expect(!FileManager.default.fileExists(atPath: cache.path))
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try fixture.store.loadValidated().history.count == 1)
}

@Test func cleanupRevalidatesChangedPreferencesAndContent() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    let cache = try fixture.make(".npm/_cacache/fixture")
    _ = try fixture.runner.run(fixture.request(["scan", "--quick"]))
    let plan = fixture.root.appendingPathComponent("review.json")
    _ = try fixture.runner.run(fixture.request(["plan", "--output", plan.path]))
    _ = try fixture.runner.run(fixture.request(["config", "--disable", "npm"]))
    let result = try fixture.runner.run(fixture.request(["clean", "--plan", plan.path, "--yes"]))
    #expect(result.status == 4 && FileManager.default.fileExists(atPath: cache.path))
}

@Test func rustCLIReviewAndCleanupRecheckUsageAndPreserveRelease() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    let repository = fixture.home.appendingPathComponent("Code/Sano").path
    _ = try fixture.make("Code/Sano/.gitignore", content: "target/\n")
    _ = try fixture.make("Code/Sano/linux/Cargo.toml", content: "[package]\nname='fixture'\nversion='0.1.0'\n")
    let source = try fixture.make("Code/Sano/linux/src/main.rs", content: "fn main() {}")
    let release = try fixture.make("Code/Sano/linux/target/release/fixture")
    let debug = try fixture.make("Code/Sano/linux/target/debug/deps/libfixture.rlib")
    _ = try fixture.make("Code/Sano/linux/target/debug/.fingerprint/fixture/lib-fixture.json", content: "{}")
    #expect(Command.run("/usr/bin/git", ["init", repository]).status == 0)
    var idle = ProcessInventory(); idle.complete = true
    var state = PersistedState(); state.preferences.projectRoots = [fixture.home.appendingPathComponent("Code").path]
    var notices: [String] = []
    let projects = ProjectInspector.discover(roots: state.preferences.projectRoots, notices: &notices)
    var scan = ScanSnapshot()
    scan.findings = try ProjectInspector.inspect(repositories: projects, preferences: state.preferences, processes: idle, catalog: fixture.catalog, progress: { _ in })
    let item = try #require(scan.findings.first { $0.ruleID == "rust-debug" })
    #expect(item.state == .ready && !state.preferences.enabledCategories.contains(.build))
    state.lastScan = scan; try fixture.store.save(state)
    let list = try fixture.runner.run(fixture.request(["list", "--category", "build", "--json"]))
    let listed = try #require(JSONSerialization.jsonObject(with: Data(list.output.utf8)) as? [String: Any])
    let listedItems = try #require(listed["items"] as? [[String: Any]])
    #expect(listedItems.contains { $0["path"] as? String == item.path && $0["state"] as? String == "ready" })
    _ = try fixture.runner.run(fixture.request(["config", "--enable", "build"]))
    let plan = fixture.root.appendingPathComponent("rust-debug-plan.json")
    _ = try fixture.runner.run(fixture.request(["plan", "--path", item.path, "--output", plan.path]))
    let active = CLIRunner(environment: CLIEnvironment(catalog: fixture.catalog, store: fixture.store, captureProcesses: {
        var value = ProcessInventory(); value.complete = true; value.commands = ["cargo run"]
        return value
    }))
    let blocked = try active.run(fixture.request(["clean", "--plan", plan.path, "--yes", "--json"]))
    #expect(blocked.status == 4 && FileManager.default.fileExists(atPath: debug.path))
    let cleaned = try fixture.runner.run(fixture.request(["clean", "--plan", plan.path, "--yes", "--json"]))
    #expect(cleaned.status == 0 && !FileManager.default.fileExists(atPath: debug.path))
    #expect(FileManager.default.fileExists(atPath: release.path))
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func parserRejectsAmbiguousAndDestructiveShortcuts() throws {
    #expect(throws: (any Error).self) { try CLIRequest.parse(["clean", "--yes"]) }
    #expect(throws: (any Error).self) { try CLIRequest.parse(["plan", "--path", "/tmp/a", "--category", "npm"]) }
    #expect(throws: (any Error).self) { try CLIRequest.parse(["scan", "--yes"]) }
    #expect(throws: (any Error).self) { try CLIRequest.parse(["plan", "--category", "all"]) }
    #expect(throws: (any Error).self) { try CLIRequest.parse(["scan", "--language", "fr"]) }
    #expect(try CLIRequest.parse(["scan", "--language", "es"]).language == .spanish)
    #expect(try CLIRequest.parse(["scan", "--worktrees"]).worktreesOnly)
    #expect(throws: (any Error).self) { try CLIRequest.parse(["scan", "--quick", "--worktrees"]) }
    #expect(throws: (any Error).self) { try CLIRequest.parse(["list", "--worktrees"]) }
}

@Test func worktreeOnlyCLIRequiresExplicitManualPlanAndPreservesCaches() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    let source = try fixture.make("Code/repository/source.swift", content: "published fixture source")
    let cache = try fixture.make(".npm/_cacache/keep-this-cache")
    let repository = source.deletingLastPathComponent().path
    let worktree = fixture.home.appendingPathComponent("external/worktree").path
    func git(_ args: [String], in path: String? = nil) throws -> String {
        let result = Command.run("/usr/bin/git", ["--no-optional-locks", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=CLI fixture", "-c", "user.email=fixture@localhost", "-C", path ?? repository] + args)
        guard result.status == 0 else { throw CLIFailure.usage("Fixture Git command failed") }
        return result.output
    }
    _ = try git(["init", "-b", "real-default"])
    _ = try git(["add", "."])
    _ = try git(["commit", "-m", "fixture"])
    _ = try git(["update-ref", "refs/remotes/origin/real-default", "HEAD"])
    _ = try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/real-default"])
    _ = try git(["worktree", "add", "-b", "fixture-copy", worktree, "HEAD"])
    let admin = try git(["rev-parse", "--path-format=absolute", "--git-dir"], in: worktree).trimmingCharacters(in: .newlines)
    for root in [worktree, admin] {
        for entry in try FileTree.read(root).reversed() {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86_400)], ofItemAtPath: entry.relativePath.isEmpty ? root : root + "/" + entry.relativePath)
        }
    }
    let scan = try fixture.runner.run(fixture.request(["scan", "--worktrees", "--json"]))
    let json = try #require(JSONSerialization.jsonObject(with: Data(scan.output.utf8)) as? [String: Any])
    let items = try #require(json["items"] as? [[String: Any]])
    #expect(items.count == 1 && items.first?["category"] as? String == "worktree")
    #expect(items.first?["state"] as? String == "ready")
    let assessment = try #require(items.first?["worktree"] as? [String: Any])
    #expect(assessment["status"] as? String == "idle" && assessment["unpublishedCommits"] as? Int == 0)
    #expect(assessment["removalContext"] == nil)
    #expect(FileManager.default.fileExists(atPath: worktree))
    #expect(throws: (any Error).self) { try fixture.runner.run(fixture.request(["plan", "--category", "worktree"])) }
    _ = try fixture.runner.run(fixture.request(["config", "--enable", "worktree"]))
    #expect(throws: (any Error).self) { try fixture.runner.run(fixture.request(["plan"])) }
    let plan = fixture.root.appendingPathComponent("worktree-plan.json")
    _ = try fixture.runner.run(fixture.request(["plan", "--category", "worktree", "--output", plan.path]))
    let result = try fixture.runner.run(fixture.request(["clean", "--plan", plan.path, "--yes", "--json"]))
    #expect(result.status == 0)
    #expect(!FileManager.default.fileExists(atPath: worktree))
    #expect(FileManager.default.fileExists(atPath: source.path) && FileManager.default.fileExists(atPath: cache.path))
    #expect(try git(["rev-parse", "--verify", "refs/heads/fixture-copy"]).isEmpty == false)
}

@Test func planFilesCannotOverwriteExistingFilesOrUseSymlinks() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    _ = try fixture.make(".npm/_cacache/file")
    _ = try fixture.runner.run(fixture.request(["scan", "--quick"]))
    let plan = fixture.root.appendingPathComponent("plan.json")
    _ = try fixture.runner.run(fixture.request(["plan", "--output", plan.path]))
    let original = try Data(contentsOf: plan)
    #expect(throws: (any Error).self) { try fixture.runner.run(fixture.request(["plan", "--output", plan.path])) }
    #expect(try Data(contentsOf: plan) == original)
    let link = fixture.root.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: plan)
    #expect(throws: (any Error).self) { try PlanDocument.read(from: link, expectedHome: fixture.catalog.home) }
}

@Test func expiredAndForeignPlansAreRejected() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    _ = try fixture.make(".npm/_cacache/file")
    _ = try fixture.runner.run(fixture.request(["scan", "--quick"]))
    let findings = try #require(fixture.store.loadValidated().lastScan?.findings)
    let expired = fixture.root.appendingPathComponent("expired.json")
    try PlanDocument(home: fixture.catalog.home, scannedAt: .now.addingTimeInterval(-901), findings: findings).write(to: expired)
    #expect(throws: (any Error).self) { try PlanDocument.read(from: expired, expectedHome: fixture.catalog.home) }
    let foreign = fixture.root.appendingPathComponent("foreign.json")
    try PlanDocument(home: "/another-home", scannedAt: .now, findings: findings).write(to: foreign)
    #expect(throws: (any Error).self) { try PlanDocument.read(from: foreign, expectedHome: fixture.catalog.home) }
}
