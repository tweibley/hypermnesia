import Foundation
@preconcurrency import UserNotifications

/// Posts the opt-in "new drafts captured" notification. One notification per drain pass (never
/// per memory), and only from a real .app bundle — UNUserNotificationCenter requires a bundle
/// identity, which a bare SwiftPM dev run doesn't have.
enum Notifier {
    static func notifyNewDrafts(_ count: Int) {
        guard count > 0, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Hypermnesia"
            content.body = count == 1
                ? "Captured 1 new memory from your last session — review the draft."
                : "Captured \(count) new memories from your last session — review the drafts."
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
