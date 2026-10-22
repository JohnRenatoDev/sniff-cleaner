import Foundation
import Testing
@testable import SniffCore

@Test func registeredExternalWorktreePreservesIgnoredDatabaseAndUsesRealPrincipal() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let repository = fixture.root.path + "/projects/main"
    _ = try fixture.make("projects/main/source.swift", text: "fixture source")
    _ = try fixture.make("projects/main/.gitignore", text: "local.db\n")
    func git(_ arguments: [String]) throws -> CommandResult {
        let result = Command.run("/usr/bin/git", ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Sniff fixture", "-c", "user.email=sniff-fixture@localhost", "-C", repository] + arguments)
        #expect(result.status == 0)
        return result
    }
    _ = try git(["init", "-b", "trunk-real"])
    _ = try git(["add", "."])
    _ = try git(["commit", "-m", "fixture"])
    _ = try git(["update-ref", "refs/remotes/origin/trunk-real", "HEAD"])
    _ = try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk-real"])
    let external = fixture.root.path + "/outside-project-roots/worktree"
    _ = try git(["worktree", "add", "--detach", external, "HEAD"])
    let database = try fixture.make("outside-project-roots/worktree/local.db", text: "disposable fixture database; preserve")
    var preferences = Preferences(); preferences.projectRoots = [fixture.root.path + "/projects"]
    var notices: [String] = []
    let discovered = ProjectInspector.discover(roots: preferences.projectRoots, notices: &notices)
    var processes = ProcessInventory(); processes.complete = true
    let findings = try ProjectInspector.inspect(repositories: discovered, preferences: preferences, processes: processes, catalog: fixture.catalog, progress: { _ in })
    let item = try #require(findings.first { $0.path == external })
    #expect(item.state == .protected)
    #expect(item.details.contains { $0.contains("origin/trunk-real") })
    #expect(item.details.contains { $0.contains("Ignorado: local.db") })
    #expect(item.details.contains { $0.contains("Commits exclusivos") && $0.contains("0") })
    #expect(!fixture.catalog.validates(item, preferences: preferences))
    #expect(FileManager.default.fileExists(atPath: database))
}

@Test func boundedMeasurementLabelsPartialSizeWithoutLoadingWholeTree() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    for index in 0..<10 { _ = try fixture.make("tree/\(index).bin", text: String(repeating: "x", count: 1_024)) }
    let result = try FileTree.boundedMeasurement(fixture.root.path + "/tree", seconds: 3, limit: 3)
    #expect(result.partial)
    #expect(result.logical == 2_048)
    #expect(result.allocated > 0)
}
