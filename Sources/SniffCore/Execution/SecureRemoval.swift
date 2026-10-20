import Foundation
import Darwin

enum SecureRemoval {
    /// Directory descriptors and O_NOFOLLOW keep each unlink inside the analyzed tree.
    /// Only manifest entries are removed. Unexpected new children cause ENOTEMPTY and a partial result.
    static func remove(path: String, manifest: [TreeEntry]) throws {
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
        func delete(_ parent: Int32, name: String, entry: TreeEntry) throws {
            var current = stat()
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw SniffError.message("Item não está mais disponível: \(name)") }
            let stamp = FileTree.stamp(current)
            guard stamp == entry.stamp else { throw SniffError.message("Item mudou depois da análise: \(name). Preservado.") }
            if stamp.isDirectory {
                let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard fd >= 0 else { throw SniffError.message("Diretório sem acesso: \(name)") }
                defer { close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0, opened.st_ino == stamp.inode, opened.st_dev == stamp.device else { throw SniffError.message("Diretório substituído. Preservado.") }
                for child in children[entry.relativePath, default: []] {
                    try delete(fd, name: (child.relativePath as NSString).lastPathComponent, entry: child)
                }
                // Re-check identity only; our own removals changed directory timestamps.
                var final = stat()
                guard fstatat(parent, name, &final, AT_SYMLINK_NOFOLLOW) == 0, final.st_ino == stamp.inode, final.st_dev == stamp.device else { throw SniffError.message("Diretório substituído durante a operação.") }
                guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw SniffError.message("Diretório preservado ou remoção parcial: \(name) (\(String(cString: strerror(errno))))") }
            } else {
                guard unlinkat(parent, name, 0) == 0 else { throw SniffError.message("Falha ao remover \(name): \(String(cString: strerror(errno)))") }
            }
        }
        try delete(descriptor, name: (path as NSString).lastPathComponent, entry: root)
    }
}
