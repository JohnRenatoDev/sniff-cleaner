import Foundation

public enum WorktreeInspector {
    struct Record: Equatable {
        var path: String
        var head: String?
        var branch: String?
        var locked = false
        var bare = false
    }

    static func records(_ output: String) -> [Record] {
        output.components(separatedBy: "\0\0").compactMap { block in
            let fields = block.components(separatedBy: "\0")
            guard let path = fields.first, path.hasPrefix("worktree ") else { return nil }
            var record = Record(path: String(path.dropFirst(9)))
            for field in fields.dropFirst() {
                if field.hasPrefix("HEAD ") { record.head = String(field.dropFirst(5)) }
                if field.hasPrefix("branch ") { record.branch = String(field.dropFirst(7)) }
                if field == "locked" || field.hasPrefix("locked ") { record.locked = true }
                if field == "bare" { record.bare = true }
            }
            return record
        }
    }

    public static func inspect(repositories: [String], preferences: Preferences, processes: ProcessInventory,
                               catalog: RuleCatalog, manifestLimit: Int = 180_000,
                               progress: @Sendable (String) -> Void = { _ in }) throws -> [Finding] {
        var findings: [Finding] = []
        var seenRepositories = Set<String>()
        var seenWorktrees = Set<String>()
        for repository in repositories {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: repository + "/.git"), !FileTree.hasSymlinkAncestor(repository) else { continue }
            let common = git(repository, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
            guard common.status == 0, !common.timedOut else { continue }
            let commonLocation = line(common.output)
            guard !FileTree.hasSymlinkAncestor(commonLocation) else { continue }
            let commonPath = FileTree.canonical(commonLocation)
            guard let stamp = try? FileTree.stamp(commonPath), stamp.isDirectory,
                  seenRepositories.insert(identity(stamp)).inserted else { continue }
            let list = git(repository, ["worktree", "list", "--porcelain", "-z"])
            guard list.status == 0, !list.timedOut, let primary = records(list.output).first else { continue }
            for record in records(list.output).dropFirst() {
                try Task.checkCancellation()
                let key = (try? FileTree.stamp(record.path)).map(identity) ?? record.path
                guard seenWorktrees.insert(key).inserted else { continue }
                progress("Inspecionando worktree \(URL(fileURLWithPath: record.path).lastPathComponent)…")
                findings.append(try inspect(record: record, repository: primary.path, commonDirectory: commonPath,
                                            preferences: preferences, processes: processes, catalog: catalog, manifestLimit: manifestLimit))
            }
        }
        try Task.checkCancellation()
        return findings
    }

    static func recognizes(_ finding: Finding, preferences: Preferences, catalog: RuleCatalog) -> Bool {
        guard finding.ruleID == "git-worktree", finding.category == .worktree,
              finding.worktree?.status == .idle, let context = finding.worktree?.removalContext,
              finding.path != context.repository,
              authorized(repository: context.repository, worktree: finding.path, preferences: preferences, catalog: catalog),
              URL(fileURLWithPath: context.administrativeDirectory).deletingLastPathComponent().path == context.commonDirectory + "/worktrees",
              !context.administrativeManifest.isEmpty else { return false }
        return !FileTree.hasSymlinkAncestor(finding.path) && !FileTree.hasSymlinkAncestor(context.administrativeDirectory)
    }

    static func revalidate(_ finding: Finding, preferences: Preferences, catalog: RuleCatalog) throws {
        guard recognizes(finding, preferences: preferences, catalog: catalog), let expected = finding.worktree?.removalContext else {
            throw SniffError.message("Worktree sem comprovação de segurança. Analise novamente.")
        }
        let list = try checkedGit(expected.repository, ["worktree", "list", "--porcelain", "-z"])
        let entries = records(list)
        guard entries.first?.path == expected.repository,
              let entry = entries.dropFirst().first(where: { $0.path == finding.path }) else {
            throw SniffError.message("O registro da worktree mudou. Preservada; analise novamente.")
        }
        // The executor runs its injected, fresh process probe separately. Git and file evidence
        // are deliberately rechecked after that probe as well.
        var processes = ProcessInventory(); processes.complete = true
        let current = try inspect(record: entry, repository: expected.repository, commonDirectory: expected.commonDirectory,
                                  preferences: preferences, processes: processes, catalog: catalog, manifestLimit: 180_000)
        guard current.state == .ready, current.worktree?.removalContext == expected,
              current.manifest == finding.manifest else {
            throw SniffError.message("A worktree mudou ou ganhou pendências. Preservada; analise novamente.")
        }
    }

