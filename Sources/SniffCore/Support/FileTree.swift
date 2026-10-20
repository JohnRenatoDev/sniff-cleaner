import Foundation
import Darwin

public enum FileTree {
    public static func stamp(_ path: String) throws -> FileStamp {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw SniffError.message("Não foi possível ler: \(path) (\(String(cString: strerror(errno))))") }
        return stamp(info)
    }
    static func stamp(_ value: stat) -> FileStamp {
        .init(device: value.st_dev, inode: value.st_ino, mode: value.st_mode, size: value.st_size, blocks: value.st_blocks, links: value.st_nlink,
              modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanos: Int64(value.st_mtimespec.tv_nsec),
              changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanos: Int64(value.st_ctimespec.tv_nsec))
    }
    public static func contains(_ parent: String, _ path: String) -> Bool { path == parent || path.hasPrefix(parent + "/") }
    public static func canonical(_ path: String) -> String {
        if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        // Resolve an existing ancestor while retaining nonexistent exclusion components.
        let parent = (path as NSString).deletingLastPathComponent
        if parent != path, !parent.isEmpty { return canonical(parent) + "/" + (path as NSString).lastPathComponent }
        return path
    }
    public static func hasSymlinkAncestor(_ path: String) -> Bool {
        var current = ""
        for component in (path as NSString).pathComponents.dropFirst() {
            if component == ".." || component == "." { return true }
            current += "/" + component
            if let info = try? stamp(current), info.isSymlink { return true }
        }
        return false
    }
    public static func read(_ path: String, limit: Int = 180_000) throws -> [TreeEntry] {
        guard !hasSymlinkAncestor(path) else { throw SniffError.message("Caminho com link simbólico preservado.") }
        var entries: [TreeEntry] = []
        let initial = try stamp(path)
        func visit(_ absolute: String, _ relative: String, depth: Int) throws {
            try Task.checkCancellation()
            guard entries.count < limit, depth < 90 else { throw SniffError.message("Análise parcial: limite de arquivos ou profundidade. Item preservado.") }
            let info = try stamp(absolute)
            guard info.device == initial.device else { throw SniffError.message("Outro volume encontrado. Item preservado.") }
            entries.append(.init(relativePath: relative, stamp: info))
            if info.isDirectory {
                for child in try FileManager.default.contentsOfDirectory(atPath: absolute).sorted() {
                    try visit(absolute + "/" + child, relative.isEmpty ? child : relative + "/" + child, depth: depth + 1)
                }
            }
        }
        try visit(path, "", depth: 0)
        return entries
    }
    public static func sizes(_ entries: [TreeEntry]) -> (logical: Int64, allocated: Int64, shared: Bool) {
        var seen = Set<String>(); var logical: Int64 = 0; var allocated: Int64 = 0; var shared = false
        for entry in entries {
            let info = entry.stamp
            if !info.isDirectory { logical += info.size }
            if seen.insert("\(info.device):\(info.inode)").inserted { allocated += info.blocks * 512 }
            if !info.isDirectory && info.links > 1 { shared = true }
        }
        return (logical, allocated, shared)
    }
    public static func boundedMeasurement(_ path: String, seconds: TimeInterval = 0.18, limit: Int = 3_000) throws -> (logical: Int64, allocated: Int64, shared: Bool, partial: Bool) {
        guard !hasSymlinkAncestor(path) else { throw SniffError.message("Caminho com link simbólico preservado.") }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        let device = try stamp(path).device
        var stack = [path]; var entries: [TreeEntry] = []
        while let current = stack.popLast() {
            try Task.checkCancellation()
            if entries.count >= limit || ProcessInfo.processInfo.systemUptime >= deadline { stack.append(current); break }
            let info = try stamp(current)
            if info.device != device { continue }
            entries.append(.init(relativePath: "", stamp: info))
            if info.isDirectory { stack += try FileManager.default.contentsOfDirectory(atPath: current).sorted().map { current + "/" + $0 } }
        }
        let size = sizes(entries)
        return (size.logical, size.allocated, size.shared, !stack.isEmpty)
    }
    public static func available(_ path: String) -> Int64? {
        guard let values = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = values[.systemFreeSize] as? NSNumber else { return nil }
        return free.int64Value
    }
}
