import Foundation

public enum Category: String, Codable, CaseIterable, Sendable, Identifiable {
    case npm, npx, uv, bun, pnpm, pip, nodeGyp, go, typescript, swiftPM, homebrew, nuget, cargo, gradle
    case runtimeInstall, installer, logs, build, worktree, docker, claudeVM, signingClone
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .npm: "npm"; case .npx: "Ambientes npx"; case .uv: "uv"; case .bun: "Bun"
        case .pnpm: "pnpm"; case .pip: "pip"; case .nodeGyp: "node-gyp"; case .go: "Go"
        case .typescript: "TypeScript"; case .swiftPM: "SwiftPM"; case .homebrew: "Homebrew"
        case .nuget: "NuGet"; case .cargo: "Cargo"; case .gradle: "Gradle"
        case .runtimeInstall: "Instalações temporárias do Codex"; case .installer: "Instaladores antigos"
        case .logs: "Logs antigos"; case .build: "Compilações"; case .worktree: "Worktrees"
        case .docker: "Docker / OrbStack"; case .claudeVM: "Imagem da VM do Claude"; case .signingClone: "Clones de assinatura"
        }
    }
    public var symbol: String {
        switch self {
        case .worktree: "arrow.triangle.branch"; case .docker: "shippingbox"; case .claudeVM: "desktopcomputer"
        case .signingClone: "signature"; case .logs: "doc.text"; case .build: "hammer"
        case .installer, .runtimeInstall: "shippingbox.and.arrow.backward"; default: "archivebox"
        }
    }
    public var regeneration: String {
        switch self {
        case .worktree: "Pode conter código, commits exclusivos, configurações e bancos ignorados pelo Git. Esta versão só inspeciona worktrees."
        case .docker: "O Sniff inspeciona imagens e caches e preserva containers e volumes. Para remover algo pelo Docker, você precisa revisar os itens separadamente."
        case .claudeVM: "Você precisa selecionar a imagem manualmente. O Claude terá que reconstruir a VM no próximo uso. Sessiondata, a base comprimida e os metadados são preservados."
        case .signingClone: "Mantêm a assinatura durante atualizações e podem compartilhar blocos APFS. Esta versão só inspeciona esses clones, mesmo quando são antigos e não há uso visível."
        case .build: "Você precisa selecionar as pastas manualmente. O Sniff remove apenas arquivos de compilação reconhecidos e preserva o código-fonte. A próxima compilação será mais lenta."
        case .logs: "Você precisa selecionar os logs manualmente. O Sniff remove apenas arquivos .log fora do prazo de retenção. Depois de removido, esse histórico não pode ser reconstruído."
        case .npx: "Você precisa selecionar os ambientes manualmente. Os pacotes serão baixados de novo. Ambientes com MCPs ou citados por processos são preservados."
        case .runtimeInstall: "O Sniff remove apenas pastas codex-runtime-install-* antigas e preserva o runtime principal."
        case .installer: "O Sniff remove apenas caches de atualização reconhecidos e antigos. Você pode precisar baixar o instalador de novo."
        default: "A ferramenta consegue recriar este cache. A próxima instalação ou compilação pode precisar baixar dependências e levar mais tempo."
        }
    }
    public var allowsAutomatic: Bool {
        ![.worktree, .docker, .claudeVM, .signingClone, .build, .logs, .npx].contains(self)
    }
}

public enum FindingState: String, Codable, Sendable {
    case ready, inUse, protected, review, inaccessible
    public var title: String {
        switch self { case .ready: "Pode limpar"; case .inUse: "Em uso"; case .protected: "Preservado"; case .review: "Só inspeção"; case .inaccessible: "Sem acesso" }
    }
}

public struct FileStamp: Codable, Equatable, Sendable {
    public var device: Int32
    public var inode: UInt64
    public var mode: UInt16
    public var size: Int64
    public var blocks: Int64
    public var links: UInt16
    public var modifiedSeconds: Int64
    public var modifiedNanos: Int64
    public var changedSeconds: Int64
    public var changedNanos: Int64
    public var isDirectory: Bool { mode & 0o170000 == 0o040000 }
    public var isSymlink: Bool { mode & 0o170000 == 0o120000 }
}

public struct TreeEntry: Codable, Equatable, Sendable {
    public var relativePath: String
    public var stamp: FileStamp
    public init(relativePath: String, stamp: FileStamp) { self.relativePath = relativePath; self.stamp = stamp }
}

public struct Finding: Codable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var title: String
    public var category: Category
    public var ruleID: String
    public var state: FindingState
    public var reason: String
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var sharedLinks: Bool
    public var manifest: [TreeEntry]
    public var details: [String]
    public var partialMeasurement = false
    public init(path: String, title: String, category: Category, ruleID: String, state: FindingState, reason: String, logicalBytes: Int64 = 0, allocatedBytes: Int64 = 0, sharedLinks: Bool = false, manifest: [TreeEntry] = [], details: [String] = []) {
        self.path = path; self.title = title; self.category = category; self.ruleID = ruleID; self.state = state; self.reason = reason
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes; self.sharedLinks = sharedLinks; self.manifest = manifest; self.details = details
    }
}

public struct ScanSnapshot: Codable, Sendable {
    public var date: Date = .now
    public var findings: [Finding] = []
    public var notices: [String] = []
    public var completed: Bool = true
    public init() {}
}

public struct RemovalOutcome: Codable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var removed: Bool
    public var message: String
    public var allocatedBytes: Int64
}

public struct CleaningReport: Codable, Sendable {
    public var date: Date = .now
    public var outcomes: [RemovalOutcome] = []
    public var availableBefore: Int64?
    public var availableAfter: Int64?
    public var netChange: Int64? {
        guard let availableBefore, let availableAfter else { return nil }
        return availableAfter - availableBefore
    }
    public var removedAllocated: Int64 { outcomes.filter(\.removed).reduce(0) { $0 + $1.allocatedBytes } }
    public init() {}
}
