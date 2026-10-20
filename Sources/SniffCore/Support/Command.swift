import Foundation

public struct CommandResult: Sendable {
    public var status: Int32
    public var output: String
    public var timedOut: Bool
}

public enum Command {
    /// Argument vectors only. No shell and no interpolated command strings.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 12) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let inherited = ProcessInfo.processInfo.environment
        let keys = ["HOME", "USER", "LOGNAME", "TMPDIR", "XDG_CONFIG_HOME", "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"]
        var environment = inherited.filter { keys.contains($0.key) }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        // A temporary file avoids pipe backpressure and unbounded buffering while the child runs.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("sniff-command-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: temporary) else { return .init(status: -1, output: "Falha ao preparar o comando.", timedOut: false) }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .init(status: -1, output: error.localizedDescription, timedOut: false) }
        let end = Date().addingTimeInterval(timeout)
        var outputExceeded = false
        while process.isRunning && Date() < end {
            if let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size]) as? NSNumber, size.int64Value > 24_000_000 { outputExceeded = true; break }
            Thread.sleep(forTimeInterval: 0.03)
        }
        let timedOut = process.isRunning && !outputExceeded
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.08); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit()
        guard !outputExceeded, let reader = try? FileHandle(forReadingFrom: temporary) else { return .init(status: -1, output: "Saída excedeu o limite seguro.", timedOut: timedOut) }
        defer { try? reader.close() }
        let data = (try? reader.read(upToCount: 24_000_001)) ?? Data()
        guard data.count <= 24_000_000 else { return .init(status: -1, output: "Saída excedeu o limite seguro.", timedOut: timedOut) }
        return .init(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self), timedOut: timedOut)
    }
}
