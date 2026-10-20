import Foundation

public enum LocalizedFormat {
    public static func number(_ value: Int, language: AppLanguage? = nil) -> String {
        value.formatted(.number.locale((language ?? Localization.language).locale))
    }
    public static func items(_ count: Int, language: AppLanguage? = nil) -> String {
        Localization.text(count == 1 ? "{0} item" : "{0} itens", arguments: [number(count, language: language)], language: language)
    }
    public static func bytes(_ value: Int64, language: AppLanguage? = nil) -> String {
        value.formatted(.byteCount(style: .binary).locale((language ?? Localization.language).locale))
    }
    public static func date(_ value: Date?, language: AppLanguage? = nil) -> String {
        value?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale((language ?? Localization.language).locale))
            ?? Localization.text("Ainda não aconteceu", language: language)
    }
}
