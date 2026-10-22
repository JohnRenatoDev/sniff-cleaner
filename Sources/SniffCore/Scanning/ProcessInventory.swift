import Foundation

public struct ProcessInventory: Sendable {
    public var commands: [String] = []
    public var openPaths: Set<String> = []
    public var complete = false
    public init() {}
    public static func capture() -> ProcessInventory {
        var value = ProcessInventory()
        let ps = Command.run("/bin/ps", ["-axo", "pid=,comm=,args="], timeout: 6)
        let lsof = Command.run("/usr/sbin/lsof", ["-nP", "-a", "-u", NSUserName(), "-Fn"], timeout: 18)
        value.commands = ps.output.components(separatedBy: .newlines).filter { !$0.contains("/bin/ps -axo") && !$0.contains("/usr/sbin/lsof") }
        value.openPaths = Set(lsof.output.components(separatedBy: .newlines).filter { $0.hasPrefix("n/") }.map { FileTree.canonical(String($0.dropFirst())) })
        value.complete = ps.status == 0 && !ps.timedOut && lsof.status == 0 && !lsof.timedOut
        return value
    }
    public var buildInProgress: Bool {
        let tokens = ["swift-frontend", "rustc", "cargo build", "cargo test", "xcodebuild", "ninja ", "clang -", "GradleDaemon", "dotnet build"]
        return commands.contains { command in tokens.contains { command.localizedCaseInsensitiveContains($0) } }
    }
    public func reason(path: String, tokens: [String] = [], manifest: [TreeEntry] = []) -> String? {
        guard complete else { return "O Sniff não conseguiu verificar todos os processos visíveis e preservou este item." }
        if openPaths.contains(where: { FileTree.contains(path, $0) }) { return "Um processo visível mantém arquivos ou uma pasta deste caminho abertos." }
        if commands.contains(where: { $0.contains(path) }) { return "Um processo em execução faz referência a este caminho." }
        let linked = Set(manifest.filter { !$0.stamp.isDirectory && $0.stamp.links > 1 }.map { "\($0.stamp.device):\($0.stamp.inode)" })
        if !linked.isEmpty, openPaths.contains(where: { opened in
            guard let stamp = try? FileTree.stamp(opened) else { return false }
            return linked.contains("\(stamp.device):\(stamp.inode)")
        }) { return "Um processo mantém um hardlink deste item aberto em outro caminho. Preservado." }
        if let token = tokens.first(where: { token in commands.contains { $0.localizedCaseInsensitiveContains(token) } }) { return "Ferramenta ativa: \(token.trimmingCharacters(in: .whitespaces))." }
        return nil
    }
    public static func directFileInUse(_ path: String) -> Bool? {
        let result = Command.run("/usr/sbin/lsof", ["-nP", "-Fpc", "--", path], timeout: 8)
        if result.timedOut || result.status > 1 || result.status < 0 { return nil }
        return result.output.components(separatedBy: .newlines).contains { $0.hasPrefix("p") }
    }
}
