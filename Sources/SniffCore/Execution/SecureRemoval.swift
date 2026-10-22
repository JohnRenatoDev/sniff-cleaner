import Foundation
import Darwin

enum SecureRemoval {
    struct PartialFailure: Error {
        let reason: String
        let allocatedBytes: Int64
    }
    /// Directory descriptors and O_NOFOLLOW keep each unlink inside the analyzed tree.
    /// Only manifest entries are removed. Unexpected new children cause ENOTEMPTY and a partial result.
    static func remove(path: String, manifest: [TreeEntry], lastRootEntry: String? = nil, beforeUnlink: ((String) -> Void)? = nil) throws {
        var removedCount = 0; var removedAllocated: Int64 = 0; var seen = Set<String>()
        guard let root = manifest.first(where: { $0.relativePath.isEmpty }) else { throw SniffError.message("Plano sem manifesto.") }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SniffError.message("Não foi possível abrir a raiz.") }
        defer { close(descriptor) }
        for component in ((path as NSString).deletingLastPathComponent as NSString).pathComponents.dropFirst() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw SniffError.message("Um diretório mudou, está sem acesso ou virou um link. Preservado.") }
            close(descriptor); descriptor = next
        }
        let children = Dictionary(grouping: manifest.filter { !$0.relativePath.isEmpty }) { entry -> String in
            let parent = (entry.relativePath as NSString).deletingLastPathComponent
            return parent == "." ? "" : parent
        }
        let aliases = Dictionary(grouping: manifest.filter { $0.stamp.mode & 0o170000 == 0o100000 }) { "\($0.stamp.device):\($0.stamp.inode)" }
        var expected = Dictionary(uniqueKeysWithValues: manifest.map { ($0.relativePath, $0.stamp) })
        func delete(_ parent: Int32, name: String, entry: TreeEntry) throws {
            var current = stat()
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw SniffError.message("Item não está mais disponível: \(name)") }
            let stamp = FileTree.stamp(current)
            guard stamp == expected[entry.relativePath] else { throw SniffError.message("Item mudou depois da análise: \(name). Preservado.") }
            if stamp.isDirectory {
                let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard fd >= 0 else { throw SniffError.message("Diretório sem acesso: \(name)") }
                defer { close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0, opened.st_ino == stamp.inode, opened.st_dev == stamp.device else { throw SniffError.message("Diretório substituído. Preservado.") }
                let ordered = children[entry.relativePath, default: []].sorted {
                    let leftLast = entry.relativePath.isEmpty && $0.relativePath == lastRootEntry
                    let rightLast = entry.relativePath.isEmpty && $1.relativePath == lastRootEntry
                    return leftLast != rightLast ? !leftLast : $0.relativePath < $1.relativePath
                }
                for child in ordered {
                    try delete(fd, name: (child.relativePath as NSString).lastPathComponent, entry: child)
                }
                // Re-check identity only; our own removals changed directory timestamps.
                var final = stat()
                guard fstatat(parent, name, &final, AT_SYMLINK_NOFOLLOW) == 0, final.st_ino == stamp.inode, final.st_dev == stamp.device else { throw SniffError.message("Diretório substituído durante a operação.") }
                beforeUnlink?(entry.relativePath)
                guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw SniffError.message("Diretório preservado ou remoção parcial: \(name) (\(String(cString: strerror(errno))))") }
            } else {
                let key = "\(stamp.device):\(stamp.inode)"
                let siblings = aliases[key, default: []]
                let linkedDescriptor = siblings.count > 1 ? openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) : -1
                defer { if linkedDescriptor >= 0 { close(linkedDescriptor) } }
                if siblings.count > 1 {
                    var held = stat()
                    guard linkedDescriptor >= 0, fstat(linkedDescriptor, &held) == 0, FileTree.stamp(held) == stamp else {
                        throw SniffError.message("Hardlink mudou durante a remoção. Preservado.")
                    }
                }
                beforeUnlink?(entry.relativePath)
                guard unlinkat(parent, name, 0) == 0 else { throw SniffError.message("Falha ao remover \(name): \(String(cString: strerror(errno)))") }
                removedCount += 1
                if seen.insert(key).inserted { removedAllocated += stamp.blocks * 512 }
                if linkedDescriptor >= 0 {
                    var held = stat()
                    guard fstat(linkedDescriptor, &held) == 0 else { throw SniffError.message("Hardlink mudou durante a remoção. Preservado.") }
                    let after = FileTree.stamp(held)
                    guard after.device == stamp.device, after.inode == stamp.inode, after.mode == stamp.mode,
                          after.size == stamp.size, after.modifiedSeconds == stamp.modifiedSeconds, after.modifiedNanos == stamp.modifiedNanos else {
                        throw SniffError.message("Hardlink mudou durante a remoção. Preservado.")
                    }
                    for sibling in siblings {
                        expected[sibling.relativePath]?.changedSeconds = after.changedSeconds
                        expected[sibling.relativePath]?.changedNanos = after.changedNanos
                        expected[sibling.relativePath]?.links = after.links
                    }
                }
                return
            }
            removedCount += 1
            if seen.insert("\(stamp.device):\(stamp.inode)").inserted { removedAllocated += stamp.blocks * 512 }
        }
        do { try delete(descriptor, name: (path as NSString).lastPathComponent, entry: root) }
        catch {
            if removedCount > 0 { throw PartialFailure(reason: error.localizedDescription, allocatedBytes: removedAllocated) }
            throw error
        }
    }
}
