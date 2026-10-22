import Foundation
import Testing
@testable import SniffCore

@Test func allSupportedCatalogsHaveTheSameKeysAndPlaceholders() throws {
    let english = try #require(Localization.catalogs["en"])
    #expect(english.count >= 300)
    let expression = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
    func placeholders(_ text: String) -> [String] {
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }.sorted()
    }
    for code in ["pt", "es", "en"] {
        let catalog = try #require(Localization.catalogs[code])
        #expect(Set(catalog.keys) == Set(english.keys))
        for (key, value) in catalog {
            #expect(!value.isEmpty)
            #expect(placeholders(key) == placeholders(value))
        }
    }
}

@Test func languageMatchingHandlesRegionsAndUnsupportedLanguages() {
    #expect(AppLanguage.resolve(preferredLanguages: ["pt-BR"]) == .portuguese)
    #expect(AppLanguage.resolve(preferredLanguages: ["pt-PT"]) == .portuguese)
    #expect(AppLanguage.resolve(preferredLanguages: ["es-MX"]) == .spanish)
    #expect(AppLanguage.resolve(preferredLanguages: ["en-GB"]) == .english)
    #expect(AppLanguage.resolve(preferredLanguages: ["ja", "es_AR"]) == .spanish)
    #expect(AppLanguage.resolve(preferredLanguages: ["ja"]) == .english)
    #expect(AppLanguage.resolve(preferredLanguages: []) == .english)
}

@Test func languageChoicePersistsWithoutChangingScanPreferences() throws {
    let suite = "app.sniff.fixture.language.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(LanguagePreference.load(from: defaults) == .system)
    for language in AppLanguage.allCases {
        LanguagePreference.save(language, to: defaults)
        #expect(LanguagePreference.load(from: defaults) == language)
        #expect((defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String]) == (language == .system ? nil : [language.rawValue]))
    }
    defaults.set("invalid-language", forKey: "interfaceLanguage")
    #expect(LanguagePreference.load(from: defaults) == .system)
    let original = Preferences()
    let encoded = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(Preferences.self, from: encoded)
    #expect(!restored.scheduleEnabled && !restored.monitorEnabled)
    #expect(restored.retentionDays == original.retentionDays)
}

@Test func savedMessagesTranslateWithoutRescanningOrChangingPaths() {
    let path = "/Users/fixture/árbol/{0}/50%/foo · versão bar (1)"
    let source = "Preservado por uma exclusão sua: " + path
    #expect(Localization.text(source, language: .english) == "Preserved by your exclusion: " + path)
    #expect(Localization.text(source, language: .spanish) == "Conservado por una exclusión tuya: " + path)
    #expect(Localization.text(source, language: .portuguese) == source)
    #expect(Localization.text("Ignorado: " + path, language: .english) == "Ignored: " + path)
    #expect(Localization.text("{0} · {1} alocados estimados", arguments: [path, "2 GB"], language: .english).hasPrefix(path))
    #expect(Localization.text("Regra reconhecida; será verificada novamente antes de remover.", language: .english).hasPrefix("This path matches"))
    #expect(Localization.text("Dentro da retenção de 14 dias.", language: .spanish) == "El elemento cambió en los últimos 14 días y se ha conservado.")
    #expect(Localization.text("Principal registrada: refs/remotes/origin/trunk-real. Referência local; nenhum fetch executado.", language: .english).contains("refs/remotes/origin/trunk-real"))
    #expect(Localization.text(path, language: .spanish) == path)
    #expect(Localization.text("Commits não publicados: 2.", language: .english) == "Unpublished commits: 2.")
    #expect(Localization.text("3 caminhos ignorados pelo Git.", language: .spanish) == "3 rutas ignoradas por Git.")
}

@Test func singularPluralAndFormattersFollowTheChosenLanguage() {
    #expect(LocalizedFormat.items(0, language: .english) == "0 items")
    #expect(LocalizedFormat.items(1, language: .english) == "1 item")
    #expect(LocalizedFormat.items(2, language: .english) == "2 items")
    #expect(LocalizedFormat.items(1, language: .portuguese) == "1 item")
    #expect(LocalizedFormat.items(2, language: .portuguese) == "2 itens")
    #expect(LocalizedFormat.items(1, language: .spanish) == "1 elemento")
    #expect(LocalizedFormat.items(2, language: .spanish) == "2 elementos")
    #expect(LocalizedFormat.number(123456, language: .english) == "123,456")
    #expect(LocalizedFormat.number(123456, language: .portuguese) == "123.456")
    #expect(LocalizedFormat.number(123456, language: .spanish) == "123.456")
    #expect(LocalizedFormat.date(nil, language: .english) == "Not yet")
    #expect(LocalizedFormat.date(nil, language: .spanish) == "Todavía no")
    let date = Date(timeIntervalSince1970: 1_793_000_000)
    #expect(LocalizedFormat.date(date, language: .english) != LocalizedFormat.date(date, language: .portuguese))
    #expect(LocalizedFormat.bytes(1_180_549_120, language: .english).contains("1.1"))
    #expect(LocalizedFormat.bytes(1_180_549_120, language: .portuguese).contains("1,1"))
}