    private static func inspect(record: Record, repository: String, commonDirectory: String, preferences: Preferences,
                                processes: ProcessInventory, catalog: RuleCatalog, manifestLimit: Int) throws -> Finding {
        var item = Finding(path: record.path, title: URL(fileURLWithPath: record.path).lastPathComponent,
                           category: .worktree, ruleID: "git-worktree", state: .review,
                           reason: "Não foi possível verificar todas as condições desta worktree. Preservada.")
        item.worktree = WorktreeAssessment(repository: repository, branch: record.branch, head: record.head)
        func preserved(_ status: WorktreeStatus, _ reason: String, state: FindingState = .protected) -> Finding {
            var result = item
            result.state = state; result.reason = reason; result.worktree?.status = status
            result.worktree?.removalContext = nil
            if let size = try? FileTree.boundedMeasurement(record.path) {
                result.logicalBytes = size.logical; result.allocatedBytes = size.allocated
                result.sharedLinks = size.shared; result.partialMeasurement = size.partial
            }
            return result
        }
        guard let root = try? FileTree.stamp(record.path), root.isDirectory,
              !FileTree.hasSymlinkAncestor(record.path) else {
            return preserved(.missing, "Registro sem diretório presente ou caminho com symlink. Nenhuma remoção.", state: .review)
        }
        guard let parent = try? FileTree.stamp(URL(fileURLWithPath: record.path).deletingLastPathComponent().path), parent.device == root.device else {
            return preserved(.unverified, "Outro volume encontrado. Item preservado.", state: .review)
        }
        if let reason = catalog.protectedReason(item, preferences: preferences) { return preserved(.excluded, reason) }
        if record.locked { return preserved(.locked, "Worktree bloqueada no Git. Preservada.") }
        let usage = processes.reason(path: record.path)
        do {
            let contextPaths = try administrativePaths(path: record.path, repository: repository, commonDirectory: commonDirectory)
            let admin = contextPaths.admin
            let adminManifest = try FileTree.read(admin, limit: 200)
            let metadataFiles: Set<String> = ["", "HEAD", "index", "ORIG_HEAD", "COMMIT_EDITMSG", "commondir", "gitdir", "logs", "logs/HEAD", "refs"]
            let metadataDirectories: Set<String> = ["", "logs", "refs"]
            if adminManifest.contains(where: { $0.relativePath.hasSuffix(".lock") || ["locked", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-apply", "rebase-merge", "sequencer", "BISECT_LOG", "BISECT_START"].contains($0.relativePath) }) {
                return preserved(.locked, "Há uma operação Git em andamento. Worktree preservada.")
            }
            if adminManifest.contains(where: { $0.stamp.isSymlink || (metadataFiles.contains($0.relativePath) && metadataDirectories.contains($0.relativePath) != $0.stamp.isDirectory) }) {
                return preserved(.localData, "A worktree tem configurações ou metadados locais que precisam ser preservados.")
            }
            let extraMetadata = adminManifest.filter { !metadataFiles.contains($0.relativePath) }
            item.details += extraMetadata.prefix(4).map { "Metadado local: " + $0.relativePath }
            let shallow = try checkedGit(record.path, ["rev-parse", "--is-shallow-repository"])
            guard line(shallow) == "false", !FileManager.default.fileExists(atPath: commonDirectory + "/info/grafts") else {
                return preserved(.unverified, "Histórico Git incompleto ou alterado. Worktree preservada.", state: .review)
            }
            let head = line(try checkedGit(record.path, ["rev-parse", "--verify", "HEAD"]))
            guard head == record.head else { return preserved(.unverified, "O registro da worktree mudou. Preservada; analise novamente.", state: .review) }
            let symbolic = git(record.path, ["symbolic-ref", "--quiet", "HEAD"])
            let branch = symbolic.status == 0 ? line(symbolic.output) : nil
            guard branch == record.branch else { return preserved(.unverified, "O registro da worktree mudou. Preservada; analise novamente.", state: .review) }
            item.details.append("Branch: \(branch.map { String($0.dropFirst("refs/heads/".count)) } ?? "HEAD destacado")")

            let status = try checkedGit(record.path, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"])
            item.worktree?.localChanges = fields(status).count
            item.details.append(status.isEmpty ? "Git sem alterações locais ou untracked." : "Há alterações locais ou arquivos untracked. Preservar.")
            let ignored = fields(try checkedGit(record.path, ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"]))
            item.worktree?.ignoredPaths = ignored.count
            item.details.append("\(ignored.count) caminhos ignorados pelo Git.")
            item.details += ignored.prefix(6).map { "Ignorado: " + $0 }
            let staged = fields(try checkedGit(record.path, ["ls-files", "--stage", "-z"]))
            let tracked = Set(staged.compactMap { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) })
            if staged.contains(where: { $0.hasPrefix("160000 ") }) {
                return preserved(.localData, "Worktree com submódulos. Conteúdo preservado para revisão.")
            }
            let flags = fields(try checkedGit(record.path, ["ls-files", "-v", "-z"]))
            if flags.contains(where: { !$0.hasPrefix("H ") }) {
                return preserved(.unverified, "O Git pode ocultar alterações nesta worktree. Preservada.", state: .review)
            }

            let references = try checkedGit(record.path, ["for-each-ref", "--format=%(refname) %(objectname)", "refs/remotes"])
                .split(separator: "\n").map(String.init).sorted()
            guard !references.isEmpty else {
                return preserved(.unverified, "Sem referências remotas locais para conferir os commits. Worktree preservada.", state: .review)
            }
            let unpublished = try count(record.path, [head, "--not", "--remotes"])
            item.worktree?.unpublishedCommits = unpublished
            item.details.append("Commits não publicados: \(unpublished).")
            let principal = principalReference(path: record.path, references: references)
            var unmerged: Int?
            var principalHead: String?
            if let principal {
                item.worktree?.comparisonReference = principal
                principalHead = line(try checkedGit(record.path, ["rev-parse", "--verify", principal]))
                unmerged = try count(record.path, ["\(principal)..\(head)"])
                item.worktree?.unmergedCommits = unmerged
                item.details.append("Principal registrada: \(principal). Referência local; nenhum fetch executado.")
                item.details.append("Commits exclusivos frente a essa referência: \(unmerged ?? 0).")
            }
            if let usage { return preserved(.inUse, usage, state: .inUse) }
            if !status.isEmpty { return preserved(.localChanges, "Há alterações locais ou arquivos novos. Worktree preservada.") }
            if unpublished > 0 || (unmerged ?? 0) > 0 {
                return preserved(.pendingCommits, "Há commits não publicados ou ainda não integrados à principal. Worktree preservada.")
            }
            if !extraMetadata.isEmpty {
                return preserved(.localData, "A worktree tem configurações ou metadados locais que precisam ser preservados.")
            }
            guard let principal, let principalHead, unmerged != nil else {
                return preserved(.unverified, "Branch principal real não registrada no Git local. Não presumida como main/master.", state: .review)
            }
            // Retain commits referenced only by the worktree's own reflog or ORIG_HEAD, too.
            let history = try historicalCommits(admin: admin)
            if !history.isEmpty, try count(record.path, history + ["--not", "--remotes"]) > 0 {
                return preserved(.pendingCommits, "O histórico local da worktree contém commits não publicados. Preservada.")
            }
            if FileManager.default.fileExists(atPath: admin + "/COMMIT_EDITMSG") {
                let savedMessage = try boundedText(admin + "/COMMIT_EDITMSG", limit: 1_000_000)
                let committedMessage = try checkedGit(record.path, ["log", "-1", "--no-show-signature", "--format=%B", "HEAD"])
                if savedMessage.trimmingCharacters(in: .newlines) != committedMessage.trimmingCharacters(in: .newlines) {
                    return preserved(.localData, "A worktree tem configurações ou metadados locais que precisam ser preservados.")
                }
            }
            for relative in ignored where !regenerable(relative, tracked: tracked) || sensitive(relative) {
                return preserved(.localData, "Há arquivos ignorados que podem conter configuração, dados ou estado local. Worktree preservada.")
            }
            guard authorized(repository: repository, worktree: record.path, preferences: preferences, catalog: catalog) else {
                return preserved(.unverified, "Adicione o repositório às pastas de projetos antes de limpar esta worktree.", state: .review)
            }
            let manifest = try FileTree.read(record.path, limit: manifestLimit)
            for entry in manifest {
                let relative = entry.relativePath
                if relative != ".git", (relative as NSString).lastPathComponent == ".git" {
                    return preserved(.localData, "Há outro repositório dentro da worktree. Conteúdo preservado para revisão.")
                }
                if !entry.stamp.isDirectory && !entry.stamp.isSymlink && entry.stamp.mode & 0o170000 != 0o100000 {
                    return preserved(.localData, "Há arquivos especiais ou serviços locais nesta worktree. Preservada.")
                }
                if ignored.contains(where: { $0.hasSuffix("/") && relative.hasPrefix($0) }), sensitive(relative) {
                    return preserved(.localData, "Há arquivos ignorados que podem conter configuração, dados ou estado local. Worktree preservada.")
                }
            }
            if let reason = processes.reason(path: record.path, manifest: manifest) { return preserved(.inUse, reason, state: .inUse) }
            let cutoff = Date().addingTimeInterval(-Double(max(preferences.retentionDays, 1)) * 86_400).timeIntervalSince1970
            if (manifest + adminManifest).contains(where: { Double($0.stamp.modifiedSeconds) > cutoff }) {
                return preserved(.recent, "O item teve alterações nos últimos \(preferences.retentionDays) dias e foi preservado.")
            }
            guard try FileTree.read(admin, limit: 200) == adminManifest else {
                return preserved(.unverified, "A worktree mudou durante a análise. Preservada; analise novamente.", state: .review)
            }
            let size = FileTree.sizes(manifest)
            item.logicalBytes = size.logical; item.allocatedBytes = size.allocated; item.sharedLinks = size.shared
            item.manifest = manifest; item.state = .ready; item.worktree?.status = .idle
            item.reason = "Sem uso visível, alterações locais ou commits pendentes. Worktree disponível para revisão manual."
            item.details.append("A comparação usa referências locais do Git; o servidor não foi consultado.")
            item.worktree?.removalContext = WorktreeRemovalContext(repository: repository, commonDirectory: commonDirectory,
                administrativeDirectory: admin, head: head, branch: branch, integrationReference: principal,
                integrationHead: principalHead, remoteReferences: references, administrativeManifest: adminManifest)
            return item
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let usage { return preserved(.inUse, usage, state: .inUse) }
            return preserved(.unverified, "Não foi possível verificar todas as condições desta worktree. Preservada.", state: .review)
        }
    }

    private static func authorized(repository: String, worktree: String, preferences: Preferences, catalog: RuleCatalog) -> Bool {
        preferences.projectRoots.contains { FileTree.contains(FileTree.canonical($0), repository) }
            || ["/.codex/worktrees", "/.claude/worktrees"].contains { FileTree.contains(catalog.home + $0, worktree) }
    }
    private static func administrativePaths(path: String, repository: String, commonDirectory: String) throws -> (admin: String, common: String) {
        guard path != repository, !FileTree.hasSymlinkAncestor(commonDirectory), !FileTree.hasSymlinkAncestor(repository + "/.git") else {
            throw SniffError.message("Worktree sem comprovação de segurança. Analise novamente.")
        }
        let marker = try boundedText(path + "/.git")
        guard marker.hasPrefix("gitdir: ") else { throw SniffError.message("Registro Git inválido.") }
        let markerPath = String(line(marker).dropFirst(8))
        let markerLocation = markerPath.hasPrefix("/") ? markerPath : path + "/" + markerPath
        guard !FileTree.hasSymlinkAncestor(markerLocation) else { throw SniffError.message("Registro Git inválido.") }
        let admin = FileTree.canonical(markerLocation)
        guard URL(fileURLWithPath: admin).deletingLastPathComponent().path == commonDirectory + "/worktrees",
              !FileTree.hasSymlinkAncestor(admin),
              FileTree.canonical(line(try checkedGit(path, ["rev-parse", "--path-format=absolute", "--git-dir"]))) == admin,
              FileTree.canonical(line(try checkedGit(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))) == commonDirectory,
              FileTree.canonical(line(try boundedText(admin + "/gitdir"))) == path + "/.git" else {
            throw SniffError.message("Registro Git inválido.")
        }
        return (admin, commonDirectory)
    }
    private static func principalReference(path: String, references: [String]) -> String? {
        let preferred = ["refs/remotes/upstream/HEAD", "refs/remotes/origin/HEAD"]
        let others = references.compactMap { $0.split(separator: " ").first.map(String.init) }.filter { $0.hasSuffix("/HEAD") && !preferred.contains($0) }
        for candidate in preferred + (others.count == 1 ? others : []) {
            let result = git(path, ["symbolic-ref", "--quiet", candidate])
            let value = line(result.output)
            if result.status == 0, !result.timedOut, value.hasPrefix("refs/remotes/"), value != candidate { return value }
        }
        return nil
    }
    private static func historicalCommits(admin: String) throws -> [String] {
        var commits = Set<String>()
        for name in ["ORIG_HEAD", "logs/HEAD"] where FileManager.default.fileExists(atPath: admin + "/" + name) {
            let text = try boundedText(admin + "/" + name, limit: 1_000_000)
            for row in text.split(separator: "\n") {
                for field in row.split(separator: " ").prefix(name == "ORIG_HEAD" ? 1 : 2) {
                    let value = String(field)
                    guard [40, 64].contains(value.count), value.allSatisfy({ $0.isHexDigit }) else { throw SniffError.message("Registro Git inválido.") }
                    if value.contains(where: { $0 != "0" }) { commits.insert(value) }
                }
            }
        }
        guard commits.count <= 1_000 else { throw SniffError.message("Histórico Git muito extenso para esta análise.") }
        return commits.sorted()
    }
    private static func regenerable(_ relative: String, tracked: Set<String>) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            let prefix = parts.prefix(index).joined(separator: "/")
            let base = prefix.isEmpty ? "" : prefix + "/"
            if ["node_modules", ".next", ".nuxt"].contains(part), tracked.contains(base + "package.json") { return true }
            if part == "target", tracked.contains(base + "Cargo.toml") { return true }
            if part == ".build", tracked.contains(base + "Package.swift") { return true }
            if ["bin", "obj"].contains(part), tracked.contains(where: { ($0 as NSString).deletingLastPathComponent == (prefix.isEmpty ? "" : prefix) && ["csproj", "fsproj", "vbproj"].contains(($0 as NSString).pathExtension) }) { return true }
        }
        return false
    }
    private static func sensitive(_ relative: String) -> Bool {
        let components = relative.split(separator: "/").map { $0.lowercased() }
        let protectedNames: Set<String> = [".git", ".claude", ".codex", ".wrangler", ".ssh", ".aws", ".config", ".proposta-web-local", ".npmrc", ".pypirc", ".netrc", "credentials"]
        if components.contains(where: { protectedNames.contains($0) || $0.hasPrefix(".env") }) { return true }
        let name = components.last ?? ""
        return ["db", "sqlite", "sqlite3", "mdb", "sql", "pfx", "p12", "key", "pem"].contains((name as NSString).pathExtension)
            || name.hasSuffix("-wal") || name.hasSuffix("-shm")
    }
    private static func boundedText(_ path: String, limit: Int64 = 8_192) throws -> String {
        let stamp = try FileTree.stamp(path)
        guard stamp.mode & 0o170000 == 0o100000, stamp.size <= limit, !FileTree.hasSymlinkAncestor(path) else { throw SniffError.message("Registro Git inválido.") }
        return try String(contentsOfFile: path, encoding: .utf8)
    }
    private static func count(_ path: String, _ revisions: [String]) throws -> Int {
        guard let value = Int(line(try checkedGit(path, ["rev-list", "--count"] + revisions + ["--"]))), value >= 0 else { throw SniffError.message("Registro Git inválido.") }
        return value
    }
    static func git(_ path: String, _ arguments: [String]) -> CommandResult {
        var options = ["--no-pager", "--no-optional-locks", "--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false", "-c", "core.trustctime=true", "-c", "core.checkStat=default", "-c", "core.ignoreStat=false", "-c", "core.fileMode=true", "-c", "color.ui=false", "-c", "status.submoduleSummary=false", "-C", path]
        if arguments.first == "status" {
            // A repository's clean/process filters are executable commands. Never run them
            // while inspecting somebody's project; raw-content differences stay protected.
            let filters = git(path, ["config", "--null", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|process|required)$"])
            let names = fields(filters.output)
            guard !filters.timedOut, [0, 1].contains(filters.status), names.count <= 100 else {
                return .init(status: -1, output: "Registro Git inválido.", timedOut: filters.timedOut)
            }
            for name in names { options += ["-c", name + (name.hasSuffix(".required") ? "=false" : "=")] }
        }
        return Command.run("/usr/bin/git", options + arguments, timeout: 12)
    }
    private static func checkedGit(_ path: String, _ arguments: [String]) throws -> String {
        try Task.checkCancellation()
        let result = git(path, arguments)
        guard result.status == 0, !result.timedOut else { throw SniffError.message("Registro Git inválido.") }
        return result.output
    }
    private static func line(_ output: String) -> String { output.hasSuffix("\n") ? String(output.dropLast()) : output }
    private static func fields(_ output: String) -> [String] { output.components(separatedBy: "\0").filter { !$0.isEmpty } }
    private static func identity(_ stamp: FileStamp) -> String { "\(stamp.device):\(stamp.inode)" }
}
