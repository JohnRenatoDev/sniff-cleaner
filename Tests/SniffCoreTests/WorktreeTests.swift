import Foundation
import Darwin
import Testing
@testable import SniffCore

struct WorktreeFixture {
    let fixture: Fixture
    let repository: String
    let path: String
    init() throws {
        fixture = try Fixture()
        repository = fixture.root.path + "/projects/main"
        path = fixture.root.path + "/outside/idle $(literal) árvore"
        _ = try fixture.make("projects/main/source.swift", text: "committed fixture source")
        _ = try fixture.make("projects/main/package.json", text: "{\"name\":\"sniff-fixture\",\"private\":true}")
        _ = try fixture.make("projects/main/.gitignore", text: "local.db\n.env\n.claude/\nnode_modules/\nscratch/\nbin/\nobj/\n")
        _ = try git(["init", "-b", "trunk-real"])
        _ = try git(["add", "."])
        _ = try git(["commit", "-m", "fixture baseline"])
        _ = try git(["update-ref", "refs/remotes/origin/trunk-real", "HEAD"])
        _ = try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk-real"])
        _ = try git(["worktree", "add", "-b", "fixture-idle", path, "HEAD"])
        try age()
    }
    var preferences: Preferences {
        var value = Preferences(); value.projectRoots = [fixture.root.path + "/projects"]; return value
    }
    var admin: String { WorktreeInspector.git(path, ["rev-parse", "--path-format=absolute", "--git-dir"]).output.trimmingCharacters(in: .newlines) }
    @discardableResult func git(_ args: [String], in directory: String? = nil) throws -> String {
        let result = Command.run("/usr/bin/git", ["--no-optional-locks", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Sniff fixture", "-c", "user.email=sniff-fixture@localhost", "-C", directory ?? repository] + args)
        guard result.status == 0, !result.timedOut else { throw SniffError.message("Fixture Git command failed: \(args.first ?? "unknown")") }
        return result.output
    }
    func make(_ relative: String, text: String = "disposable fixture") throws -> String {
        let target = URL(fileURLWithPath: path).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target); return target.path
    }
    func age() throws {
        let old = Int(Date().addingTimeInterval(-60 * 86_400).timeIntervalSince1970)
        for root in [path, admin] {
            for entry in try FileTree.read(root).reversed() {
                let target = entry.relativePath.isEmpty ? root : root + "/" + entry.relativePath
                let times = [timespec(tv_sec: old, tv_nsec: 0), timespec(tv_sec: old, tv_nsec: 0)]
                let result = times.withUnsafeBufferPointer { utimensat(AT_FDCWD, target, $0.baseAddress, AT_SYMLINK_NOFOLLOW) }
                guard result == 0 else { throw SniffError.message("Could not age disposable worktree fixture") }
            }
        }
    }
    func finding(processes: ProcessInventory? = nil, preferences override: Preferences? = nil, limit: Int = 180_000) throws -> Finding {
        var inventory = ProcessInventory(); inventory.complete = true
        let items = try WorktreeInspector.inspect(repositories: [repository, path], preferences: override ?? preferences,
            processes: processes ?? inventory, catalog: fixture.catalog, manifestLimit: limit)
        #expect(Set(items.map(\.path)).count == items.count)
        #expect(items.filter { $0.path == path }.count == 1)
        return try #require(items.first { $0.path == path })
    }
    func clean(_ item: Finding, automatic: Bool = false, useCheck: @escaping @Sendable (Finding) -> String? = { _ in nil }) -> CleaningReport {
        var value = preferences; value.enabledCategories.insert(.worktree)
        return fixture.clean([item], preferences: value, automatic: automatic, useCheck: useCheck)
    }
    func dispose() { fixture.dispose() }
}

@Test func idlePublishedWorktreeRequiresManualSelectionAndPreservesOtherCheckoutsAndBranches() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    _ = try f.make("node_modules/package/index.js")
    _ = try f.git(["worktree", "add", "--detach", f.fixture.root.path + "/other", "HEAD"])
    try f.age()
    let item = try f.finding()
    #expect(item.state == .ready, "\(item.reason) \(item.details)")
    #expect(item.worktree?.status == .idle)
    #expect(item.worktree?.unpublishedCommits == 0 && item.worktree?.unmergedCommits == 0)
    #expect(!item.manifest.isEmpty && item.worktree?.removalContext != nil)
    #expect(!f.preferences.enabledCategories.contains(.worktree) && !Category.worktree.allowsAutomatic)
    #expect(f.fixture.clean([item], preferences: f.preferences).outcomes.first?.removed == false)
    #expect(f.clean(item, automatic: true).outcomes.first?.removed == false)
    let admin = f.admin
    let report = f.clean(item)
    #expect(report.outcomes.first?.removed == true)
    #expect(!FileManager.default.fileExists(atPath: f.path) && !FileManager.default.fileExists(atPath: admin))
    #expect(FileManager.default.fileExists(atPath: f.repository + "/source.swift"))
    #expect(FileManager.default.fileExists(atPath: f.fixture.root.path + "/other/source.swift"))
    #expect(try f.git(["rev-parse", "--verify", "refs/heads/fixture-idle"]).isEmpty == false)
    #expect(try f.git(["worktree", "list", "--porcelain"]).contains(f.path) == false)
}

