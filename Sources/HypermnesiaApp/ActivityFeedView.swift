import SwiftUI
import HypermnesiaKit

/// The greppable-truth counterpart of the MRI: a plain, newest-first list of exactly what
/// happened — what was injected into which session, what was captured, what got superseded.
struct ActivityFeedView: View {
    @Environment(AppModel.self) private var model
    @State private var events: [MemoryActivityEvent] = []

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView(
                    "No activity yet", systemImage: "clock.arrow.circlepath",
                    description: Text("Injections, captures, recalls, and audits will appear here as they happen.")
                )
            } else {
                List(events.reversed()) { event in
                    feedRow(event)
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }
        }
        .task(id: model.selectedProject) {
            // Live while visible: the log's decoded tail is cached by file signature, so an
            // unchanged file makes this poll effectively free.
            while !Task.isCancelled {
                events = MemoryActivityLog.recent(projectId: model.selectedProject, limit: 300)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func feedRow(_ event: MemoryActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(for: event.eventType))
                .foregroundStyle(event.eventType.tint)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(for: event)).font(.callout)
                if !titles(for: event).isEmpty {
                    Text(titles(for: event))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let latency = event.latencyMs {
                    Text("\(latency) ms").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if let first = event.memoryIds.first { model.selectedMemoryID = first }
        }
    }

    private func headline(for event: MemoryActivityEvent) -> String {
        let n = event.count ?? event.memoryIds.count
        let noun = n == 1 ? "memory" : "memories"
        switch event.eventType {
        case .hydrate: return "Injected \(n) \(noun) into a session"
        case .recall:
            if let query = event.metadata["query"], !query.isEmpty {
                return "Recall served \(n) \(noun) for “\(query)”"
            }
            return "Recall served \(n) \(noun)"
        case .capture:
            let source = event.metadata["source"].map { " (\($0))" } ?? ""
            return "Captured \(n) \(noun)\(source)"
        case .applySuccess: return "Audit corroborated \(n) \(noun)"
        case .applyOverride: return "Audit flagged drift on \(n) \(noun)"
        case .revalidate: return "Revalidated \(n) \(noun)"
        case .decayTransition:
            if let from = event.metadata["from"], let to = event.metadata["to"] {
                return "Decay transition: \(from) → \(to)"
            }
            return "Decay transition"
        case .supersede: return "A newer memory retired an older one"
        case .dream:
            let skills = event.metadata["skills"].flatMap(Int.init) ?? 0
            var line = "Dreamed: \(n) epiphan\(n == 1 ? "y" : "ies")"
            if skills > 0 { line += ", \(skills) skill proposal\(skills == 1 ? "" : "s")" }
            return line
        }
    }

    private func symbol(for type: MemoryActivityEvent.EventType) -> String {
        switch type {
        case .hydrate: "drop.fill"
        case .recall: "magnifyingglass"
        case .capture: "tray.and.arrow.down.fill"
        case .applySuccess: "checkmark.seal"
        case .applyOverride: "exclamationmark.triangle"
        case .revalidate: "arrow.clockwise"
        case .decayTransition: "hourglass"
        case .supersede: "arrow.triangle.2.circlepath"
        case .dream: "moon.zzz.fill"
        }
    }

    /// The affected memories by title (first few), resolved live so renames show current text.
    private func titles(for event: MemoryActivityEvent) -> String {
        let names = event.memoryIds.prefix(3).compactMap { model.memory(id: $0)?.title }
        guard !names.isEmpty else { return "" }
        let more = event.memoryIds.count - names.count
        return names.joined(separator: " · ") + (more > 0 ? " · +\(more) more" : "")
    }
}
