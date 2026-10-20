import SwiftUI
import Observation
import Combine
import SniffCore
import SniffInstallation

@Observable @MainActor
final class InstallerStore: ObservableObject {
    var language = LanguagePreference.load()
    var applicationsDirectory: URL
    var installCLI = true
    var installing = false
    var phase: InstallationPhase = .checking
    var result: InstallationResult?
    var error: String?
    private(set) var fixture = false
    let binDirectory: URL
    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        applicationsDirectory = FileManager.default.isWritableFile(atPath: "/Applications") ? URL(fileURLWithPath: "/Applications") : home.appendingPathComponent("Applications")
        binDirectory = home.appendingPathComponent(".local/bin")
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--fixture-destination"), CommandLine.arguments.indices.contains(index + 1) {
            let path = URL(fileURLWithPath: FileTree.canonical(URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL.path))
            if path.deletingLastPathComponent().path == "/private/tmp", path.lastPathComponent.hasPrefix("sniff-installer-fixture-") {
                applicationsDirectory = path.appendingPathComponent("Applications"); fixture = true
            }
        }
        #endif
    }
    func text(_ key: String, _ arguments: String...) -> String { Localization.text(key, arguments: arguments, language: language) }
    var destination: URL { applicationsDirectory.appendingPathComponent("Sniff.app") }
    var commandDirectory: URL { fixture ? applicationsDirectory.deletingLastPathComponent().appendingPathComponent("bin") : binDirectory }
    var commandPath: String { commandDirectory.appendingPathComponent("sniff").path }
    func displayPath(_ value: String) -> String { value.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
    var preview: Bool { Bundle.main.object(forInfoDictionaryKey: "SniffPreviewBuild") as? Bool ?? true }
    var activity: String {
        let key = switch phase {
        case .checking: "Checking the installation…"
        case .copying: "Copying Sniff…"
        case .verifying: "Verifying the copied application…"
        case .installingCommand: "Installing the sniff command…"
        case .finishing: "Finishing the installation…"
        }
        return text(key)
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = text("Choose where to install Sniff."); panel.prompt = text("Choose")
        if panel.runModal() == .OK, let url = panel.url { applicationsDirectory = url.resolvingSymlinksInPath() }
    }
    func install() {
        guard !installing, result == nil else { return }
        guard let payload = Bundle.main.resourceURL?.appendingPathComponent("Payload/Sniff.app"), FileManager.default.fileExists(atPath: payload.path) else {
            error = text("The installer payload is missing. Download the complete installer again."); return
        }
        installing = true; error = nil
        let request = InstallationRequest(payload: payload, applicationsDirectory: applicationsDirectory, binDirectory: commandDirectory, installCLI: installCLI)
        let state = fixture ? StateStore(directory: applicationsDirectory.deletingLastPathComponent().appendingPathComponent("state")) : StateStore()
        Task { [self] in
            do {
                result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try InstallationService(stateStore: state).install(request) { phase in Task { @MainActor in self?.phase = phase } }
                }.value
                if !fixture { LanguagePreference.save(language) }
            } catch { self.error = text(error.localizedDescription) }
            installing = false
        }
    }
    func openApplication() { if let result { NSWorkspace.shared.open(result.application) } }
}
