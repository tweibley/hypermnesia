import Foundation
@preconcurrency import UserNotifications
import HypermnesiaKit

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

    /// The morning digest: ONE notification across all projects, only for nights that actually
    /// dreamed (quiet nights never notify). Clicking it opens the Dream Journal (see AppDelegate).
    static func notifyDreamDigest(_ entries: [DreamJournalEntry]) {
        guard !entries.isEmpty, Bundle.main.bundleIdentifier != nil else { return }
        let memories = entries.reduce(0) { $0 + $1.payload.proposedMemoryIds.count }
        let contradictions = entries.reduce(0) {
            $0 + $1.payload.epiphanies.filter { $0.kind == .contradiction }.count
        }
        let skillProposals = entries.flatMap(\.payload.skillProposals)
        let epiphanies = entries.reduce(0) { $0 + $1.payload.epiphanies.count }

        var parts: [String] = []
        if memories > 0 { parts.append("\(memories) memor\(memories == 1 ? "y" : "ies")") }
        if contradictions > 0 {
            parts.append("\(contradictions) contradiction\(contradictions == 1 ? "" : "s")")
        }
        if !skillProposals.isEmpty {
            parts.append(skillProposals.count == 1
                ? "1 new skill (\(skillProposals[0].slug))"
                : "\(skillProposals.count) new skills")
        }
        if parts.isEmpty { parts.append("\(epiphanies) epiphan\(epiphanies == 1 ? "y" : "ies")") }

        let projects = Set(entries.map(\.projectId))
        let scope = projects.count == 1
            ? projectDisplayName(projects.first ?? "")
            : "\(projects.count) projects"
        let body = "Hypermnesia dreamed — \(parts.joined(separator: ", ")) for \(scope). "
            + "Open the Dream Journal."

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Hypermnesia"
            content.body = body
            center.add(UNNotificationRequest(
                identifier: "dream-digest-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }
}
