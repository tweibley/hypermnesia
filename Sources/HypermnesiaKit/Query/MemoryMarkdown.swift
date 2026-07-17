import Foundation

/// Renders one memory as portable Markdown — for pasting into a PR description, an issue, or a
/// CLAUDE.md. Deliberately plain: no app-specific ids or metadata a reader outside the app can't use.
public enum MemoryMarkdown {

    public static func render(_ node: MemoryNode) -> String {
        var lines: [String] = []
        lines.append("**[\(node.type.displayName)] \(node.title)**")
        if !node.summary.isEmpty && node.summary != node.title {
            lines.append("")
            lines.append(node.summary)
        }
        let details = detailBullets(node.data)
        if !details.isEmpty {
            lines.append("")
            lines += details
        }
        let files = node.data.relatedFiles
        if !files.isEmpty {
            lines.append("")
            lines.append("Files: " + files.map { "`\($0)`" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// A whole project's confirmed memory as one committable document — the README of what the
    /// team has decided and learned. Only live memories (confirmed, not superseded/deleted); no
    /// internal ids, per the portability convention, and the human display name in place of the
    /// raw project id so path-based ids never leak a machine's directory layout.
    public static func projectDigest(projectId: String, nodes: [MemoryNode], generatedAt: Date = Date()) -> String {
        let live = nodes.filter { $0.status == .confirmed && !$0.isSuperseded && !$0.isDeleted }
        let name = ProjectIdentity.displayName(for: projectId)
        var out: [String] = ["# \(name) — project memory", ""]

        guard !live.isEmpty else {
            out.append("_No confirmed memories yet · exported from Hypermnesia on \(dayString(generatedAt))_")
            return out.joined(separator: "\n") + "\n"
        }

        let sections: [(type: MemoryType, members: [MemoryNode])] = MemoryType.allCases.compactMap { type in
            let members = ordered(live.filter { $0.type == type }, for: type)
            return members.isEmpty ? nil : (type, members)
        }

        out.append(statsLine(live, generatedAt: generatedAt))
        out.append("")
        out.append(
            "This is the project's durable memory — decisions, conventions, and gotchas captured "
            + "from real coding sessions. Committed to the repo, it gives both people and coding "
            + "agents the \"why\" behind the code.")

        if sections.count >= 2 {
            out.append("")
            out.append("## Contents")
            out.append("")
            for section in sections {
                let title = sectionTitle(section.type)
                out.append("- [\(title)](#\(anchor(title))) — \(section.members.count)")
            }
        }

        for section in sections {
            out.append("")
            out.append("## \(sectionTitle(section.type))")
            out.append("")
            out.append("_\(sectionDescription(section.type))_")
            for memory in section.members {
                out.append("")
                out.append("### \(memory.title)")
                if let meta = metaLine(memory, asOf: generatedAt) {
                    out.append("")
                    out.append(meta)
                }
                if !memory.summary.isEmpty && memory.summary != memory.title {
                    out.append("")
                    out.append(memory.summary)
                }
                let bullets = detailBullets(memory.data)
                if !bullets.isEmpty {
                    out.append("")
                    out.append(contentsOf: bullets)
                }
                let files = memory.data.relatedFiles
                if !files.isEmpty {
                    out.append("")
                    out.append("Files: " + files.map { "`\($0)`" }.joined(separator: ", "))
                }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Digest pieces

    /// One italic line of corpus stats: count by type, evidence, time span, export date.
    private static func statsLine(_ live: [MemoryNode], generatedAt: Date) -> String {
        var parts: [String] = ["\(live.count) confirmed \(live.count == 1 ? "memory" : "memories")"]
        let byType = MemoryType.allCases.compactMap { type -> String? in
            let count = live.filter { $0.type == type }.count
            return count > 0 ? type.counted(count) : nil
        }
        parts.append(byType.joined(separator: ", "))

        let applied = live.reduce(0) { $0 + $1.timesAppliedSuccess }
        let sessions = Set(live.compactMap(\.conversationId)).count
        if applied > 0 {
            parts.append(sessions > 1 ? "applied \(applied)× across \(sessions) sessions" : "applied \(applied)×")
        }

        if let earliest = live.map(\.createdAt).min() {
            parts.append("captured since \(dayString(earliest))")
        }
        parts.append("exported from Hypermnesia on \(dayString(generatedAt))")
        return "_\(parts.joined(separator: " · "))_"
    }

    /// Provenance/evidence byline under each entry — only claims backed by nonzero counters, plus
    /// a decay warning when the memory is old enough to need review before being relied on.
    private static func metaLine(_ memory: MemoryNode, asOf now: Date) -> String? {
        var parts: [String] = ["Captured \(dayString(memory.createdAt))"]
        if memory.timesAppliedSuccess > 0 { parts.append("applied \(memory.timesAppliedSuccess)×") }
        if memory.timesOverridden > 0 { parts.append("overridden \(memory.timesOverridden)×") }
        if memory.needsRevalidation {
            parts.append("⚠️ aging (\(memory.daysSinceValidation(asOf: now))d unvalidated) — verify before relying on it")
        }
        return "_\(parts.joined(separator: " · "))_"
    }

    /// Concerns lead with the worst severity and backlog with the highest priority; everything
    /// else reads newest-first.
    private static func ordered(_ members: [MemoryNode], for type: MemoryType) -> [MemoryNode] {
        func rank(_ label: String?) -> Int {
            switch label?.lowercased() {
            case "critical": 0
            case "high": 1
            case "medium": 2
            case "low": 3
            default: 4
            }
        }
        switch type {
        case .concern:
            return members.sorted {
                let (a, b) = (rank($0.data.concernData?.severity), rank($1.data.concernData?.severity))
                return a == b ? $0.updatedAt > $1.updatedAt : a < b
            }
        case .backlog:
            return members.sorted {
                let (a, b) = (rank($0.data.backlogData?.priority), rank($1.data.backlogData?.priority))
                return a == b ? $0.updatedAt > $1.updatedAt : a < b
            }
        default:
            return members.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private static func sectionTitle(_ type: MemoryType) -> String {
        switch type {
        case .decision: "Decisions"
        case .convention: "Conventions"
        case .intent: "Intents"
        case .fact: "Facts"
        case .concern: "Concerns"
        case .backlog: "Backlog"
        case .codeRef: "Code References"
        }
    }

    private static func sectionDescription(_ type: MemoryType) -> String {
        switch type {
        case .decision: "Choices made between alternatives, with the rationale — the \"why\" behind the code."
        case .convention: "Rules this project follows. Apply them when they're relevant; note the exclusions."
        case .intent: "Goals and desired behaviors the work is driving toward."
        case .fact: "Stable pieces of project state."
        case .concern: "Known risks, caveats, and gotchas — worst first."
        case .backlog: "Deferred ideas and future work, not yet acted on — highest priority first."
        case .codeRef: "Durable pointers into the codebase."
        }
    }

    /// GitHub-style heading anchor: lowercase, spaces → hyphens.
    private static func anchor(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private static func dayString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func detailBullets(_ data: MemoryData) -> [String] {
        var bullets: [String] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            bullets.append("- \(label): \(value)")
        }
        switch data {
        case .decision(let d):
            add("Problem", d.problem)
            add("Chosen", d.chosen)
            if !d.alternatives.isEmpty { add("Alternatives", d.alternatives.joined(separator: "; ")) }
            add("Rationale", d.rationale)
            if !d.revisitTriggers.isEmpty { add("Revisit when", d.revisitTriggers.joined(separator: "; ")) }
        case .convention(let c):
            add("Rule", c.rule)
            add("Applies when", c.appliesWhen)
            add("Does NOT apply to", c.excludesWhen)
            for example in c.examples {
                add("✗ Bad", example.bad)
                add("✓ Good", example.good)
            }
        case .intent(let i):
            add("Goal", i.goal)
            for b in i.behaviors {
                let line = [b.given.map { "Given \($0)" }, b.when.map { "when \($0)" }, b.then.map { "then \($0)" }]
                    .compactMap { $0 }.joined(separator: ", ")
                add("Behavior", line)
            }
            if !i.constraints.isEmpty { add("Constraints", i.constraints.joined(separator: "; ")) }
        case .fact(let f):
            add("\(f.category) / \(f.key)", f.value)
        case .concern(let c):
            add("Issue", c.issue)
            add("Severity", c.severity)
            add("Affected area", c.affectedArea)
            add("Applies when", c.appliesWhen)
            add("Does NOT apply to", c.excludesWhen)
        case .backlog(let b):
            add("Idea", b.idea)
            add("Priority", b.priority)
            add("Trigger", b.trigger)
        case .codeRef(let r):
            add("Symbol", r.symbolName)
            add("Range", r.range)
        }
        return bullets
    }
}
