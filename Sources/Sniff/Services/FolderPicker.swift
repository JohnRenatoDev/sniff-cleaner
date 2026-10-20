import AppKit
import SniffCore

enum FolderPicker {
    static func choose(title: String, allowsFiles: Bool = false) -> [String] {
        let panel = NSOpenPanel()
        panel.title = title; panel.canChooseDirectories = true; panel.canChooseFiles = allowsFiles
        panel.allowsMultipleSelection = true; panel.prompt = L("Escolher")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map(\.path)
    }
    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}
