import Foundation
import GRDB
import Testing
@testable import HypermnesiaKit

@Suite("DecayBelief")
struct DecayBeliefTests {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func convention(confidence: Double, belief: Double?, ageDays: Int) -> MemoryNode {
        MemoryNode(
            projectId: "p", type: .convention, title: "t", summary: "s",
            data: .convention(.init(rule: "r")),
            confidence: confidence, belief: belief,
            createdAt: now.addingTimeInterval(-Double(ageDays) * 86_400),
            lastValidatedAt: nil)
    }

    @Test("belief-bearing node decays as belief × freshness")
    func beliefTimesFreshness() {
        let fresh = DecayEngine.decayed(convention(confidence: 0.0, belief: 0.8, ageDays: 5), asOf: now)
        #expect(abs(fresh.confidence - 0.8) < 1e-9)                  // freshness 1.0
        let aged = DecayEngine.decayed(convention(confidence: 0.0, belief: 0.8, ageDays: 45), asOf: now)
        #expect(abs(aged.confidence - 0.8 * 0.74) < 1e-9)           // freshness 0.74 (aging band)
    }

    @Test("legacy nodes (nil belief) keep the old age × override decay")
    func legacyUnchanged() {
        let legacy = DecayEngine.decayed(convention(confidence: 0.9, belief: nil, ageDays: 5), asOf: now)
        let expected = DecayEngine.confidence(ageDays: 5, timesApplied: 0, timesOverridden: 0)
        #expect(abs(legacy.confidence - expected) < 1e-9)
    }

    @Test("migration backfill invariant: belief = confidence/freshness reproduces confidence exactly")
    func migrationInvariant() {
        // Legacy confidence is always ageMultiplier × penalty (≤ freshness), so confidence/freshness
        // never clamps and decayed() reproduces the original confidence — no cratering on upgrade.
        for ageDays in [5, 45, 120, 250] {
            let fresh = DecayEngine.ageMultiplier(ageDays: ageDays)
            for penalty in [1.0, 0.5] {
                let legacyConfidence = fresh * penalty
                let backfilledBelief = min(1.0, max(0.01, legacyConfidence / fresh))
                let migrated = DecayEngine.decayed(
                    convention(confidence: legacyConfidence, belief: backfilledBelief, ageDays: ageDays), asOf: now)
                #expect(abs(migrated.confidence - legacyConfidence) < 1e-9)
            }
        }
    }

    @Test("capture sets belief from the (validator-adjusted) classifier confidence; the weak cap now sticks")
    func captureSetsBelief() {
        // A weak capture is capped to 0.55 by the validator; before the belief model, decay would
        // overwrite this to 1.0 for a fresh convention. Now it survives.
        let weak = ClassifiedMemory(type: .convention, confidence: 0.55, title: "t", summary: "s",
                                    context: ["rule": .string("r")])
        let node = DecayEngine.decayed(
            weak.toDraftNode(projectId: "p", sessionId: "sess", createdAt: now), asOf: now)
        #expect(node.belief == 0.55)
        #expect(abs(node.confidence - 0.55) < 1e-9)   // NOT forced to 1.0
    }

