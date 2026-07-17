import Foundation

/// A problem found while reality-checking a memory against the current codebase.
public struct AuditFinding: Sendable, Equatable {
    public enum Issue: String, Sendable {
        case missingFile          // a related file no longer exists
        case changedSinceCapture  // a related file changed since the memory's commit
        case outdated             // an LLM judged the memory no longer accurate
    }
    public let nodeId: String
    public let title: String
    public let issue: Issue
    public let detail: String

    public init(nodeId: String, title: String, issue: Issue, detail: String) {
        self.nodeId = nodeId
        self.title = title
        self.issue = issue
        self.detail = detail
    }
}

/// Reality-checks memories against the live repository. Decay handles *age*; this handles *truth* —
/// it stops the system from confidently injecting context the code has moved past.
public enum MemoryAuditor {

    // MARK: - Deterministic checks (no LLM)

    /// Cheap checks against the working tree at `repoPath`: related files that no longer exist, and
    /// files that changed between the memory's commit and HEAD.
    public static func audit(
        store: MemoryStore, projectId: String, repoPath: String, status: MemoryStatus? = .confirmed
    ) -> [AuditFinding] {
        let nodes = (try? store.nodes(projectId: projectId, status: status, limit: 2000)) ?? []
        let head = ProjectIdentity.headSha(cwd: repoPath)
        var findings: [AuditFinding] = []

        for node in nodes {
            for file in node.data.relatedFiles {
                let absolute = absolutePath(file, repoPath: repoPath)
                if !FileManager.default.fileExists(atPath: absolute) {
                    findings.append(.init(nodeId: node.id, title: node.title, issue: .missingFile, detail: file))
                    continue
                }
                if let sha = node.commitSha, let head, sha != head,
                   fileChanged(repoPath: repoPath, from: sha, to: head, file: relativePath(file, repoPath: repoPath)) {
                    findings.append(.init(nodeId: node.id, title: node.title, issue: .changedSinceCapture, detail: file))
                }
            }
        }
        return findings
    }

    // MARK: - LLM verification (deep)

    /// Ask a model whether each memory (with related files) still holds, given the current file
    /// contents. Costs one completion per memory, so it's capped.
    public static func verify(
        store: MemoryStore, projectId: String, repoPath: String, completer: Completer,
        status: MemoryStatus? = .confirmed, limit: Int = 25
    ) async -> [AuditFinding] {
        let nodes = ((try? store.nodes(projectId: projectId, status: status, limit: 2000)) ?? [])
            .filter { !$0.data.relatedFiles.isEmpty }
            .prefix(limit)

        var findings: [AuditFinding] = []
        let system = """
        You verify whether a stored project memory is still accurate given the CURRENT code. Reply \
        with exactly one of STILL_TRUE, OUTDATED, or UNCLEAR on the first line, then one short \
        sentence of reasoning. Judge only from the provided file content.
        """
        for node in nodes {
            let snippets = node.data.relatedFiles.prefix(3).compactMap { file -> String? in
                let path = absolutePath(file, repoPath: repoPath)
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
                return "FILE \(file):\n" + String(content.prefix(4000))
            }
            guard !snippets.isEmpty else { continue }
            let user = "MEMORY: \(node.title) — \(node.summary)\n\n" + snippets.joined(separator: "\n\n")
            guard let answer = try? await completer.complete(system: system, user: user) else { continue }
            if answer.uppercased().hasPrefix("OUTDATED") {
                let reason = answer.split(separator: "\n").dropFirst().joined(separator: " ")
                findings.append(.init(nodeId: node.id, title: node.title, issue: .outdated,
                                      detail: reason.isEmpty ? "model judged this outdated" : String(reason.prefix(160))))
            }
        }
        return findings
    }

    // MARK: - Apply

    /// Penalize the confidence of flagged memories so they drop in the decay model and surface in
    /// Health for review (revalidation resets them). Returns the number of memories affected.
    @discardableResult
    public static func apply(_ findings: [AuditFinding], store: MemoryStore) -> Int {
        // Cap confidence at an absolute floor (not a multiplier) so repeated audit runs don't compound.
        var cap: [String: Double] = [:]
        for finding in findings {
            let floor = (finding.issue == .changedSinceCapture) ? 0.7 : 0.3   // missing/outdated hit harder
            cap[finding.nodeId] = min(cap[finding.nodeId] ?? 1, floor)
        }
        var changed = 0
        for (id, floor) in cap {
            guard var node = try? store.node(id: id), node.confidence > floor else { continue }  // idempotent
            let previousLevel = node.decayLevel
            node.confidence = floor
            node.updatedAt = Date()
            try? store.upsert(node)
            MemoryActivityLog.append(.init(
                projectId: node.projectId,
                eventType: .applyOverride,
                memoryIds: [node.id],
                count: 1,
                metadata: ["source": "audit_apply", "floor": String(format: "%.2f", floor)]
            ))
            let nextLevel = node.decayLevel
            if nextLevel != previousLevel {
                MemoryActivityLog.append(.init(
                    projectId: node.projectId,
                    eventType: .decayTransition,
                    memoryIds: [node.id],
                    count: 1,
                    metadata: ["from": previousLevel.rawValue, "to": nextLevel.rawValue]
                ))
            }
            changed += 1
        }
        return changed
    }

