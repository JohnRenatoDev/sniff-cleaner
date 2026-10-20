import Foundation
import Testing
@testable import SniffCore

@Test func forgedReadyMCPEnvironmentIsStillPreservedAtExecution() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let path = try fixture.make(".npm/_npx/server/package-lock.json", text: "{\"dependencies\":{\"@modelcontextprotocol/server\":{}}}")
    let environment = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let old = Date().addingTimeInterval(-90 * 86_400)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: environment)
    var processes = ProcessInventory(); processes.complete = true
    var preferences = Preferences(); preferences.enabledCategories.insert(.npx)
    let rule = try #require(fixture.catalog.rule(id: "npx"))
    var finding = Scanner(catalog: fixture.catalog).inspect(path: environment, rule: rule, preferences: preferences, processes: processes)
    #expect(finding.state == .protected)
    finding.state = .ready
    #expect(fixture.clean([finding], preferences: preferences).outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func npxLockSymlinksRemainProtected() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let outside = try fixture.make("outside-lock.json", text: "{\"dependencies\":{\"ordinary-package\":{}}}")
    let path = fixture.root.appendingPathComponent(".npm/_npx/linked")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: path.appendingPathComponent("package-lock.json").path, withDestinationPath: outside)
    #expect(NpxPolicy.mustPreserve(path.path))
    #expect(FileManager.default.fileExists(atPath: outside))
}

@Test func corruptStateCannotBeSilentlyOverwritten() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let store = StateStore(directory: fixture.root.appendingPathComponent("state"))
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let data = Data("{invalid JSON keep this evidence".utf8)
    try data.write(to: store.file)
    #expect(throws: (any Error).self) { try store.loadValidated() }
    #expect(throws: (any Error).self) { try store.save(PersistedState()) }
    #expect(try Data(contentsOf: store.file) == data)
}

@Test func partialDirectoryRemovalReportsAlreadyRemovedFiles() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let first = try fixture.make(".npm/_cacache/first")
    let root = URL(fileURLWithPath: first).deletingLastPathComponent()
    let manifest = try FileTree.read(root.path)
    do {
        try SecureRemoval.remove(path: root.path, manifest: manifest, beforeUnlink: { relative in
            if relative.isEmpty { try? Data("new fixture activity".utf8).write(to: root.appendingPathComponent("new")) }
        })
        Issue.record("Expected an ENOTEMPTY partial removal")
    } catch let partial as SecureRemoval.PartialFailure {
        #expect(partial.allocatedBytes > 0)
        #expect(!FileManager.default.fileExists(atPath: first))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
    }
}

@Test func partialReportsInvalidateTheOldDeletionManifestAndDecodeOldReports() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    _ = try fixture.make(".npm/_cacache/file")
    let finding = fixture.finding()
    var snapshot = ScanSnapshot(); snapshot.findings = [finding]
    var state = PersistedState(); state.lastScan = snapshot
    var report = CleaningReport()
    report.outcomes = [RemovalOutcome(path: finding.path, removed: false, message: "Partial fixture", allocatedBytes: 512, partiallyRemoved: true)]
    state.apply(report)
    #expect(state.lastScan?.findings.first?.state == .protected)
    #expect(state.lastScan?.findings.first?.manifest.isEmpty == true)
    #expect(report.partialCount == 1 && report.removedAllocated == 512)
    let old = Data("{\"path\":\"/fixture\",\"removed\":false,\"message\":\"Kept\",\"allocatedBytes\":0}".utf8)
    #expect(try JSONDecoder().decode(RemovalOutcome.self, from: old).partiallyRemoved == nil)
}
