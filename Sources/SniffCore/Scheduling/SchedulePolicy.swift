import Foundation

public enum SchedulePolicy {
    public static func isDue(_ preferences: Preferences, now: Date = .now) -> Bool {
        preferences.scheduleEnabled && (preferences.nextRun == nil || preferences.nextRun! <= now)
    }
    public static func nextDate(hours: Int, now: Date = .now) -> Date { now.addingTimeInterval(Double(max(1, min(hours, 168))) * 3_600) }
    public static func launchAgentPlist(label: String = "app.sniff.scheduler", bundleProgram: String = "Contents/MacOS/Sniff", interval: Int = 900) -> Data {
        let values: [String: Any] = ["Label": label, "BundleProgram": bundleProgram, "ProgramArguments": ["Sniff", "--scheduled"], "StartInterval": max(60, interval), "RunAtLoad": true, "ProcessType": "Background", "LowPriorityIO": true, "Nice": 10]
        return (try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)) ?? Data()
    }
    /// A metadata-only monitor; it never enumerates cache contents.
    public static func changedRoots(snapshot: ScanSnapshot?, catalog: RuleCatalog) -> [String] {
        guard let snapshot else { return [] }
        return catalog.rules.compactMap { rule in
            guard case .whole = rule.layout, let old = snapshot.findings.first(where: { $0.path == rule.base })?.manifest.first?.stamp,
                  let current = try? FileTree.stamp(rule.base), current != old else { return nil }
            return rule.base
        }
    }
}
