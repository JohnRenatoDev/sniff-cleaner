import Foundation
import Testing
import SniffCore
@testable import SniffCommands
import SniffInstallation

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

@Test func parserRejectsAmbiguousAndDestructiveShortcuts() throws {
    #expect(throws: (any Error).self) { try CLIRequest.parse(["clean", "--yes"]) }
    #expect(throws: (any Error).self) { try CLIRequest.parse(["plan", "--path", "/tmp/a", "--category", "npm"]) }
    #expect(throws: (any Error).self) { try CLIRequest.parse(["scan", "--yes"]) }
    #expect(throws: (any Error).self) { try CLIRequest.parse(["plan", "--category", "all"]) }
    #expect(throws: (any Error).self) { try CLIRequest.parse(["scan", "--language", "fr"]) }
    #expect(try CLIRequest.parse(["scan", "--language", "es"]).language == .spanish)
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
