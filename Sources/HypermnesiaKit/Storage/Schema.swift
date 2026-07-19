import Foundation
import GRDB

/// Database schema and migrations for the local memory store.
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // Memories
            try db.create(table: "memory_node") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                t.column("type", .text).notNull()
                t.column("status", .text).notNull()
                t.column("title", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("data", .text).notNull()            // JSON {type, content}
                t.column("confidence", .double).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("lastValidatedAt", .datetime)
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("deletedAt", .datetime)
                t.column("supersedesId", .text)
                t.column("supersededById", .text)
                t.column("conversationId", .text)
                t.column("sourceQuote", .text)
                t.column("commitSha", .text)
                t.column("branch", .text)
                t.column("timesApplied", .integer).notNull().defaults(to: 0)
                t.column("timesOverridden", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_node_project_status", on: "memory_node", columns: ["projectId", "status"])
            try db.create(index: "idx_node_project_type", on: "memory_node", columns: ["projectId", "type"])

            // Typed edges (mostly inferred). Composite identity.
            try db.create(table: "memory_edge") { t in
                t.column("projectId", .text).notNull()
                t.column("source", .text).notNull()
                t.column("target", .text).notNull()
                t.column("relationship", .text).notNull()
                t.column("properties", .text)                // JSON
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["projectId", "source", "target", "relationship"])
            }

            // Capture queue (hooks enqueue; daemon/app drains)
            try db.create(table: "capture_queue") { t in
                t.primaryKey("id", .text)
                t.column("sessionId", .text).notNull()
                t.column("projectId", .text).notNull()
                t.column("transcriptPath", .text).notNull()
                t.column("cwd", .text).notNull()
                t.column("gitSha", .text)
                t.column("gitBranch", .text)
                t.column("enqueuedAt", .datetime).notNull()
                t.column("status", .text).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
            }
            try db.create(index: "idx_queue_status", on: "capture_queue", columns: ["status", "enqueuedAt"])

            // Idempotency for live + backfill processing
            try db.create(table: "processed_session") { t in
                t.primaryKey("sessionId", .text)
                t.column("projectId", .text).notNull()
                t.column("processedAt", .datetime).notNull()
                t.column("source", .text).notNull()
                t.column("memoryCount", .integer).notNull().defaults(to: 0)
            }

            // Full-text search over memories (kept in sync by MemoryStore on upsert/delete)
            try db.create(virtualTable: "memory_fts", using: FTS5()) { t in
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("node_id").notIndexed()
                t.column("title")
                t.column("summary")
                t.column("body")
            }
        }

        // v2: incremental (in-session) capture — a per-session cursor + a final-flush flag.
        migrator.registerMigration("v2-incremental") { db in
            try db.create(table: "session_progress") { t in
                t.primaryKey("sessionId", .text)
                t.column("projectId", .text).notNull()
                t.column("eventCursor", .integer).notNull().defaults(to: 0)  // events captured so far
                t.column("updatedAt", .datetime).notNull()
            }
            // Whether the queued session has fully ended (flush remainder regardless of threshold).
            try db.alter(table: "capture_queue") { t in
                t.add(column: "isFinal", .boolean).notNull().defaults(to: false)
            }
        }

        // v3: per-memory vector embeddings for semantic retrieval.
        migrator.registerMigration("v3-embeddings") { db in
            try db.create(table: "memory_embedding") { t in
                t.primaryKey("nodeId", .text)
                t.column("model", .text).notNull()   // embedder identifier (dimensions/model can change)
                t.column("dims", .integer).notNull()
                t.column("vector", .blob).notNull()   // packed Float32
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // v4: evidence-based "belief" (epistemic trust, separate from freshness). Backfill so that the
        // new `confidence = belief × freshness` reproduces each existing node's confidence EXACTLY —
        // i.e. belief = confidence / freshness for decaying types — rather than `belief = confidence`,
        // which would double-decay aged memories and silently drop them out of injection on upgrade.
        // Self-contained: raw rows + inlined freshness buckets (no dependency on evolving app types).
        migrator.registerMigration("v4-belief") { db in
            try db.alter(table: "memory_node") { t in t.add(column: "belief", .double) }
            func freshness(ageDays: Int) -> Double {
                if ageDays < 30 { return 1.00 }
                if ageDays < 90 { return 0.74 }
                if ageDays < 180 { return 0.49 }
                return 0.24
            }
            let decaying: Set<String> = ["decision", "convention", "intent"]
            let rows = try Row.fetchAll(db, sql:
                "SELECT id, type, confidence, lastValidatedAt, createdAt, timesOverridden FROM memory_node")
            for row in rows {
                let id: String = row["id"]
                let type: String = row["type"]
                let confidence: Double = row["confidence"]
                let timesOverridden: Int = row["timesOverridden"]
                var belief = confidence
                if decaying.contains(type) {
                    let anchor: Date = row["lastValidatedAt"] ?? row["createdAt"]
                    let ageDays = max(0, Int(Date().timeIntervalSince(anchor) / 86_400))
                    var reconstructed = confidence / freshness(ageDays: ageDays)
                    // The belief model re-applies a 0.5 override penalty for any node with
                    // timesOverridden > 0 (0 successes at upgrade). Divide it back out here so the
                    // penalty isn't applied twice — otherwise an overridden memory's confidence is
                    // halved on upgrade and "Mark still true" can never restore it.
                    if timesOverridden > 0 { reconstructed /= 0.5 }
                    belief = min(1.0, max(0.01, reconstructed))
                }
                try db.execute(sql: "UPDATE memory_node SET belief = ? WHERE id = ?", arguments: [belief, id])
            }
        }

        // v5: split the overloaded `timesApplied` (which actually counted re-capture SIGHTINGS) into
        // explicit evidence counters. No behavior change: backfill timesSighted = timesApplied, and
        // successes start at 0. `timesApplied`/`timesOverridden` stay for auto-confirm + legacy decay.
        migrator.registerMigration("v5-evidence-counters") { db in
            try db.alter(table: "memory_node") { t in
                t.add(column: "timesSighted", .integer).notNull().defaults(to: 0)
                t.add(column: "timesAppliedSuccess", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "UPDATE memory_node SET timesSighted = timesApplied")
        }

        // v6: remember the last audit outcome per node so a periodic recordOutcomes pass only moves
        // belief when the verdict *changes* (idempotent), instead of compounding the same drift or
        // minting a corroboration on every re-run.
        migrator.registerMigration("v6-audit-outcome") { db in
            try db.alter(table: "memory_node") { t in t.add(column: "lastAuditOutcome", .text) }
        }

        // v7: repair beliefs skewed by the first shipped v4 backfill, which forgot to divide the
        // 0.5 override penalty back out for decaying nodes with timesOverridden > 0. Migrations are
        // keyed by name, so a database that already ran that v4 never re-runs the corrected one —
        // its overridden memories are stuck at half the intended belief ("Mark still true" can never
        // restore them). Invert the missing ÷0.5 here.
        //
        // Scope: every pre-v4 node's stored confidence follows the legacy invariant
        // `confidence = ageMultiplier × overridePenalty` (capture persisted the legacy-decayed
        // value, which ignored classifier confidence), so for overridden decaying rows the
        // corrected v4 always reconstructs belief ≥ 1 → clamps to exactly 1.0, and the buggy v4
        // left belief < 1.0 exactly when the 0.5 penalty was baked into confidence. Doubling those
        // rows (capped at 1.0) therefore reproduces the corrected backfill precisely:
        //   • overridden + penalty baked  → buggy belief ∈ (0, 1) → ×2, capped   (the repair)
        //   • overridden, no penalty baked → belief already 1.0   (excluded by belief < 1.0)
        //   • timesOverridden = 0          → both versions agreed  (excluded)
        //   • non-decaying types           → belief = confidence in both versions (excluded)
        //   • fresh installs / post-fix DBs → v4 ran corrected; their overridden decaying rows
        //     carry belief 1.0, so this is a no-op (and empty DBs have no rows at all).
        // Known trade-off: a node captured *after* the buggy v4 with a genuine prior < 1.0 that
        // later drifted (timesOverridden > 0 via recordOutcomes) is also doubled. The error is
        // bounded (capped at 1.0) and the read-time override penalty still halves such a node,
        // while missing a genuinely skewed row would leave it at half trust forever.
        migrator.registerMigration("v7-belief-repair") { db in
            try db.execute(sql: """
                UPDATE memory_node
                SET belief = MIN(1.0, belief * 2)
                WHERE type IN ('decision', 'convention', 'intent')
                  AND belief IS NOT NULL
                  AND belief < 1.0
                  AND timesOverridden > 0
                """)
        }

        // v8: queued historical sessions retain backfill semantics through the shared drainer.
        migrator.registerMigration("v8-capture-source") { db in
            try db.alter(table: "capture_queue") { t in
                t.add(column: "source", .text).notNull().defaults(to: CaptureSource.live.rawValue)
            }
        }

        // v9: the Dream Journal — one row per project per night the dream loop RAN (dreamed or
        // quiet). Nights with no row read as "skipped" in the 7-night strip. The structured result
        // (epiphanies, proposals, report-backs, stats) lives in `payload` as JSON, mirroring
        // memory_node.data, so the shape can evolve without migrations.
        migrator.registerMigration("v9-dream-journal") { db in
            try db.create(table: "dream_journal") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                t.column("night", .text).notNull()          // local calendar day, "yyyy-MM-dd"
                t.column("createdAt", .datetime).notNull()
                t.column("outcome", .text).notNull()        // dreamed | quiet
                t.column("narrative", .text)
                t.column("payload", .text).notNull()        // JSON DreamPayload
                t.column("unread", .boolean).notNull().defaults(to: false)
                t.column("calls", .integer).notNull().defaults(to: 0)
                t.column("estCostUSD", .double)
            }
            try db.create(
                index: "idx_dream_project_night", on: "dream_journal",
                columns: ["projectId", "night"], unique: true)
        }

        return migrator
    }
}
