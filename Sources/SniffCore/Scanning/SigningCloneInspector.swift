import Foundation

public enum SigningCloneInspector {
    public static func inspect(processes: ProcessInventory, preferences: Preferences, notices: inout [String]) -> [Finding] {
        let temporary = FileTree.canonical(FileManager.default.temporaryDirectory.path)
        let parent = URL(fileURLWithPath: temporary).deletingLastPathComponent().path
        let x = parent + "/X"
        guard let groups = try? FileManager.default.contentsOfDirectory(atPath: x) else { return [] }
        var findings: [Finding] = []
        for group in groups where group.hasSuffix(".code_sign_clone") {
            guard let clones = try? FileManager.default.contentsOfDirectory(atPath: x + "/" + group) else { notices.append("Sem acesso ao clone: \(group)"); continue }
            for clone in clones where clone.hasPrefix("code_sign_clone.") {
                let path = x + "/" + group + "/" + clone
                var item = Finding(path: path, title: group.replacingOccurrences(of: ".code_sign_clone", with: ""), category: .signingClone, ruleID: "signing-inspect", state: .review, reason: "Esta versão só inspeciona clones de assinatura e mantém os arquivos.")
                do {
                    let tree = try FileTree.read(path)
                    let size = FileTree.sizes(tree); item.logicalBytes = size.logical; item.allocatedBytes = size.allocated; item.sharedLinks = size.shared
                    if let reason = processes.reason(path: path) { item.state = .inUse; item.reason = reason }
                    let bundles = try FileManager.default.contentsOfDirectory(atPath: path)
                    for bundle in bundles {
                        let root = path + "/" + bundle
                        guard let data = FileManager.default.contents(atPath: root + "/Contents/Info.plist"), let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                        item.details.append("\(bundle) · versão \(plist["CFBundleShortVersionString"] as? String ?? "desconhecida")")
                        if let name = plist["CFBundleExecutable"] as? String {
                            // Direct file lookup lets lsof match device/inode, including hardlinks whose displayed path is /Applications.
                            let executable = root + "/Contents/MacOS/" + name
                            let used = ProcessInventory.directFileInUse(executable)
                            if used == true { item.state = .inUse; item.reason = "O executável está em uso, confirmado pela consulta direta ao arquivo (inode)." }
                            if used == nil { item.details.append("A consulta direta ao executável foi inconclusiva. O Sniff preservou o clone.") }
                            if let stamp = try? FileTree.stamp(executable), stamp.links > 1 { item.details.append("O executável tem \(stamp.links) hardlinks. A soma dos tamanhos pode incluir blocos compartilhados.") }
                        }
                    }
                } catch { item.state = .inaccessible; item.reason = error.localizedDescription }
                findings.append(item)
            }
        }
        return findings
    }
}
