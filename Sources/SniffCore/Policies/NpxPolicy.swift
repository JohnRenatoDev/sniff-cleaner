import Foundation
import Darwin

enum NpxPolicy {
    static func mustPreserve(_ path: String) -> Bool {
        let descriptor = open(path + "/package-lock.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return true }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size < 8_000_000,
              let data = try? handle.read(upToCount: 8_000_000), data.count < 8_000_000,
              let text = String(data: data, encoding: .utf8) else { return true }
        return text.localizedCaseInsensitiveContains("mcp") || text.contains("@modelcontextprotocol")
    }
}
