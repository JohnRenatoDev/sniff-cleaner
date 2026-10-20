import Foundation
import SniffCore

/// Local UI hints only. Receiving these notifications cannot authorize a cleanup.
enum ScheduledActivity {
    static let notification = Notification.Name("app.sniff.scheduledActivity")
    static func post(active: Bool, cleaning: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: nil,
            userInfo: ["pid": Int(ProcessInfo.processInfo.processIdentifier), "active": active, "cleaning": cleaning],
            deliverImmediately: true
        )
    }
}
