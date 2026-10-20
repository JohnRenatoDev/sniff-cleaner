import Foundation
import Testing
import SniffCore
import SniffInstallation

extension CommandFixture {
    func payload(_ name: String = "payload", identity: String = ProductInfo.bundleIdentifier, marker: String = "new") throws -> URL {
        let app = root.appendingPathComponent(name).appendingPathComponent("Sniff.app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identity, "CFBundleExecutable": "Sniff", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.3.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let helpers = app.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        for file in [executables.appendingPathComponent("Sniff"), helpers.appendingPathComponent("sniff")] {
            try Data(("#!/bin/sh\n# " + marker + "\nexit 0\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return app
    }
    func installRequest(_ payload: URL, cli: Bool = true) -> InstallationRequest {
        .init(payload: payload, applicationsDirectory: root.appendingPathComponent("Applications"), binDirectory: root.appendingPathComponent("bin"), installCLI: cli)
    }
    var installer: InstallationService { .init(stateStore: store, verifySignature: { _ in }) }
}

@Test func installerCopiesBundleAndCreatesOnlyItsOwnCommandLink() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    try fixture.store.save(PersistedState())
    let before = try Data(contentsOf: fixture.store.file)
    let result = try fixture.installer.install(fixture.installRequest(fixture.payload()))
    #expect(FileManager.default.fileExists(atPath: result.application.appendingPathComponent("Contents/MacOS/Sniff").path))
    let command = try #require(result.command)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: command.path) == result.application.appendingPathComponent("Contents/Helpers/sniff").path)
    #expect(try Data(contentsOf: fixture.store.file) == before)
}

@Test func installerRefusesUnrelatedAppsAndCommands() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    let payload = try fixture.payload()
    let other = try fixture.payload("Applications", identity: "another.application", marker: "keep")
    let bytes = try Data(contentsOf: other.appendingPathComponent("Contents/MacOS/Sniff"))
    #expect(throws: (any Error).self) { try fixture.installer.install(fixture.installRequest(payload)) }
    #expect(try Data(contentsOf: other.appendingPathComponent("Contents/MacOS/Sniff")) == bytes)
    try FileManager.default.removeItem(at: other)
    let bin = fixture.root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let existing = bin.appendingPathComponent("sniff"); try Data("keep another command".utf8).write(to: existing)
    #expect(throws: (any Error).self) { try fixture.installer.install(fixture.installRequest(payload)) }
    #expect(try String(contentsOf: existing, encoding: .utf8) == "keep another command")
}

@Test func verificationFailureDoesNotReplaceAnExistingApp() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    let payload = try fixture.payload(); let old = try fixture.payload("Applications", marker: "old")
    let bytes = try Data(contentsOf: old.appendingPathComponent("Contents/MacOS/Sniff"))
    let installer = InstallationService(stateStore: fixture.store, verifySignature: { _ in throw SniffError.message("Fixture signature failure") })
    #expect(throws: (any Error).self) { try installer.install(fixture.installRequest(payload)) }
    #expect(try Data(contentsOf: old.appendingPathComponent("Contents/MacOS/Sniff")) == bytes)
}

@Test func commandFailureAfterSwapRestoresThePreviousApp() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    let payload = try fixture.payload(); let old = try fixture.payload("Applications", marker: "old")
    let oldBytes = try Data(contentsOf: old.appendingPathComponent("Contents/MacOS/Sniff"))
    let blockedCommand = fixture.root.appendingPathComponent("bin/sniff")
    #expect(throws: (any Error).self) {
        try fixture.installer.install(fixture.installRequest(payload)) { phase in
            if phase == .installingCommand { try? FileManager.default.createDirectory(at: blockedCommand, withIntermediateDirectories: false) }
        }
    }
    #expect(try Data(contentsOf: old.appendingPathComponent("Contents/MacOS/Sniff")) == oldBytes)
}

@Test func installerRespectsTheOperationLockAndCanSkipCLI() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    let payload = try fixture.payload()
    do {
        let lock = try fixture.store.lock(); defer { withExtendedLifetime(lock) {} }
        #expect(throws: (any Error).self) { try fixture.installer.install(fixture.installRequest(payload)) }
    }
    let result = try fixture.installer.install(fixture.installRequest(payload, cli: false))
    #expect(result.command == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("bin/sniff").path))
}

@Test func installerRejectsDestinationInsidePayload() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    let payload = try fixture.payload()
    let request = InstallationRequest(payload: payload, applicationsDirectory: payload.appendingPathComponent("nested"), binDirectory: fixture.root.appendingPathComponent("bin"))
    #expect(throws: (any Error).self) { try fixture.installer.install(request) }
    #expect(!FileManager.default.fileExists(atPath: payload.appendingPathComponent("nested").path))
}

@Test func failedRecoveryPreservesThePreviousApplicationBackup() throws {
    let fixture = try CommandFixture(); defer { fixture.dispose() }
    let payload = try fixture.payload(); let old = try fixture.payload("Applications", marker: "old")
    let oldBytes = try Data(contentsOf: old.appendingPathComponent("Contents/MacOS/Sniff"))
    #expect(throws: (any Error).self) {
        try fixture.installer.install(fixture.installRequest(payload)) { phase in
            if phase == .installingCommand {
                try? FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("bin/sniff"), withIntermediateDirectories: false)
                try? FileManager.default.moveItem(at: old, to: fixture.root.appendingPathComponent("moved-new.app"))
            }
        }
    }
    let backups = try FileManager.default.contentsOfDirectory(at: old.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".sniff-install-") }
    #expect(backups.count == 1)
    let backup = try #require(backups.first)
    #expect(try Data(contentsOf: backup.appendingPathComponent("Sniff.app/Contents/MacOS/Sniff")) == oldBytes)
}
