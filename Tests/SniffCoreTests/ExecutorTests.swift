import Foundation
import Testing
@testable import SniffCore

struct Fixture {
    let root: URL
    let catalog: RuleCatalog
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/sniff-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        catalog = RuleCatalog(home: root.path)
    }
    func make(_ relative: String, text: String = "temporary regenerable fixture") throws -> String {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file.path
    }
    func finding(_ ruleID: String = "npm", preferences: Preferences = .init()) -> Finding {
        let rule = catalog.rule(id: ruleID)!
        var process = ProcessInventory(); process.complete = true
        return Scanner(catalog: catalog).inspect(path: rule.base, rule: rule, preferences: preferences, processes: process)
    }
    func clean(_ plan: [Finding], preferences: Preferences = .init(), date: Date = .now, automatic: Bool = false, useCheck: @escaping @Sendable (Finding) -> String? = { _ in nil }) -> CleaningReport {
        CleaningExecutor(catalog: catalog, useCheck: useCheck).execute(plan: plan, scannedAt: date, preferences: preferences, automatic: automatic)
    }
    func dispose() { try? FileManager.default.removeItem(at: root) }
}

@Test func removesOnlyRecognizedCacheAndMeasuresVolume() throws {
    let f = try Fixture(); defer { f.dispose() }
    let cache = try f.make(".npm/_cacache/content-v2/literal $(do-not-execute)")
    let source = try f.make("project/source.swift", text: "source must remain")
    let report = f.clean([f.finding()])
    #expect(report.outcomes.first?.removed == true)
    #expect(!FileManager.default.fileExists(atPath: cache))
    #expect(FileManager.default.fileExists(atPath: source))
    #expect(report.availableBefore != nil && report.availableAfter != nil)
}

@Test func exclusionInsideCandidatePreservesEntireTree() throws {
    let f = try Fixture(); defer { f.dispose() }
    let keep = try f.make(".npm/_cacache/keep/config.json")
    let item = f.finding()
    var preferences = Preferences(); preferences.exclusions = [keep]
    let report = f.clean([item], preferences: preferences)
    #expect(report.outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: keep))
}

@Test func internalSymlinkNeverTouchesOutsideTarget() throws {
    let f = try Fixture(); defer { f.dispose() }
    let keep = try f.make("outside/precious.db")
    _ = try f.make(".npm/_cacache/file")
    try FileManager.default.createSymbolicLink(atPath: f.catalog.home + "/.npm/_cacache/link", withDestinationPath: f.root.path + "/outside")
    let report = f.clean([f.finding()])
    #expect(report.outcomes.first?.removed == true)
    #expect(FileManager.default.fileExists(atPath: keep))
}

@Test func symlinkAncestorIsRefused() throws {
    let f = try Fixture(); defer { f.dispose() }
    let keep = try f.make("outside/file")
    try FileManager.default.createDirectory(atPath: f.root.path + "/.npm", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: f.root.path + "/.npm/_cacache", withDestinationPath: f.root.path + "/outside")
    #expect(f.finding().state == .inaccessible)
    #expect(f.clean([f.finding()]).outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: keep))
}

@Test func changedContentInvalidatesPlan() throws {
    let f = try Fixture(); defer { f.dispose() }
    let file = try f.make(".npm/_cacache/file")
    let item = f.finding()
    try Data("changed, preserve this".utf8).write(to: URL(fileURLWithPath: file))
    #expect(f.clean([item]).outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: file))
}

@Test func rechecksAfterSlowUsageProbe() throws {
    let f = try Fixture(); defer { f.dispose() }
    let file = try f.make(".npm/_cacache/file")
    let report = f.clean([f.finding()], useCheck: { _ in
        try? Data("new activity during probe".utf8).write(to: URL(fileURLWithPath: file))
        return nil
    })
    #expect(report.outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: file))
}

@Test func inUseItemIsPreserved() throws {
    let f = try Fixture(); defer { f.dispose() }
    let file = try f.make(".npm/_cacache/file")
    let report = f.clean([f.finding()], useCheck: { _ in "Arquivo aberto por processo de teste." })
    #expect(report.outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: file))
}

@Test func directProbeFindsAnOpenHardlinkByInode() throws {
    let f = try Fixture(); defer { f.dispose() }
    let original = try f.make("original")
    let link = f.root.path + "/hardlink"
    try FileManager.default.linkItem(atPath: original, toPath: link)
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: original)); defer { try? handle.close() }
    #expect(ProcessInventory.directFileInUse(link) == true)
}

