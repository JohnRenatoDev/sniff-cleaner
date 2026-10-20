import Foundation

/// Persisted findings retain their original Portuguese evidence. Translate at presentation time.
/// Paths, commands, Git/Docker output and the removal manifest are never rewritten.
public enum Localization {
    public static var language: AppLanguage { LanguagePreference.load().resolved }
    public static var locale: Locale { language.locale }
    private static let resourceBundle: Bundle = {
        let name = "Sniff_SniffCore.bundle"
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
            executable?.appendingPathComponent(name),
            executable?.appendingPathComponent("../Resources/" + name)
        ]
        for case let url? in candidates { if let bundle = Bundle(url: url) { return bundle } }
        return .module
    }()
    public static let catalogs: [String: [String: String]] = {
        var result: [String: [String: String]] = [:]
        for code in ["en", "pt", "es"] {
            guard let url = resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: code + ".lproj"),
                  let data = try? Data(contentsOf: url),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { continue }
            result[code] = values
        }
        return result
    }()
    private struct LegacyTemplate: Sendable {
        let key: String
        let expression: NSRegularExpression
    }
    private static let legacyTemplates: [LegacyTemplate] = {
        guard let url = resourceBundle.url(forResource: "LegacyTemplates", withExtension: "json"),
              let data = try? Data(contentsOf: url), let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        // Match an explicit message prefix before generic metadata such as "{0} · versão {1}".
        // A path may itself contain words or punctuation that resemble such metadata.
        return keys.sorted {
            let left = $0.prefix(while: { $0 != "{" }).count
            let right = $1.prefix(while: { $0 != "{" }).count
            return left == right ? $0.count > $1.count : left > right
        }.compactMap { key in
            let components = key.components(separatedBy: CharacterSet(charactersIn: "{}"))
            var pattern = "^"
            for (index, component) in components.enumerated() {
                pattern += index.isMultiple(of: 2) ? NSRegularExpression.escapedPattern(for: component) : "(.*?)"
            }
            pattern += "$"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            return LegacyTemplate(key: key, expression: expression)
        }
    }()
    private static let placeholder = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    public static func text(_ key: String, arguments: [String] = [], language: AppLanguage? = nil) -> String {
        let language = (language ?? self.language).resolved
        if !arguments.isEmpty { return format(catalogs[language.rawValue]?[key] ?? key, arguments: arguments) }
        return render(key, language: language, depth: 0)
    }
    private static func render(_ value: String, language: AppLanguage, depth: Int) -> String {
        if value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("docker://") { return value }
        if let exact = catalogs[language.rawValue]?[value] { return exact }
        guard depth < 4 else { return value }
        let source = value as NSString
        for template in legacyTemplates {
            guard let match = template.expression.firstMatch(in: value, range: NSRange(location: 0, length: source.length)) else { continue }
            var arguments = (1..<match.numberOfRanges).map { source.substring(with: match.range(at: $0)) }
            // Only these fields contain another app-owned message. Other captures are opaque
            // paths, command output, identifiers or numbers, even when they resemble UI text.
            if template.key == "Farejando {0}…" || template.key == "Branch: {0}" {
                arguments[0] = catalogs[language.rawValue]?[arguments[0]] ?? arguments[0]
            } else if template.key == "Tamanho não concluído: {0}" || template.key == "O macOS não registrou o agendador: {0}" || template.key == "Limpeza parcial. Alguns arquivos foram removidos; analise novamente. {0}" {
                arguments[0] = render(arguments[0], language: language, depth: depth + 1)
            }
            return format(catalogs[language.rawValue]?[template.key] ?? template.key, arguments: arguments)
        }
        return value
    }
    private static func format(_ template: String, arguments: [String]) -> String {
        let source = template as NSString
        var result = ""; var position = 0
        for match in placeholder.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let index = Int(source.substring(with: match.range(at: 1))) ?? -1
            result += arguments.indices.contains(index) ? arguments[index] : source.substring(with: match.range)
            position = NSMaxRange(match.range)
        }
        return result + source.substring(from: position)
    }
}

public func L(_ key: String, _ arguments: any CustomStringConvertible...) -> String {
    Localization.text(key, arguments: arguments.map(\.description))
}
