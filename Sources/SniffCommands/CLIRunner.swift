import Foundation
import SniffCore

public struct CLIRunner: Sendable {
    public let environment: CLIEnvironment
    public init(environment: CLIEnvironment = .init()) { self.environment = environment }
    public func run(_ request: CLIRequest, diagnostics: @Sendable (String) -> Void = { _ in },
                    confirm: (String) -> Bool = { _ in false }) throws -> CLIResult {
        let language = request.language.resolved
        func text(_ key: String, _ args: String...) -> String { Localization.text(key, arguments: args, language: language) }
        let store = request.stateDirectory.map { StateStore(directory: Self.url($0)) } ?? environment.store
        switch request.action {
        case .help: return .init(output: CLIOutput.help(language: language))
        case .version: return .init(output: ProductInfo.version)
        case .categories:
            struct Row: Encodable { let id: String; let title: String; let automatic: Bool; let inspectionOnly: Bool }
            let rows = SniffCore.Category.allCases.map { Row(id: $0.cliName, title: text($0.title), automatic: $0.allowsAutomatic, inspectionOnly: [.docker, .signingClone].contains($0)) }
            return .init(output: request.json ? try CLIOutput.json(rows) : rows.map { "\($0.id)  \($0.title)\($0.inspectionOnly ? " [inspection-only]" : "")" }.joined(separator: "\n"))
        case .status:
            let state = try store.loadValidated()
            struct Status: Encodable {
                let version: String; let language: String; let scanDate: Date?; let findings: Int; let readyItems: Int
                let estimatedAllocatedBytes: Int64; let cleanupReports: Int; let scheduleConfigured: Bool
                let monitorConfigured: Bool; let registrationNote: String
            }
            let ready = state.lastScan?.findings.filter { $0.state == .ready } ?? []
            let value = Status(version: ProductInfo.version, language: language.rawValue, scanDate: state.lastScan?.date,
                               findings: state.lastScan?.findings.count ?? 0, readyItems: ready.count,
                               estimatedAllocatedBytes: ready.reduce(0) { $0 + $1.allocatedBytes }, cleanupReports: state.history.count,
                               scheduleConfigured: state.preferences.scheduleEnabled, monitorConfigured: state.preferences.monitorEnabled,
                               registrationNote: text("Check macOS registration in the app's Schedule screen."))
            return .init(output: request.json ? try CLIOutput.json(value) : "Sniff \(ProductInfo.version)\n" + text("Last scan: {0}", LocalizedFormat.date(value.scanDate, language: language)) + "\n" + text("{0} items ready for review; {1} estimated.", "\(ready.count)", LocalizedFormat.bytes(value.estimatedAllocatedBytes, language: language)) + "\n" + value.registrationNote)
        case .scan:
            let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
            var state = try store.loadValidated()
            if state.preferences.projectRoots.isEmpty && state.lastScan == nil {
                let code = environment.catalog.home + "/Code"
                if FileManager.default.fileExists(atPath: code) { state.preferences.projectRoots = [code] }
            }
            let snapshot = try Scanner(catalog: environment.catalog, captureProcesses: environment.captureProcesses).scan(preferences: state.preferences, deep: !request.quick, worktreesOnly: request.worktreesOnly) { message in
                diagnostics(Localization.text(message, language: language))
            }
            state.lastScan = snapshot; try store.save(state)
            return try scanOutput(snapshot, items: snapshot.findings, json: request.json, language: language)
        case .list, .plan:
            let state = try store.loadValidated()
            guard let snapshot = state.lastScan else { throw CLIFailure.usage("No saved scan. Run sniff scan first.") }
            var items = snapshot.findings
            if !request.categories.isEmpty { items = items.filter { request.categories.contains($0.category) } }
            if !request.paths.isEmpty {
                let paths = Set(request.paths.map { FileTree.canonical(Self.url($0).path) })
                for path in paths where !items.contains(where: { $0.path == path }) { throw CLIFailure.usage("Path not found in the saved scan: {0}.", path) }
                items = items.filter { paths.contains($0.path) }
            }
            if request.readyOnly { items = items.filter { $0.state == .ready } }
            if request.action == .list { return try scanOutput(snapshot, items: items, json: request.json, language: language) }
            items = items.filter { $0.state == .ready && state.preferences.enabledCategories.contains($0.category) }
            if request.categories.isEmpty && request.paths.isEmpty { items = items.filter { $0.category.allowsAutomatic } }
            guard !items.isEmpty else { throw CLIFailure.usage("No eligible items selected. Check the scan and enabled categories.") }
            let age = Date().timeIntervalSince(snapshot.date)
            guard age >= -30 && age < 900 else { throw CLIFailure.usage("The plan has expired. Scan again and create a new plan.") }
            if let output = request.output {
                let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
                try PlanDocument(home: environment.catalog.home, scannedAt: snapshot.date, findings: items).write(to: Self.url(output))
            }
            struct Preview: Encodable { let schemaVersion: Int; let language: String; let scannedAt: Date; let planFile: String?; let items: [FindingSummary] }
            if request.json { return .init(output: try CLIOutput.json(Preview(schemaVersion: 1, language: language.rawValue, scannedAt: snapshot.date, planFile: request.output, items: items.map { FindingSummary($0, language: language) }))) }
            return .init(output: CLIOutput.findings(items, language: language) + "\n\n" + (request.output.map { text("Plan saved to {0}. No files were removed.", Self.url($0).path) } ?? text("Preview only. Use --output to save a cleanup plan.")))
        case .clean:
            guard let file = request.planFile else { throw CLIFailure.usage("clean requires --plan. Create a reviewed plan with sniff plan --output first.") }
            let plan = try PlanDocument.read(from: Self.url(file), expectedHome: environment.catalog.home)
            diagnostics(CLIOutput.findings(plan.findings, language: language))
            if !request.yes {
                guard environment.interactive else { throw CLIFailure(status: 3, key: "Non-interactive cleanup requires --yes and an explicit plan file.", arguments: []) }
                guard confirm(text("Type CLEAN to permanently delete these files and folders:")) else { return .init(status: 3, output: text("Cancelled. No files were removed.")) }
            }
            let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
            var state = try store.loadValidated()
            let capture = environment.captureProcesses; let catalog = environment.catalog
            let executor = CleaningExecutor(catalog: catalog, useCheck: { finding in
                CleaningExecutor.usageReason(finding, inventory: capture(), catalog: catalog)
            })
            let report = executor.execute(plan: plan.findings, scannedAt: plan.scannedAt, preferences: state.preferences) { message in diagnostics(Localization.text(message, language: language)) }
            state.apply(report); try store.save(state)
            let status: Int32 = report.outcomes.allSatisfy(\.removed) ? 0 : 4
            if request.json { return .init(status: status, output: try CLIOutput.json(localized(report, language: language))) }
            let rows = report.outcomes.map { outcome in
                "[\(outcome.removed ? "removed" : outcome.partiallyRemoved == true ? "partial" : "preserved")] \(outcome.path)\n  \(text(outcome.message))"
            }.joined(separator: "\n")
            let change = report.netChange.map { ($0 >= 0 ? "+" : "−") + LocalizedFormat.bytes(abs($0), language: language) } ?? text("Medida de espaço livre indisponível.")
            return .init(status: status, output: rows + "\n\n" + text("Free space change: {0}", change))
        case .history:
            let reports = try store.loadValidated().history.map { localized($0, language: language) }
            if request.json { return .init(output: try CLIOutput.json(reports)) }
            return .init(output: reports.isEmpty ? text("Nenhuma limpeza ainda") : reports.map { report in
                LocalizedFormat.date(report.date, language: language) + "\n" + report.outcomes.map { "  \($0.path): \($0.message)" }.joined(separator: "\n")
            }.joined(separator: "\n\n"))
        case .config:
            let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
            var state = try store.loadValidated()
            for category in request.enable {
                guard ![.docker, .signingClone].contains(category) else { throw CLIFailure.usage("This category is inspection-only: {0}.", category.cliName) }
                state.preferences.enabledCategories.insert(category)
            }
            for category in request.disable { state.preferences.enabledCategories.remove(category) }
            for root in request.projects {
                let path = FileTree.canonical(Self.url(root).path)
                guard path != "/", (try? FileTree.stamp(path).isDirectory) == true else { throw CLIFailure.usage("Choose an existing project folder: {0}.", path) }
                if !state.preferences.projectRoots.contains(path) { state.preferences.projectRoots.append(path) }
            }
            for excluded in request.exclusions {
                let path = FileTree.canonical(Self.url(excluded).path)
                if !state.preferences.exclusions.contains(path) { state.preferences.exclusions.append(path) }
            }
            if !request.enable.isEmpty || !request.disable.isEmpty || !request.projects.isEmpty || !request.exclusions.isEmpty { try store.save(state) }
            return .init(output: try CLIOutput.json(state.preferences))
        }
    }
    private func scanOutput(_ scan: ScanSnapshot, items: [Finding], json: Bool, language: AppLanguage) throws -> CLIResult {
        struct Result: Encodable { let schemaVersion: Int; let language: String; let scannedAt: Date; let items: [FindingSummary]; let notices: [String] }
        if json { return .init(output: try CLIOutput.json(Result(schemaVersion: 1, language: language.rawValue, scannedAt: scan.date, items: items.map { FindingSummary($0, language: language) }, notices: scan.notices.map { Localization.text($0, language: language) }))) }
        return .init(output: CLIOutput.findings(items, language: language) + "\n\n" + scan.notices.map { Localization.text($0, language: language) }.joined(separator: "\n"))
    }
    private func localized(_ report: CleaningReport, language: AppLanguage) -> CleaningReport {
        var result = report
        for index in result.outcomes.indices { result.outcomes[index].message = Localization.text(result.outcomes[index].message, language: language) }
        return result
    }
    private static func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }
}