@Test func expiredPlanAndDisabledCategoryAreRefused() throws {
    let f = try Fixture(); defer { f.dispose() }
    let file = try f.make(".npm/_cacache/file")
    let item = f.finding()
    #expect(f.clean([item], date: .now.addingTimeInterval(-901)).outcomes.first?.removed == false)
    var preferences = Preferences(); preferences.enabledCategories.remove(.npm)
    #expect(f.clean([item], preferences: preferences).outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: file))
}

@Test func forgedRuntimeAndWorktreeCannotEnterExecutor() throws {
    let f = try Fixture(); defer { f.dispose() }
    let keep = try f.make(".cache/codex-runtimes/codex-primary-runtime/bin/tool")
    var item = f.finding(); item.path = f.root.path + "/.cache/codex-runtimes/codex-primary-runtime"; item.state = .ready
    item.manifest = try FileTree.read(item.path)
    #expect(f.clean([item]).outcomes.first?.removed == false)
    item.ruleID = "worktree-review"; item.category = .worktree
    #expect(f.clean([item]).outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: keep))
}

@Test func partialFailureDoesNotHideSuccessfulRemoval() throws {
    let f = try Fixture(); defer { f.dispose() }
    let first = try f.make(".npm/_cacache/file")
    let second = try f.make(".cache/uv/file")
    let a = f.finding(); let b = f.finding("uv")
    try Data("changed".utf8).write(to: URL(fileURLWithPath: second))
    let report = f.clean([a, b])
    #expect(report.outcomes.count == 2)
    #expect(report.outcomes[0].removed && !report.outcomes[1].removed)
    #expect(!FileManager.default.fileExists(atPath: first) && FileManager.default.fileExists(atPath: second))
}

@Test func automaticCleanupRefusesVMAndLogs() throws {
    let f = try Fixture(); defer { f.dispose() }
    let vm = try f.make("Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img")
    var preferences = Preferences(); preferences.enabledCategories.insert(.claudeVM)
    let item = f.finding("claude-vm", preferences: preferences)
    #expect(f.clean([item], preferences: preferences, automatic: true).outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: vm))
}

@Test func schedulingSeparatesDueTimeAndSafeFixtureExecution() throws {
    let f = try Fixture(); defer { f.dispose() }
    let store = StateStore(directory: f.root.appendingPathComponent("store"))
    var state = PersistedState(); state.preferences.scheduleEnabled = true; state.preferences.scheduleMode = .automatic
    state.preferences.nextRun = .now.addingTimeInterval(3_600)
    #expect(!SchedulePolicy.isDue(state.preferences))
    state.preferences.nextRun = .now.addingTimeInterval(-1)
    #expect(SchedulePolicy.isDue(state.preferences))
    try store.save(state)
    let message = try ScheduledRunner.run(store: store, fixture: true)
    #expect(message?.contains("nenhuma limpeza") == true)
    #expect(store.load().history.isEmpty)
    #expect(store.load().schedulerLastWake != nil)
    let plist = try #require(PropertyListSerialization.propertyList(from: SchedulePolicy.launchAgentPlist(), format: nil) as? [String: Any])
    #expect(plist["BundleProgram"] as? String == "Contents/MacOS/Sniff")
    #expect(plist["StartInterval"] as? Int == 900)
    #expect(plist["UserName"] == nil)
}

@Test func lockPreventsConcurrentAppAndSchedulerOperations() throws {
    let f = try Fixture(); defer { f.dispose() }
    let store = StateStore(directory: f.root.appendingPathComponent("store"))
    let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
    #expect(throws: (any Error).self) { try store.lock() }
}

@Test func newestFileControlsRetention() throws {
    let f = try Fixture(); defer { f.dispose() }
    let file = try f.make(".cache/codex-runtimes/codex-runtime-install-fixture/file")
    var process = ProcessInventory(); process.complete = true
    let rule = try #require(f.catalog.rule(id: "codex-install"))
    let path = URL(fileURLWithPath: file).deletingLastPathComponent().path
    let item = Scanner(catalog: f.catalog).inspect(path: path, rule: rule, preferences: .init(), processes: process)
    #expect(item.state == .protected)
}