    @Test("v4 migration backfills belief on a pre-existing legacy row (exercises the real ALTER+UPDATE)")
    func v4BackfillOnLegacyData() throws {
        let dbQueue = try DatabaseQueue()        // in-memory
        let migrator = Schema.migrator
        try migrator.migrate(dbQueue, upTo: "v3-embeddings")   // a DB as it existed BEFORE belief

        // A legacy convention: confidence = freshness(95d)=0.49 × penalty 1.0. Inserted with NO belief column.
        let age95 = Date().addingTimeInterval(-95 * 86_400)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO memory_node
                  (id, projectId, type, status, title, summary, data, confidence, createdAt, updatedAt, version, timesApplied, timesOverridden)
                VALUES ('n1','p','convention','confirmed','t','s','{"type":"convention","content":{"rule":"r"}}',
                        0.49, ?, ?, 1, 0, 0)
                """, arguments: [age95, age95])
        }

        try migrator.migrate(dbQueue)            // apply v4 → ALTER + backfill loop

        let belief = try dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT belief FROM memory_node WHERE id = 'n1'")
        }
        // belief = confidence / freshness(95) = 0.49 / 0.49 = 1.0, so belief × freshness reproduces 0.49.
        let unwrapped = try #require(belief)
        #expect(abs(unwrapped - 1.0) < 0.02)
    }

    @Test("v7 repairs beliefs skewed by the buggy first-shipped v4 to match a fresh install")
    func v7RepairsBuggyV4Beliefs() throws {
        // The first shipped v4 backfilled `belief = clamp(confidence / freshness)` WITHOUT dividing
        // the 0.5 override penalty back out for overridden decaying nodes. Databases that ran it
        // never re-run the corrected v4 (same migration name), so v7 must repair them in place to
        // the values a fresh install (corrected v4) computes from the same legacy data.

        // Legacy rows as they existed pre-v4. Stored confidence follows the legacy invariant
        // confidence = ageMultiplier(at bake time) × overridePenalty(at bake time).
        struct LegacyRow {
            let id: String, type: String, confidence: Double, ageDays: Int
            let timesApplied: Int, timesOverridden: Int
        }
        let rows: [LegacyRow] = [
            // Penalty baked, same freshness bucket at bake and migration: buggy 0.5 → correct 1.0.
            .init(id: "penalized-same-bucket", type: "convention",
                  confidence: 0.49 * 0.5, ageDays: 95, timesApplied: 3, timesOverridden: 2),
            // Penalty baked while Aging (0.74), migrated while Stale (0.49): buggy ≈0.755 → 1.0.
            .init(id: "penalized-bucket-drift", type: "decision",
                  confidence: 0.74 * 0.5, ageDays: 95, timesApplied: 3, timesOverridden: 2),
            // Overridden but under the 30% rate at bake (no penalty in confidence): both versions
            // clamp to 1.0 — v7 must leave it alone.
            .init(id: "overridden-no-penalty", type: "intent",
                  confidence: 0.49, ageDays: 95, timesApplied: 10, timesOverridden: 2),
            // Never overridden: both versions agree — untouched.
            .init(id: "clean", type: "convention",
                  confidence: 0.74, ageDays: 45, timesApplied: 2, timesOverridden: 0),
            // Non-decaying type with overrides: belief = confidence in BOTH versions; v7 must not
            // double it even though belief < 1.0 and timesOverridden > 0.
            .init(id: "fact-overridden", type: "fact",
                  confidence: 0.8, ageDays: 95, timesApplied: 3, timesOverridden: 2),
        ]

        func seedLegacy(_ db: Database) throws {
            for row in rows {
                let anchor = Date().addingTimeInterval(-Double(row.ageDays) * 86_400)
                try db.execute(sql: """
                    INSERT INTO memory_node
                      (id, projectId, type, status, title, summary, data, confidence, createdAt, updatedAt, version, timesApplied, timesOverridden)
                    VALUES (?, 'p', ?, 'confirmed', 't', 's', '{"type":"fact","content":{"statement":"x"}}',
                            ?, ?, ?, 1, ?, ?)
                    """, arguments: [row.id, row.type, row.confidence, anchor, anchor,
                                     row.timesApplied, row.timesOverridden])
            }
        }

        // The buggy backfill, replicated verbatim from the first shipped v4 (no ÷0.5 for
        // overridden nodes).
        func buggyV4Belief(type: String, confidence: Double, ageDays: Int) -> Double {
            func freshness(ageDays: Int) -> Double {
                if ageDays < 30 { return 1.00 }
                if ageDays < 90 { return 0.74 }
                if ageDays < 180 { return 0.49 }
                return 0.24
            }
            guard ["decision", "convention", "intent"].contains(type) else { return confidence }
            return min(1.0, max(0.01, confidence / freshness(ageDays: ageDays)))
        }

        // DB-A: a database that ran the BUGGY v4, now upgrading. Migrate to v6 (schema in place),
        // then force the belief column into the buggy v4's output before applying v7.
        let upgraded = try DatabaseQueue()
        try Schema.migrator.migrate(upgraded, upTo: "v3-embeddings")
        try upgraded.write { db in try seedLegacy(db) }
        try Schema.migrator.migrate(upgraded, upTo: "v6-audit-outcome")
        try upgraded.write { db in
            for row in rows {
                try db.execute(sql: "UPDATE memory_node SET belief = ? WHERE id = ?",
                               arguments: [buggyV4Belief(type: row.type, confidence: row.confidence,
                                                         ageDays: row.ageDays), row.id])
            }
            // A node captured after the belief model with no belief yet (e.g. seeded externally):
            // v7's IS NOT NULL guard must leave it NULL, even with overrides.
            try db.execute(sql: """
                INSERT INTO memory_node
                  (id, projectId, type, status, title, summary, data, confidence, createdAt, updatedAt, version, timesApplied, timesOverridden)
                VALUES ('null-belief', 'p', 'convention', 'confirmed', 't', 's',
                        '{"type":"fact","content":{"statement":"x"}}', 0.5, ?, ?, 1, 2, 1)
                """, arguments: [Date(), Date()])
        }
        // Sanity: the seeded state really is skewed (half the corrected value).
        let skewed = try #require(try upgraded.read { db in
            try Double.fetchOne(db, sql: "SELECT belief FROM memory_node WHERE id = 'penalized-same-bucket'")
        })
        #expect(abs(skewed - 0.5) < 1e-9)

        try Schema.migrator.migrate(upgraded)   // applies v7-belief-repair

        // DB-B: a fresh install — the same legacy data migrated with the CORRECTED v4 (v7 no-op).
        let fresh = try DatabaseQueue()
        try Schema.migrator.migrate(fresh, upTo: "v3-embeddings")
        try fresh.write { db in try seedLegacy(db) }
        try Schema.migrator.migrate(fresh)

        for row in rows {
            let repaired = try upgraded.read { db in
                try Double.fetchOne(db, sql: "SELECT belief FROM memory_node WHERE id = ?", arguments: [row.id])
            }
            let expected = try fresh.read { db in
                try Double.fetchOne(db, sql: "SELECT belief FROM memory_node WHERE id = ?", arguments: [row.id])
            }
            let repairedValue = try #require(repaired, "\(row.id) has no belief after repair")
            let expectedValue = try #require(expected, "\(row.id) has no belief on fresh install")
            #expect(abs(repairedValue - expectedValue) < 1e-9,
                    "\(row.id): repaired \(repairedValue) ≠ fresh install \(expectedValue)")
        }
        // Spot-check the intended values: overridden decaying rows land at exactly 1.0 (the
        // corrected backfill always clamps there), the fact keeps belief = confidence.
        let beliefs = try upgraded.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, belief FROM memory_node")
                .map { ($0["id"] as String, $0["belief"] as Double?) })
        }
        #expect(beliefs["penalized-same-bucket"] == 1.0)
        #expect(beliefs["penalized-bucket-drift"] == 1.0)
        #expect(beliefs["overridden-no-penalty"] == 1.0)
        #expect(beliefs["fact-overridden"] == 0.8)
        #expect(beliefs["null-belief"] == Double?.none)
    }

    @Test("v5 migration backfills timesSighted = timesApplied (no behavior change)")
    func v5BackfillCounters() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = Schema.migrator
        try migrator.migrate(dbQueue, upTo: "v4-belief")    // before the evidence counters
        let when = Date()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO memory_node
                  (id, projectId, type, status, title, summary, data, confidence, createdAt, updatedAt, version, timesApplied, timesOverridden)
                VALUES ('n1','p','convention','confirmed','t','s','{"type":"convention","content":{"rule":"r"}}',
                        0.8, ?, ?, 1, 3, 0)
                """, arguments: [when, when])
        }
        try migrator.migrate(dbQueue)    // apply v5
        let (sighted, success) = try dbQueue.read { db -> (Int, Int) in
            let row = try Row.fetchOne(db, sql: "SELECT timesSighted, timesAppliedSuccess FROM memory_node WHERE id='n1'")!
            return (row["timesSighted"], row["timesAppliedSuccess"])
        }
        #expect(sighted == 3)     // = old timesApplied
        #expect(success == 0)     // conservative
    }
}
