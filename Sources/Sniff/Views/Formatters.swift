import Foundation
import SniffCore

enum Display {
    static func number(_ value: Int) -> String { LocalizedFormat.number(value) }
    static func items(_ count: Int) -> String { LocalizedFormat.items(count) }
    static func bytes(_ value: Int64) -> String { LocalizedFormat.bytes(value) }
    static func date(_ value: Date?) -> String { LocalizedFormat.date(value) }
    static func title(_ item: Finding) -> String {
        item.category == .docker || item.title == item.category.title ? L(item.title) : item.title
    }
    static func path(_ value: String) -> String {
        value.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
