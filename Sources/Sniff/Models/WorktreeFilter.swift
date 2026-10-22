import SniffCore

enum WorktreeFilter: String, CaseIterable, Identifiable {
    case all, candidates, pending, inUse
    var id: Self { self }
    var title: String {
        switch self {
        case .all: L("Todas")
        case .candidates: L("Pode limpar")
        case .pending: L("Com pendências")
        case .inUse: L("Em uso")
        }
    }
    func matches(_ item: Finding) -> Bool {
        switch self {
        case .all: true
        case .candidates: item.category == .worktree && item.state == .ready
        case .pending: item.category == .worktree && item.worktree?.hasPendingChanges == true
        case .inUse: item.category == .worktree && item.state == .inUse
        }
    }
}
