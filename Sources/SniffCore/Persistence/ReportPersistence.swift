import Foundation

public extension PersistedState {
    mutating func apply(_ report: CleaningReport) {
        history.insert(report, at: 0); history = Array(history.prefix(30))
        let removed = Set(report.outcomes.filter(\.removed).map(\.path))
        lastScan?.findings.removeAll { removed.contains($0.path) }
        for outcome in report.outcomes where outcome.partiallyRemoved == true {
            guard let index = lastScan?.findings.firstIndex(where: { $0.path == outcome.path }) else { continue }
            lastScan?.findings[index].state = .protected
            lastScan?.findings[index].reason = outcome.message
            lastScan?.findings[index].manifest = []
            lastScan?.findings[index].partialMeasurement = true
            if let old = lastScan?.findings[index].allocatedBytes { lastScan?.findings[index].allocatedBytes = max(0, old - outcome.allocatedBytes) }
        }
    }
}