@Test(arguments: ["unstaged", "staged", "untracked"])
func worktreeLocalChangesArePreserved(kind: String) throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    let file = try f.make(kind == "untracked" ? "new.swift" : "source.swift", text: "local work; preserve")
    if kind == "staged" { _ = try f.git(["add", "source.swift"], in: f.path) }
    let item = try f.finding()
    #expect(item.state == .protected && item.worktree?.status == .localChanges)
    #expect(item.worktree?.hasPendingChanges == true)
    #expect(f.clean(item).outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: file))
}

@Test(arguments: [false, true])
func unpublishedAndPublishedButUnmergedWorktreeCommitsArePreserved(published: Bool) throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    _ = try f.git(["commit", "--allow-empty", "-m", "pending fixture work"], in: f.path)
    if published { _ = try f.git(["update-ref", "refs/remotes/origin/fixture-feature", "HEAD"], in: f.path) }
    let item = try f.finding()
    #expect(item.worktree?.status == .pendingCommits && item.state == .protected)
    #expect(item.worktree?.unpublishedCommits == (published ? 0 : 1))
    #expect(item.worktree?.unmergedCommits == 1)
    #expect(f.clean(item).outcomes.first?.removed == false)
}

@Test func detachedWorktreeReflogKeepsEarlierUnpublishedCommits() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    _ = try f.git(["checkout", "--detach"], in: f.path)
    _ = try f.git(["commit", "--allow-empty", "-m", "unpublished detached work"], in: f.path)
    _ = try f.git(["reset", "--hard", "refs/remotes/origin/trunk-real"], in: f.path)
    let item = try f.finding()
    #expect(item.worktree?.unpublishedCommits == 0)
    #expect(item.worktree?.status == .pendingCommits && item.state == .protected)
    #expect(item.worktree?.hasPendingChanges == true)
}

@Test(arguments: ["local.db", ".env", ".claude/session.json", "scratch/state.json", "node_modules/package/local.db", "node_modules/package/.env", "node_modules/package/.git/config"])
func ignoredWorktreeStateNeverBecomesDisposable(path: String) throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    let file = try f.make(path, text: "local state must remain")
    try f.age()
    let item = try f.finding()
    #expect(item.state == .protected && item.worktree?.status == .localData)
    #expect(item.worktree?.removalContext == nil && item.manifest.isEmpty)
    #expect(f.clean(item).outcomes.first?.removed == false)
    #expect(try String(contentsOfFile: file, encoding: .utf8) == "local state must remain")
}

@Test func worktreeUseAndIncompleteProcessInventoryFailClosed() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    var processes = ProcessInventory(); processes.complete = true; processes.openPaths = [f.path]
    #expect(try f.finding(processes: processes).state == .inUse)
    processes.openPaths = []; processes.commands = ["fixture-agent --cwd \(f.path)"]
    #expect(try f.finding(processes: processes).worktree?.status == .inUse)
    #expect(try f.finding(processes: ProcessInventory()).state == .inUse)
}

@Test func worktreeHardlinkUsageIsDetectedOutsideItsPath() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    let binary = try f.make("node_modules/fixture/bin/tool")
    let external = f.fixture.root.path + "/opened-alias"
    try FileManager.default.linkItem(atPath: binary, toPath: external); try f.age()
    var processes = ProcessInventory(); processes.complete = true; processes.openPaths = [external]
    let item = try f.finding(processes: processes)
    #expect(item.state == .inUse && item.worktree?.status == .inUse)
    #expect(FileManager.default.fileExists(atPath: external))
}

@Test func worktreeLocksFlagsAndLocalGitConfigurationArePreserved() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    _ = try f.git(["worktree", "lock", f.path])
    #expect(try f.finding().worktree?.status == .locked)
    _ = try f.git(["worktree", "unlock", f.path])
    _ = try f.git(["update-index", "--assume-unchanged", "source.swift"], in: f.path)
    _ = try f.make("source.swift", text: "hidden local source change")
    #expect(try f.finding().worktree?.status == .unverified)
    _ = try f.git(["update-index", "--no-assume-unchanged", "source.swift"], in: f.path)
    _ = try f.git(["checkout", "--", "source.swift"], in: f.path)
    try Data("[fixture]\nlocal = preserve\n".utf8).write(to: URL(fileURLWithPath: f.admin + "/config.worktree"))
    #expect(try f.finding().worktree?.status == .localData)
}

