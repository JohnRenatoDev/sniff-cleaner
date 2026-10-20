import Foundation
import Darwin
import SniffCore

public struct PlanDocument: Codable, Sendable {
    public let schemaVersion: Int
    public let home: String
    public let scannedAt: Date
    public let createdAt: Date
    public let findings: [Finding]
    public init(home: String, scannedAt: Date, findings: [Finding]) {
        schemaVersion = 1; self.home = home; self.scannedAt = scannedAt; createdAt = .now; self.findings = findings
    }
    public func write(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 64 * 1_024 * 1_024 else { throw CLIFailure.usage("The plan is too large. Select fewer items.") }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CLIFailure.usage("Cannot create plan at {0}. Choose a new file name in an existing folder.", url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); try? FileManager.default.removeItem(at: url); throw error }
    }
    public static func read(from url: URL, expectedHome: String) throws -> PlanDocument {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CLIFailure.usage("Cannot read the plan file: {0}.", url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 64 * 1_024 * 1_024,
              let data = try handle.read(upToCount: 64 * 1_024 * 1_024 + 1), data.count <= 64 * 1_024 * 1_024 else { throw CLIFailure.usage("Invalid plan file.") }
        let plan = try JSONDecoder().decode(PlanDocument.self, from: data)
        guard plan.schemaVersion == 1, plan.home == expectedHome, !plan.findings.isEmpty else { throw CLIFailure.usage("This plan is empty, unsupported or belongs to another home folder.") }
        let age = Date().timeIntervalSince(plan.scannedAt)
        guard age >= -30 && age < 900 else { throw CLIFailure.usage("The plan has expired. Scan again and create a new plan.") }
        guard Set(plan.findings.map(\.path)).count == plan.findings.count else { throw CLIFailure.usage("The plan contains duplicate paths.") }
        return plan
    }
}
