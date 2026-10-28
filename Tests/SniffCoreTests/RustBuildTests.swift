import Foundation
import Testing
@testable import SniffCore

private func rustFixture(_ fixture: Fixture, project: String = "projects/Sano/linux", profile: String = "debug") throws -> String {
    _ = try fixture.make(project + "/Cargo.toml", text: "[package]\nname = 'fixture'\nversion = '0.1.0'\nedition = '2021'\n")
    _ = try fixture.make(project + "/Cargo.lock", text: "# preserve fixture lockfile")
    _ = try fixture.make(project + "/src/main.rs", text: "fn main() {}")
    _ = try fixture.make(project + "/target/" + profile + "/deps/libfixture.rlib")
    _ = try fixture.make(project + "/target/" + profile + "/.fingerprint/fixture/lib-fixture.json", text: "{}")
    _ = try fixture.make(project + "/target/" + profile + "/incremental/session/query-cache.bin")
    _ = try fixture.make(project + "/target/" + profile + "/build/fixture/out/generated.rs", text: "// generated fixture source")
    _ = try fixture.make(project + "/target/release/fixture", text: "keep release fixture")
    return fixture.root.path + "/" + project
}

private func rustPreferences(_ fixture: Fixture) -> Preferences {
    var value = Preferences(); value.projectRoots = [fixture.root.path + "/projects"]; value.enabledCategories.insert(.build)
    return value
}

private func rustItems(_ fixture: Fixture, project: String, preferences: Preferences? = nil, processes: ProcessInventory? = nil) throws -> [Finding] {
    var idle = ProcessInventory(); idle.complete = true
    return try RustBuildInspector.inspect(project: project, preferences: preferences ?? rustPreferences(fixture), processes: processes ?? idle, catalog: fixture.catalog)
}

@Test func rustDiscoveryFindsNestedPortBelowGitRootAndDeduplicatesRoots() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let project = try rustFixture(fixture)
    let repository = fixture.root.path + "/projects/Sano"
    _ = try fixture.make("projects/Sano/.gitignore", text: "target/\n")
    #expect(Command.run("/usr/bin/git", ["init", repository]).status == 0)
    // Neither Cargo metadata nor build scripts may run while finding the port.
    let sentinel = fixture.root.path + "/unexpected-build-script"
    _ = try fixture.make("projects/Sano/linux/build.rs", text: "this is deliberately invalid Rust; never execute it")
    var notices: [String] = []
    let projects = ProjectInspector.discover(roots: [repository, repository], notices: &notices)
    #expect(projects.filter { $0 == project }.count == 1)
    #expect(projects.contains(repository))
    #expect(notices.isEmpty)
    let items = try rustItems(fixture, project: project)
    #expect(items.count == 1 && items.first?.state == .ready)
    #expect(items.first?.allocatedBytes ?? 0 > 0)
    #expect(!FileManager.default.fileExists(atPath: sentinel))
}

@Test func rustDebugRemovalKeepsReleaseSourcesLockfileAndWorktree() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let project = try rustFixture(fixture)
    let items = try rustItems(fixture, project: project)
    #expect(items.map(\.path) == [project + "/target/debug"])
    let report = fixture.clean(items, preferences: rustPreferences(fixture))
    #expect(report.outcomes.first?.removed == true)
    #expect(!FileManager.default.fileExists(atPath: project + "/target/debug"))
    for relative in ["src/main.rs", "Cargo.toml", "Cargo.lock", "target/release/fixture"] {
        #expect(FileManager.default.fileExists(atPath: project + "/" + relative))
    }
}

@Test func rustCrossCompilationDebugIsSeparateFromReleaseAndCustomProfiles() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let project = try rustFixture(fixture, profile: "aarch64-unknown-linux-gnu/debug")
    _ = try fixture.make("projects/Sano/linux/target/aarch64-unknown-linux-gnu/release/keep")
    _ = try fixture.make("projects/Sano/linux/target/custom-profile/keep")
    let items = try rustItems(fixture, project: project)
    #expect(items.count == 1)
    #expect(items.first?.path == project + "/target/aarch64-unknown-linux-gnu/debug")
    #expect(fixture.clean(items, preferences: rustPreferences(fixture)).outcomes.first?.removed == true)
    #expect(FileManager.default.fileExists(atPath: project + "/target/aarch64-unknown-linux-gnu/release/keep"))
    #expect(FileManager.default.fileExists(atPath: project + "/target/custom-profile/keep"))
}

@Test(arguments: ["cargo build", "cargo run", "rustc crate.rs", "rustdoc crate.rs", "rust-analyzer"])
func rustActiveToolsPreserveDebug(command: String) throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let project = try rustFixture(fixture)
    var processes = ProcessInventory(); processes.complete = true; processes.commands = [command]
    #expect(try rustItems(fixture, project: project, processes: processes).first?.state == .inUse)
}