    // MARK: - Outcome instrumentation (belief evidence)

    /// Translate a deterministic reality-check into belief evidence (the coarse audit-based proxy):
    /// a confirmed memory with related files that are all present & unchanged is **corroborated**
    /// (a non-recapture corroborator → `timesAppliedSuccess`); one with a missing/changed file has
    /// **drifted** (→ `timesOverridden`, which drives belief down fast). Memories without related
    /// files are skipped (no code signal). Returns the counts touched.
    @discardableResult
    public static func recordOutcomes(store: MemoryStore, projectId: String, repoPath: String) -> (corroborated: Int, drifted: Int) {
        let flagged = Set(audit(store: store, projectId: projectId, repoPath: repoPath).map(\.nodeId))
        let nodes = ((try? store.nodes(projectId: projectId, status: .confirmed, limit: 2000)) ?? [])
            .filter { !$0.data.relatedFiles.isEmpty }
        var corroborated = 0, drifted = 0
        for node in nodes {
            guard var n = try? store.node(id: node.id) else { continue }
            // Idempotent: only record an outcome when the verdict *changed* since the last pass.
            // Re-running with the same drift (or the same clean result) must not compound — otherwise
            // one stale file drives timesOverridden up every run, and no-op re-runs mint free
            // corroborations, exactly the inflation the anti-gaming design forbids.
            let outcome = flagged.contains(node.id) ? "drift" : "consistent"
            guard n.lastAuditOutcome != outcome else { continue }
            n.lastAuditOutcome = outcome
            // Baseline against the decayed-to-now level so a logged decay_transition reflects the
            // outcome's effect, not stale-confidence time-decay catch-up (which isn't this change).
            let previousLevel = DecayEngine.decayed(n).decayLevel
            if outcome == "drift" {
                n.timesOverridden += 1
                drifted += 1
                MemoryActivityLog.append(.init(
                    projectId: n.projectId,
                    eventType: .applyOverride,
                    memoryIds: [n.id],
                    count: 1,
                    metadata: ["source": "audit_outcome"]
                ))
            } else {
                n.timesAppliedSuccess += 1
                corroborated += 1
                MemoryActivityLog.append(.init(
                    projectId: n.projectId,
                    eventType: .applySuccess,
                    memoryIds: [n.id],
                    count: 1,
                    metadata: ["source": "audit_outcome"]
                ))
            }
            n.updatedAt = Date()
            // Recompute confidence from the new evidence immediately, so outcomes are live without
            // waiting for a later decay pass (the hydrator reads stored confidence).
            if n.type.decaysWithTime {
                n.confidence = DecayEngine.decayed(n).confidence
            } else {
                // Facts/concerns/backlog/codeRefs don't age, so decayed() is a no-op — apply the
                // outcome to confidence directly, else a falsified fact keeps injecting at full trust.
                n.confidence = outcome == "drift"
                    ? max(0.01, n.confidence * BeliefEngine.overridePenalty)
                    : 1.0
            }
            try? store.upsert(n)
            let nextLevel = n.decayLevel
            if nextLevel != previousLevel {
                MemoryActivityLog.append(.init(
                    projectId: n.projectId,
                    eventType: .decayTransition,
                    memoryIds: [n.id],
                    count: 1,
                    metadata: ["from": previousLevel.rawValue, "to": nextLevel.rawValue]
                ))
            }
        }
        return (corroborated, drifted)
    }

    // MARK: - Repo path resolution

    /// The local working-tree path for a project id, if it can be determined: `path:` ids carry it
    /// directly; for git-remote ids, look it up from a recent session's cwd.
    public static func repoPath(forProjectId projectId: String) -> String? {
        if projectId.hasPrefix("path:") { return String(projectId.dropFirst(5)) }
        var resolved = Set<String>()   // distinct cwds only, so git runs at most once per directory
        for transcript in ClaudeCodeSessions.allTranscripts().reversed() {   // newest first
            guard let cwd = ClaudeCodeSessions.firstCwd(of: transcript.url),
                  resolved.insert(cwd).inserted else { continue }
            if ProjectIdentity.resolve(cwd: cwd) == projectId {
                return ProjectIdentity.repoRoot(cwd: cwd) ?? cwd
            }
        }
        return nil
    }

    // MARK: - Helpers

    static func absolutePath(_ file: String, repoPath: String) -> String {
        file.hasPrefix("/") ? file : (repoPath as NSString).appendingPathComponent(file)
    }

    static func relativePath(_ file: String, repoPath: String) -> String {
        let root = repoPath.hasSuffix("/") ? repoPath : repoPath + "/"
        return file.hasPrefix(root) ? String(file.dropFirst(root.count)) : file
    }

    /// True iff `git diff --quiet from to -- file` reports a change (exit 1). Other exits → unknown.
    static func fileChanged(repoPath: String, from: String, to: String, file: String) -> Bool {
        Shell.run("git", ["-C", repoPath, "diff", "--quiet", from, to, "--", file], cwd: repoPath).status == 1
    }
}