@Test func unknownPrincipalRecentActivityAndPartialScansAreNotEligible() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    _ = try f.git(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"])
    #expect(try f.finding().worktree?.status == .unverified)
    _ = try f.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk-real"])
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
    #expect(try f.finding().worktree?.status == .recent)
    try f.age()
    let partial = try f.finding(limit: 2)
    #expect(partial.state == .review && partial.worktree?.removalContext == nil && partial.manifest.isEmpty)
}

@Test func excludingPrimaryProjectAlsoPreservesItsExternalWorktrees() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    var preferences = f.preferences; preferences.exclusions = [f.repository]
    let item = try f.finding(preferences: preferences)
    #expect(item.worktree?.status == .excluded && item.state == .protected)
    #expect(FileManager.default.fileExists(atPath: f.path))
}

@Test func worktreeExecutionRechecksCommitsAndGitLocksAfterProcessProbe() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    let item = try f.finding()
    #expect(item.state == .ready)
    let report = f.clean(item, useCheck: { _ in
        _ = try? f.git(["commit", "--allow-empty", "-m", "new work during probe"], in: f.path)
        return nil
    })
    #expect(report.outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: f.path + "/source.swift"))
}

@Test func worktreeExecutionRejectsForgedAdministrativePathsAndNewExclusions() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    var item = try f.finding()
    let original = item
    item.worktree?.removalContext?.administrativeDirectory = f.repository + "/.git"
    #expect(f.clean(item).outcomes.first?.removed == false)
    var preferences = f.preferences; preferences.enabledCategories.insert(.worktree); preferences.exclusions = [f.repository]
    #expect(f.fixture.clean([original], preferences: preferences).outcomes.first?.removed == false)
    preferences.exclusions = []; preferences.projectRoots = []
    #expect(f.fixture.clean([original], preferences: preferences).outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: f.path + "/source.swift"))
}

@Test func worktreePartialRemovalRestoresGitMarkerAndPreservesLateActivity() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    let item = try f.finding()
    do {
        try WorktreeRemoval.remove(item, beforeUnlink: { relative in
            if relative == ".git" { _ = try? f.make("late-file", text: "new activity; preserve") }
        })
        Issue.record("Expected a partial worktree removal")
    } catch is SecureRemoval.PartialFailure {
        #expect(FileManager.default.fileExists(atPath: f.path + "/late-file"))
        #expect(FileManager.default.fileExists(atPath: f.path + "/.git"))
        #expect(WorktreeInspector.git(f.path, ["rev-parse", "--verify", "HEAD"]).status == 0)
    }
}

@Test func secureRemovalHandlesHardlinksWithoutFollowingExternalAliases() throws {
    let f = try Fixture(); defer { f.dispose() }
    let first = try f.make(".npm/_cacache/first")
    let second = f.root.path + "/.npm/_cacache/second"
    let external = f.root.path + "/outside-link"
    try FileManager.default.linkItem(atPath: first, toPath: second)
    try FileManager.default.linkItem(atPath: first, toPath: external)
    #expect(f.clean([f.finding()]).outcomes.first?.removed == true)
    #expect(FileManager.default.fileExists(atPath: external))
    #expect(!FileManager.default.fileExists(atPath: second))
}

@Test func oldSavedFindingsDecodeWithoutWorktreeAssessment() throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    _ = try fixture.make(".npm/_cacache/file")
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.finding())) as? [String: Any])
    object.removeValue(forKey: "worktree")
    let decoded = try JSONDecoder().decode(Finding.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.worktree == nil && decoded.path == fixture.finding().path)
}

@Test func inspectionNeverExecutesRepositoryCleanOrProcessFilters() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    _ = try f.make(".gitattributes", text: "source.swift filter=sniff-fixture\n")
    _ = try f.git(["add", ".gitattributes"], in: f.path)
    _ = try f.git(["commit", "-m", "fixture attributes"], in: f.path)
    _ = try f.git(["update-ref", "refs/remotes/origin/trunk-real", "HEAD"], in: f.path)
    let marker = f.fixture.root.path + "/filter-must-not-run"
    _ = try f.git(["config", "filter.sniff-fixture.clean", "/usr/bin/touch " + marker])
    _ = try f.git(["config", "filter.sniff-fixture.process", "/usr/bin/touch " + marker])
    _ = try f.git(["config", "filter.sniff-fixture.required", "true"])
    try f.age()
    #expect(try f.finding().state == .ready)
    #expect(!FileManager.default.fileExists(atPath: marker))
}

