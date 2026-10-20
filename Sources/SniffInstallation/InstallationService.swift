import Foundation
import Darwin
import SniffCore

public enum InstallationPhase: String, Sendable { case checking, copying, verifying, installingCommand, finishing }
public struct InstallationRequest: Sendable {
    public let payload: URL
    public let applicationsDirectory: URL
    public let binDirectory: URL
    public let installCLI: Bool
    public init(payload: URL, applicationsDirectory: URL, binDirectory: URL, installCLI: Bool = true) {
        self.payload = payload; self.applicationsDirectory = applicationsDirectory; self.binDirectory = binDirectory; self.installCLI = installCLI
    }
}
public struct InstallationResult: Sendable {
    public let application: URL
    public let command: URL?
}

public struct InstallationService: Sendable {
    private let stateStore: StateStore
    private let verifySignature: @Sendable (URL) throws -> Void
    public init(stateStore: StateStore = .init(), verifySignature: @escaping @Sendable (URL) throws -> Void = InstallationService.verifySignature) {
        self.stateStore = stateStore; self.verifySignature = verifySignature
    }
    public static func verifySignature(_ url: URL) throws {
        let result = Command.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path], timeout: 45)
        guard result.status == 0 && !result.timedOut else { throw SniffError.message("The application signature could not be verified. Download the installer again.") }
    }
    public func install(_ request: InstallationRequest, progress: @Sendable (InstallationPhase) -> Void = { _ in }) throws -> InstallationResult {
        let files = FileManager.default
        progress(.checking)
        let lock = try stateStore.lock(); defer { withExtendedLifetime(lock) {} }
        try validateBundle(request.payload)
        let parent = URL(fileURLWithPath: FileTree.canonical(request.applicationsDirectory.standardizedFileURL.path), isDirectory: true)
        guard !FileTree.contains(FileTree.canonical(request.payload.path), parent.path) else { throw SniffError.message("Choose an installation folder outside the installer payload.") }
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        guard files.isWritableFile(atPath: parent.path) else { throw SniffError.message("The selected folder is not writable. Choose a folder in your home directory.") }
        let target = parent.appendingPathComponent("Sniff.app")
        let oldStamp = try? FileTree.stamp(target.path)
        if let oldStamp {
            guard !oldStamp.isSymlink else { throw SniffError.message("The existing application is a symbolic link. Choose another installation folder.") }
            try validateBundle(target, requireCLI: false)
            let processes = Command.run("/bin/ps", ["-axo", "comm=,args="], timeout: 6)
            guard processes.status == 0 && !processes.timedOut else { throw SniffError.message("Could not check running applications. Try again before updating Sniff.") }
            guard !processes.output.contains(target.path + "/Contents/") else { throw SniffError.message("Quit the installed Sniff app and its CLI, then try again.") }
        }
        let bin = request.binDirectory.resolvingSymlinksInPath().standardizedFileURL
        let command = bin.appendingPathComponent("sniff")
        let oldCommandStamp = request.installCLI ? try? FileTree.stamp(command.path) : nil
        if request.installCLI, oldCommandStamp != nil { try validateExistingCommand(command) }
        let stage = parent.appendingPathComponent(".sniff-install-" + UUID().uuidString)
        try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var preserveBackup = false
        defer { if !preserveBackup { try? files.removeItem(at: stage) } }
        let incoming = stage.appendingPathComponent("Sniff.app")
        progress(.copying); try files.copyItem(at: request.payload, to: incoming)
        progress(.verifying); try validateBundle(incoming); try verifySignature(incoming)
        var commandStage: URL?
        if request.installCLI {
            try files.createDirectory(at: bin, withIntermediateDirectories: true)
            let temporary = bin.appendingPathComponent(".sniff-command-" + UUID().uuidString)
            try files.createSymbolicLink(at: temporary, withDestinationURL: target.appendingPathComponent("Contents/Helpers/sniff"))
            commandStage = temporary
        }
        defer { if let commandStage { try? files.removeItem(at: commandStage) } }
        guard (try? FileTree.stamp(target.path)) == oldStamp else { throw SniffError.message("The installation folder changed. Nothing was replaced; try again.") }
        if request.installCLI { guard (try? FileTree.stamp(command.path)) == oldCommandStamp else { throw SniffError.message("The existing sniff command changed. Nothing was replaced; try again.") } }
        progress(.finishing)
        let replacing = oldStamp != nil
        let committed = replacing ? renamex_np(incoming.path, target.path, UInt32(RENAME_SWAP)) : rename(incoming.path, target.path)
        guard committed == 0 else { throw SniffError.message("Could not move Sniff into the installation folder.") }
        if let commandStage {
            progress(.installingCommand)
            if rename(commandStage.path, command.path) != 0 {
                let rolledBack = replacing ? renamex_np(incoming.path, target.path, UInt32(RENAME_SWAP)) : rename(target.path, incoming.path)
                if rolledBack != 0 {
                    preserveBackup = true
                    throw SniffError.message(Localization.text("The command could not be installed and automatic recovery failed. A backup was preserved at {0}.", arguments: [incoming.path]))
                }
                throw SniffError.message("The command could not be installed. The previous application was restored.")
            }
        }
        progress(.finishing)
        return InstallationResult(application: target, command: request.installCLI ? command : nil)
    }
    private func validateBundle(_ url: URL, requireCLI: Bool = true) throws {
        guard let stamp = try? FileTree.stamp(url.path), stamp.isDirectory, !stamp.isSymlink,
              let bundle = Bundle(url: url), bundle.bundleIdentifier == ProductInfo.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "Sniff",
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/Sniff").path),
              !requireCLI || FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/Helpers/sniff").path) else {
            throw SniffError.message("This folder does not contain a valid Sniff application. No existing application was replaced.")
        }
    }
    private func validateExistingCommand(_ url: URL) throws {
        guard let stamp = try? FileTree.stamp(url.path), stamp.isSymlink,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            throw SniffError.message("A different sniff command already exists. Install without the CLI or choose another command folder.")
        }
        let resolved = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        guard resolved.lastPathComponent == "sniff", resolved.deletingLastPathComponent().lastPathComponent == "Helpers" else {
            throw SniffError.message("A different sniff command already exists. Install without the CLI or choose another command folder.")
        }
        let app = resolved.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try validateBundle(app, requireCLI: false)
    }
}
