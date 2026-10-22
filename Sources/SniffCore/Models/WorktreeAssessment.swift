import Foundation

public enum WorktreeStatus: String, Codable, Sendable {
    case idle, inUse, localChanges, pendingCommits, localData, locked, recent, excluded, missing, unverified
}

public struct WorktreeAssessment: Codable, Sendable {
    public var status: WorktreeStatus = .unverified
    public var repository: String
    public var branch: String?
    public var head: String?
    public var comparisonReference: String?
    public var localChanges: Int?
    public var unpublishedCommits: Int?
    public var unmergedCommits: Int?
    public var ignoredPaths: Int?
    public var removalContext: WorktreeRemovalContext?
    public init(repository: String, status: WorktreeStatus = .unverified, branch: String? = nil, head: String? = nil) {
        self.repository = repository; self.status = status; self.branch = branch; self.head = head
    }
    public var hasPendingChanges: Bool {
        (localChanges ?? 0) > 0 || (unpublishedCommits ?? 0) > 0 || (unmergedCommits ?? 0) > 0
            || status == .pendingCommits || status == .localChanges || status == .localData || status == .locked
    }
}

/// Captured only for eligible linked worktrees. Every field is checked again before removal.
public struct WorktreeRemovalContext: Codable, Equatable, Sendable {
    public var repository: String
    public var commonDirectory: String
    public var administrativeDirectory: String
    public var head: String
    public var branch: String?
    public var integrationReference: String
    public var integrationHead: String
    public var remoteReferences: [String]
    public var administrativeManifest: [TreeEntry]
}
