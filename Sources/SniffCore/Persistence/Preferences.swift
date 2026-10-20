import Foundation
import Darwin

public enum ScheduleMode: String, Codable, CaseIterable, Sendable {
    case analyze, automatic
    public var title: String { self == .analyze ? "Analisar e avisar" : "Limpar caches escolhidos" }
}

public struct Preferences: Codable, Sendable {
    public var enabledCategories: Set<Category> = Set(Category.allCases.filter { $0.allowsAutomatic })
    public var exclusions: [String] = []
    public var projectRoots: [String] = []
    public var retentionDays = 14
    public var logRetentionDays = 30
    public var scheduleEnabled = false
    public var scheduleMode: ScheduleMode = .analyze
    public var intervalHours = 24
    public var nextRun: Date?
    public var monitorEnabled = false
    public var notificationsEnabled = false
    public var lastMonitor: Date?
    public init() {}
}

public struct PersistedState: Codable, Sendable {
    public var preferences = Preferences()
    public var lastScan: ScanSnapshot?
    public var history: [CleaningReport] = []
    public var schedulerMessage: String?
    public var schedulerLastWake: Date?
    public var monitorAllocated: Int64?
    public var monitorChangedPaths: [String] = []
    public init() {}
}

public struct StateStore: Sendable {
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Sniff")) { self.directory = directory }
    public var file: URL { directory.appendingPathComponent("state.json") }
    public func load() -> PersistedState {
        var data = try? Data(contentsOf: file)
        if data == nil, directory == StateStore().directory {
            // Preserve this task's initial local analysis after the public name changed.
            let previous = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Fuca/state.json")
            data = try? Data(contentsOf: previous)
        }
        guard let data, let value = try? JSONDecoder().decode(PersistedState.self, from: data) else { return PersistedState() }
        return value
    }
    public func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(state)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func lock() throws -> StoreLock {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent("operation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SniffError.message("Não foi possível abrir a trava de execução.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw SniffError.message("Outra análise ou limpeza do Sniff está em andamento.") }
        return StoreLock(fd: fd)
    }
}

public final class StoreLock: Sendable {
    private let fd: Int32
    init(fd: Int32) { self.fd = fd }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

public enum SniffError: Error, LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}
