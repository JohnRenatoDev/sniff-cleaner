import Foundation
import SniffCore

public struct CLIResult: Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32 = 0, output: String) { self.status = status; self.output = output }
}

struct FindingSummary: Encodable {
    let path: String
    let category: String
    let state: String
    let title: String
    let reason: String
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let partialMeasurement: Bool
    let details: [String]
    let worktree: WorktreeSummary?
    init(_ finding: Finding, language: AppLanguage) {
        path = finding.path; category = finding.category.cliName; state = finding.state.rawValue
        title = finding.category == .docker || finding.title == finding.category.title ? Localization.text(finding.title, language: language) : finding.title
        reason = Localization.text(finding.reason, language: language); allocatedBytes = finding.allocatedBytes
        logicalBytes = finding.logicalBytes; partialMeasurement = finding.partialMeasurement
        details = finding.details.map { Localization.text($0, language: language) }
        worktree = finding.worktree.map(WorktreeSummary.init)
    }
}

struct WorktreeSummary: Encodable {
    let status: WorktreeStatus
    let repository: String
    let branch: String?
    let head: String?
    let comparisonReference: String?
    let localChanges: Int?
    let unpublishedCommits: Int?
    let unmergedCommits: Int?
    let ignoredPaths: Int?
    init(_ value: WorktreeAssessment) {
        status = value.status; repository = value.repository; branch = value.branch; head = value.head
        comparisonReference = value.comparisonReference; localChanges = value.localChanges
        unpublishedCommits = value.unpublishedCommits; unmergedCommits = value.unmergedCommits; ignoredPaths = value.ignoredPaths
    }
}

enum CLIOutput {
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func findings(_ items: [Finding], language: AppLanguage) -> String {
        items.map { item in
            let summary = FindingSummary(item, language: language)
            return "[\(summary.state)] \(LocalizedFormat.bytes(item.allocatedBytes, language: language))  \(summary.title)\n  \(item.path)\n  \(summary.reason)"
        }.joined(separator: "\n\n")
    }
    static func help(language: AppLanguage) -> String {
        func text(_ key: String) -> String { Localization.text(key, language: language) }
        let commands = [
            ("scan [--quick]", "Scan and save results. Never removes files."),
            ("list [--ready]", "Show the saved scan."),
            ("plan [--category <name>]", "Preview enabled recreatable caches."),
            ("     [--path <exact-path>]", "Select exact paths instead of categories."),
            ("     --output <new-file>", "Save a private, reviewable cleanup plan."),
            ("clean --plan <file>", "Review and confirm permanent removal."),
            ("      [--yes]", "Explicitly approve this plan without a prompt."),
            ("status", "Show the current scan and schedule settings."),
            ("history", "Show previous cleanup reports."),
            ("categories", "List stable category identifiers."),
            ("config --enable|--disable <name>", "Read or update shared settings."),
            ("       --project|--exclude <path>", "Add a project folder or preserve a path.")
        ]
        let options = [
            ("--json", "Machine-readable output."),
            ("--worktrees", "Scan only Git worktrees; never removes files."),
            ("--language en|pt|es|system", "Language for this invocation."),
            ("--state-dir <directory>", "Use a separate state directory."),
            ("--help, -h", "Show this help."),
            ("--version, -v", "Print the version.")
        ]
        func rows(_ values: [(String, String)]) -> String {
            values.map { "  " + $0.0.padding(toLength: 36, withPad: " ", startingAt: 0) + text($0.1) }.joined(separator: "\n")
        }
        return "sniff \(ProductInfo.version)\n" + text("Sniff reviews development caches before removing anything.")
            + "\n\n" + text("USAGE") + "\n  sniff <command> [options]\n\n" + text("COMMANDS") + "\n" + rows(commands)
            + "\n\n" + text("OPTIONS") + "\n" + rows(options) + "\n\n"
            + text("Plans expire 15 minutes after the scan. Settings and process checks are revalidated before removal.") + "\n"
            + text("Manual categories must be enabled explicitly. Without filters, plan only selects enabled recreatable caches.")
    }
}
