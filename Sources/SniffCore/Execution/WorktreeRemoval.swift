import Foundation
import Darwin

enum WorktreeRemoval {
    static func remove(_ finding: Finding, beforeUnlink: ((String) -> Void)? = nil) throws {
        guard let context = finding.worktree?.removalContext else {
            throw SniffError.message("Worktree sem comprovação de segurança. Analise novamente.")
        }
        guard try FileTree.read(context.administrativeDirectory, limit: 200) == context.administrativeManifest else {
            throw SniffError.message("O registro da worktree mudou. Preservada; analise novamente.")
        }
        do {
            try SecureRemoval.remove(path: finding.path, manifest: finding.manifest, lastRootEntry: ".git", beforeUnlink: beforeUnlink)
        } catch {
            // Keep a partially removed worktree usable by Git, even if a late writer added
            // a root entry between deleting the final .git file and removing the directory.
            restoreMarker(finding, context: context)
            throw error
        }
        do {
            guard try FileTree.read(context.administrativeDirectory, limit: 200) == context.administrativeManifest else {
                throw SniffError.message("Os metadados Git mudaram e foram preservados para revisão.")
            }
            // Remove this one verified administrative directory. No force, global prune,
            // branch deletion, hooks, or traversal through Git-controlled symlinks.
            try SecureRemoval.remove(path: context.administrativeDirectory, manifest: context.administrativeManifest)
        } catch {
            throw SecureRemoval.PartialFailure(reason: "A pasta foi removida, mas o registro Git precisa de revisão.",
                                               allocatedBytes: FileTree.sizes(finding.manifest).allocated)
        }
    }

    private static func restoreMarker(_ finding: Finding, context: WorktreeRemovalContext) {
        guard let original = finding.manifest.first(where: { $0.relativePath.isEmpty })?.stamp else { return }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        for component in (finding.path as NSString).pathComponents.dropFirst() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return }
            close(descriptor); descriptor = next
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_dev == original.device, metadata.st_ino == original.inode else { return }
        let marker = openat(descriptor, ".git", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard marker >= 0 else { return }
        let handle = FileHandle(fileDescriptor: marker, closeOnDealloc: true)
        defer { try? handle.close() }
        try? handle.write(contentsOf: Data("gitdir: \(context.administrativeDirectory)\n".utf8))
    }
}
