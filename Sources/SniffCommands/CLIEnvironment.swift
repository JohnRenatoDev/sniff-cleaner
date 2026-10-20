import Foundation
import SniffCore

public struct CLIEnvironment: Sendable {
    public var catalog: RuleCatalog
    public var store: StateStore
    public var interactive: Bool
    public var captureProcesses: @Sendable () -> ProcessInventory
    public init(catalog: RuleCatalog = .init(), store: StateStore = .init(), interactive: Bool = false,
                captureProcesses: @escaping @Sendable () -> ProcessInventory = ProcessInventory.capture) {
        self.catalog = catalog; self.store = store; self.interactive = interactive; self.captureProcesses = captureProcesses
    }
}