@Test func rustOpenWorkspaceAndOpenHardlinksArePreserved() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let project = try rustFixture(fixture)
    var processes = ProcessInventory(); processes.complete = true; processes.openPaths = [project]
    #expect(try rustItems(fixture, project: project, processes: processes).first?.state == .inUse)
    let opened = fixture.root.path + "/open-alias"
    try FileManager.default.linkItem(atPath: project + "/target/debug/deps/libfixture.rlib", toPath: opened)
    processes.openPaths = [opened]
    #expect(try rustItems(fixture, project: project, processes: processes).first?.state == .inUse)
    processes.complete = false; processes.openPaths = []
    #expect(try rustItems(fixture, project: project, processes: processes).first?.state == .inUse)
}

@Test(arguments: ["local.db", "local.db-wal", ".env.production", "secret.pem", "notes.rs", "nested/.git/config", "build/fixture/out/data.sqlite", "config.json", "settings.yaml", "local.ini", "notes.json", "build/fixture/out/credentials.json"])
func rustLocalDataInGeneratedDirectoryIsNeverRemoved(relative: String) throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let project = try rustFixture(fixture)
    let data = try fixture.make("projects/Sano/linux/target/debug/" + relative, text: "local fixture data")
    var item = try #require(rustItems(fixture, project: project).first)
    #expect(item.state == .protected)
    item.state = .ready
    #expect(fixture.clean([item], preferences: rustPreferences(fixture)).outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: data))
}

@Test func rustTrackedArtifactsAndNewIndexEntriesAfterUsageProbeArePreserved() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let project = try rustFixture(fixture)
    let repository = fixture.root.path + "/projects/Sano"
    _ = try fixture.make("projects/Sano/.gitignore", text: "target/\n")
    #expect(Command.run("/usr/bin/git", ["init", repository]).status == 0)
    let items = try rustItems(fixture, project: project)
    #expect(items.first?.state == .ready)
    let path = project + "/target/debug/deps/libfixture.rlib"
    let report = fixture.clean(items, preferences: rustPreferences(fixture), useCheck: { _ in
        let result = Command.run("/usr/bin/git", ["-C", repository, "add", "--force", "--", path])
        return result.status == 0 ? nil : "fixture setup failed"
    })
    #expect(report.outcomes.first?.removed == false)
    #expect(try rustItems(fixture, project: project).first?.state == .protected)
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func rustRejectsWholeTargetLegacyPlansExclusionsAndAutomaticRemoval() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let project = try rustFixture(fixture)
    let item = try #require(rustItems(fixture, project: project).first)
    var legacy = item; legacy.ruleID = "rust-target"; legacy.path = project + "/target"; legacy.manifest = try FileTree.read(legacy.path)
    #expect(fixture.clean([legacy], preferences: rustPreferences(fixture)).outcomes.first?.removed == false)
    #expect(fixture.clean([item], preferences: rustPreferences(fixture), automatic: true).outcomes.first?.removed == false)
    var excluded = rustPreferences(fixture); excluded.exclusions = [project + "/target/debug/deps"]
    #expect(fixture.clean([item], preferences: excluded).outcomes.first?.removed == false)
    excluded.projectRoots = [fixture.root.path + "/other-root"]; excluded.exclusions = []
    #expect(fixture.clean([item], preferences: excluded).outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: project + "/target/release/fixture"))
}

@Test func rustDoesNotFollowSymlinksOrGuessCustomTargetDirectories() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let project = try rustFixture(fixture)
    let outside = try fixture.make("outside/precious.db")
    try FileManager.default.createSymbolicLink(atPath: project + "/target/debug/external", withDestinationPath: outside)
    #expect(try rustItems(fixture, project: project).first?.state == .protected)
    try FileManager.default.createSymbolicLink(atPath: project + "/linked-port", withDestinationPath: fixture.root.path + "/outside")
    var notices: [String] = []
    #expect(!RustBuildInspector.discover(roots: [project], notices: &notices).contains(project + "/linked-port"))
    var item = try #require(rustItems(fixture, project: project).first)
    item.path = project + "/custom-target/debug"
    #expect(!fixture.catalog.validates(item, preferences: rustPreferences(fixture)))
    #expect(FileManager.default.fileExists(atPath: outside))
}

@Test func rustDiscoveryReportsItsBoundAndWorktreeOnlyDiscoverySkipsNestedCargo() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    _ = try rustFixture(fixture)
    let repository = fixture.root.path + "/projects/Sano"
    #expect(Command.run("/usr/bin/git", ["init", repository]).status == 0)
    var notices: [String] = []
    #expect(RustBuildInspector.discover(roots: [repository], notices: &notices, directoryLimit: 1).isEmpty)
    #expect(notices.count == 1)
    let roots = ProjectInspector.discover(roots: [repository], includeNestedCargo: false, notices: &notices)
    #expect(roots == [repository])
}
