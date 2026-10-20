import Foundation

public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case system, english = "en", portuguese = "pt", spanish = "es"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: L("Usar idioma do macOS")
        case .english: "English"
        case .portuguese: "Português"
        case .spanish: "Español"
        }
    }
    public static func resolve(preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            switch identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
            case "pt": return .portuguese
            case "es": return .spanish
            case "en": return .english
            default: continue
            }
        }
        return .english
    }
    public var resolved: AppLanguage {
        guard self == .system else { return self }
        let systemLanguages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return Self.resolve(preferredLanguages: systemLanguages ?? Locale.preferredLanguages)
    }
    public var locale: Locale {
        switch resolved {
        case .portuguese: Locale(identifier: "pt_BR")
        case .spanish: Locale(identifier: "es_ES")
        default: Locale(identifier: "en_US")
        }
    }
}

public enum LanguagePreference {
    // A separate preference keeps existing scan/history JSON compatible and is shared with the helper.
    private static let domain = "app.sniff.mac"
    public static func load(from defaults: UserDefaults? = nil) -> AppLanguage {
        let defaults = defaults ?? UserDefaults(suiteName: domain) ?? .standard
        return defaults.string(forKey: "interfaceLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
    }
    public static func save(_ language: AppLanguage, to defaults: UserDefaults? = nil) {
        let defaults = defaults ?? UserDefaults(suiteName: domain) ?? .standard
        defaults.set(language.rawValue, forKey: "interfaceLanguage")
        // AppKit reads this per-app preference when the process starts. System dialogs and
        // framework-supplied menu actions can require reopening the app to change language.
        if language == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([language.rawValue], forKey: "AppleLanguages") }
    }
}
