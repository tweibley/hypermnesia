import Foundation

/// Representative sample memories spanning every type and decay band. Used by `hypermnesia seed`
/// and SwiftUI previews so the app can be exercised before live capture exists.
public enum SampleMemories {
    public static func make(projectId: String = "github.com/acme/widgets", now: Date = Date()) -> [MemoryNode] {
        func daysAgo(_ d: Int) -> Date { now.addingTimeInterval(-Double(d) * 86_400) }

        func node(
            _ type: MemoryType, _ title: String, _ summary: String, _ data: MemoryData,
            confidence: Double, ageDays: Int, status: MemoryStatus = .confirmed,
            applied: Int = 0, overridden: Int = 0, supersededBy: String? = nil,
            files: [String] = []
        ) -> MemoryNode {
            MemoryNode(
                projectId: projectId, type: type, status: status,
                title: title, summary: summary, data: data, confidence: confidence,
                createdAt: daysAgo(ageDays), updatedAt: daysAgo(ageDays),
                lastValidatedAt: daysAgo(ageDays),
                supersededById: supersededBy, conversationId: "sample-session",
                commitSha: "a1b2c3d", branch: "main",
                timesApplied: applied, timesOverridden: overridden,
                // Mirror the v5 backfill (sightings from the legacy counter) so samples exercise
                // the split evidence counters the way real migrated corpora do.
                timesSighted: applied, timesAppliedSuccess: applied
            )
        }

        let oldDecision = node(
            .decision, "Use REST over GraphQL",
            "Chose REST for the public API to keep the surface small.",
            .decision(.init(problem: "API style", chosen: "REST", alternatives: ["GraphQL"],
                            rationale: "Smaller surface, easier caching")),
            confidence: 0.0, ageDays: 240, supersededBy: "superseder"
        )

        return [
            node(.decision, "Adopt Swift 6 strict concurrency",
                 "All new modules build under the Swift 6 language mode.",
                 .decision(.init(problem: "Concurrency safety", chosen: "Swift 6 mode",
                                 alternatives: ["stay on Swift 5"], rationale: "Catch data races at compile time")),
                 confidence: 1.0, ageDays: 5, applied: 3, files: ["Package.swift"]),

            node(.convention, "Engine stays UI-free",
                 "HypermnesiaKit never imports SwiftUI; colors/icons are exposed as data.",
                 .convention(.init(rule: "No SwiftUI in the engine",
                                   examples: [.init(bad: "import SwiftUI", good: "expose colorHex")])),
                 confidence: 0.74, ageDays: 60, applied: 6, overridden: 1),

            node(.intent, "Backfill must reproduce decay",
                 "Replaying old sessions must backdate timestamps so decay is correct.",
                 .intent(.init(goal: "Correct historical decay",
                               behaviors: [.init(given: "an old session", when: "replayed", then: "lands aged")])),
                 confidence: 0.49, ageDays: 120),

            node(.fact, "Primary store",
                 "Local SQLite via GRDB at ~/Library/Application Support/Hypermnesia.",
                 .fact(.init(category: "stack", key: "store", value: "SQLite (GRDB) + FTS5")),
                 confidence: 1.0, ageDays: 3),

            node(.concern, "claude -p on subscription",
                 "Headless classification may draw on subscription rate limits.",
                 .concern(.init(issue: "Subscription rate limits", severity: "medium",
                                affectedArea: "classifier")),
                 confidence: 1.0, ageDays: 10),

            node(.backlog, "iOS companion app",
                 "Browse/review memories on iPhone once sync exists.",
                 .backlog(.init(idea: "iOS companion", priority: "low", trigger: "after sync lands")),
                 confidence: 1.0, ageDays: 200),

            node(.codeRef, "MemoryStore.search",
                 "FTS5-backed search entry point.",
                 .codeRef(.init(filePath: "Sources/HypermnesiaKit/Storage/MemoryStore.swift",
                                symbolName: "search(projectId:query:limit:)", range: "L150-L175")),
                 confidence: 1.0, ageDays: 4),

            node(.decision, "Pluggable classifier adapter", // draft awaiting confirmation
                 "Default claude -p; API key optional in settings.",
                 .decision(.init(chosen: "Pluggable adapter", alternatives: ["hard-wire claude -p"],
                                 rationale: "Reversible; defuses subscription concern")),
                 confidence: 0.8, ageDays: 1, status: .draft),

            oldDecision,
        ]
    }
}
