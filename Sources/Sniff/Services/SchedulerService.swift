import Foundation
import ServiceManagement
import UserNotifications
import SniffCore

enum SchedulerService {
    static var agent: SMAppService { .agent(plistName: "app.sniff.scheduler.plist") }
    static func status() -> (title: String, approval: Bool) {
        switch agent.status {
        case .enabled: ("Registrado no macOS", false)
        case .requiresApproval: ("Aguardando permissão do macOS", true)
        case .notRegistered: ("Não registrado", false)
        case .notFound:
            (FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Contents/Library/LaunchAgents/app.sniff.scheduler.plist") ? "Não registrado" : "Helper não encontrado", false)
        @unknown default: ("Estado desconhecido", false)
        }
    }
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if agent.status != .enabled { try agent.register() }
        } else if agent.status != .notRegistered { try agent.unregister() }
    }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum NotificationService {
    static func requestPermission(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            Task { @MainActor in completion(allowed) }
        }
    }
    static func post(_ message: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent(); content.title = "Sniff"; content.body = L(message)
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