@Test func changedRemoteReferencesAndLateGitLocksInvalidateWorktreePlans() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    let item = try f.finding()
    let report = f.clean(item, useCheck: { _ in
        _ = try? f.git(["commit", "--allow-empty", "-m", "new default branch commit"])
        _ = try? f.git(["update-ref", "refs/remotes/origin/trunk-real", "HEAD"])
        return nil
    })
    #expect(report.outcomes.first?.removed == false)
    let fresh = try f.finding()
    #expect(fresh.state == .ready)
    let locked = f.clean(fresh, useCheck: { _ in
        try? Data("fixture lock".utf8).write(to: URL(fileURLWithPath: f.admin + "/index.lock"))
        return nil
    })
    #expect(locked.outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: f.path + "/source.swift"))
}

@Test func linkedWorktreeSymlinkDoesNotTraverseItsReplacement() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    let destination = f.fixture.root.path + "/preserved-destination"
    try FileManager.default.moveItem(atPath: f.path, toPath: destination)
    try FileManager.default.createSymbolicLink(atPath: f.path, withDestinationPath: destination)
    let item = try f.finding()
    #expect(item.state == .review && item.worktree?.removalContext == nil)
    #expect(f.clean(item).outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: destination + "/source.swift"))
}

@Test func forgedPrimaryCheckoutIsNeverARemovalCandidate() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    var item = try f.finding()
    item.path = f.repository; item.manifest = try FileTree.read(f.repository)
    #expect(f.clean(item).outcomes.first?.removed == false)
    #expect(FileManager.default.fileExists(atPath: f.repository + "/.git"))
}

@Test func symlinkedAdministrativeDirectoriesRemainOutsideCleanup() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    let admin = f.admin
    let destination = f.fixture.root.path + "/preserved-admin"
    try FileManager.default.moveItem(atPath: admin, toPath: destination)
    try FileManager.default.createSymbolicLink(atPath: admin, withDestinationPath: destination)
    var processes = ProcessInventory(); processes.complete = true
    let items = try WorktreeInspector.inspect(repositories: [f.repository], preferences: f.preferences, processes: processes, catalog: f.fixture.catalog)
    #expect(items.allSatisfy { $0.state != .ready && $0.worktree?.removalContext == nil })
    #expect(FileManager.default.fileExists(atPath: destination + "/HEAD"))
    #expect(FileManager.default.fileExists(atPath: f.path + "/source.swift"))
}

@Test(arguments: ["pending", "inUse", "clean"])
func auxiliaryGitMetadataDoesNotHideWorktreeCommitsOrUsage(scenario: String) throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    try Data("fixture fetch record; preserve".utf8).write(to: URL(fileURLWithPath: f.admin + "/FETCH_HEAD"))
    if scenario == "pending" { _ = try f.git(["commit", "--allow-empty", "-m", "pending fixture"], in: f.path) }
    var inventory = ProcessInventory(); inventory.complete = true
    if scenario == "inUse" { inventory.openPaths = [f.path] }
    let item = try f.finding(processes: inventory)
    #expect(item.worktree?.unpublishedCommits == (scenario == "pending" ? 1 : 0))
    #expect(item.worktree?.status == (scenario == "pending" ? .pendingCommits : scenario == "inUse" ? .inUse : .localData))
    #expect(item.worktree?.removalContext == nil)
    #expect(item.details.contains("Metadado local: FETCH_HEAD"))
}

@Test func gitStatSettingsCannotHideLocalWorktreeSourceChanges() throws {
    let f = try WorktreeFixture(); defer { f.dispose() }
    _ = try f.git(["config", "core.trustctime", "false"])
    _ = try f.git(["config", "core.checkStat", "minimal"])
    _ = try f.git(["update-index", "--refresh"], in: f.path)
    // Git builds can record ctime in whole seconds. Make the synthetic edit cross
    // that boundary, as it would for a genuinely old worktree's cached index.
    Thread.sleep(forTimeInterval: 1.1)
    let source = f.path + "/source.swift"
    let original = try Data(contentsOf: URL(fileURLWithPath: source))
    let date = try #require(FileManager.default.attributesOfItem(atPath: source)[.modificationDate] as? Date)
    try Data(repeating: 120, count: original.count).write(to: URL(fileURLWithPath: source))
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source)
    try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(86_400)], ofItemAtPath: f.admin + "/index")
    let item = try f.finding()
    #expect(item.worktree?.status == .localChanges && item.state == .protected, "\(item.reason) \(item.worktree?.status.rawValue ?? "nil") \(item.details)")
    #expect(f.clean(item).outcomes.first?.removed == false)
    #expect(try Data(contentsOf: URL(fileURLWithPath: source)) != original)
}
