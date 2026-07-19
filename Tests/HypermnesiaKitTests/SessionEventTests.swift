import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("SessionEvents")
struct SessionEventTests {

    private func tempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func event(
        id: String = UUID().uuidString,
        at timestamp: Date = Date(),
        kind: SessionEvent.Kind,
        startedAt: Date? = nil,
        session: String,
        title: String? = "Fix the flaky auth test",
        message: String? = nil
    ) -> SessionEvent {
        SessionEvent(
            id: id, timestamp: timestamp, kind: kind, startedAt: startedAt, client: "claude",
            sessionId: session, projectId: "github.com/acme/widgets", cwd: "/tmp/widgets",
            title: title, message: message,
            hostPids: [4242], hostPaths: ["/Applications/iTerm.app/Contents/MacOS/iTerm2"],
            tty: "ttys004")
    }

    // MARK: - Log

    @Test("log round-trips events in order, isolated to the given directory")
    func logRoundTrip() throws {
        let dir = try tempDir("selog")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Whole-second timestamps: the log's ISO8601 encoding drops sub-second precision.
        let first = event(at: Date(timeIntervalSince1970: 1_784_000_000), kind: .finished, session: "s1")
        let second = event(at: Date(timeIntervalSince1970: 1_784_000_060), kind: .attention, session: "s2",
                           message: "Claude needs your permission to use Bash")
        SessionEventLog.append(first, in: dir)
        SessionEventLog.append(second, in: dir)

        let read = SessionEventLog.recent(in: dir)
        #expect(read == [first, second])
        #expect(read[1].needsPermission)
        #expect(!read[0].needsPermission)

        // The live feed file is private to the user, like the activity log.
        let perms = try FileManager.default.attributesOfItem(
            atPath: SessionEventLog.fileURL(in: dir).path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test("touch creates an empty log file for the watcher to attach to")
    func touchCreates() throws {
        let dir = try tempDir("setouch")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SessionEventLog.recent(in: dir).isEmpty)
        SessionEventLog.touch(in: dir)
        #expect(FileManager.default.fileExists(atPath: SessionEventLog.fileURL(in: dir).path))
        #expect(SessionEventLog.recent(in: dir).isEmpty)
    }

    // MARK: - Reducer

    @Test("latest event per session wins, and ended clears the card")
    func latestWinsAndEndedClears() {
        let now = Date()
        let events = [
            event(at: now.addingTimeInterval(-30), kind: .attention, session: "s1", message: "permission"),
            event(at: now.addingTimeInterval(-20), kind: .finished, session: "s1"),
            event(at: now.addingTimeInterval(-25), kind: .finished, session: "s2"),
            event(at: now.addingTimeInterval(-10), kind: .ended, session: "s2"),
        ]
        let cards = SessionEventFeed.cards(events: events, now: now)
        #expect(cards.count == 1)
        #expect(cards.first?.event.sessionId == "s1")
        #expect(cards.first?.event.kind == .finished)   // the newer finish replaced the attention card
    }

    @Test("finished cards expire quickly; attention cards persist to their longer TTL")
    func kindTTLs() {
        let now = Date()
        let events = [
            event(at: now.addingTimeInterval(-SessionEventFeed.finishedTTL - 1), kind: .finished, session: "s1"),
            event(at: now.addingTimeInterval(-SessionEventFeed.finishedTTL - 1), kind: .attention, session: "s2"),
            event(at: now.addingTimeInterval(-SessionEventFeed.attentionTTL - 1), kind: .attention, session: "s3"),
        ]
        let cards = SessionEventFeed.cards(events: events, now: now)
        #expect(cards.map(\.event.sessionId) == ["s2"])   // s1 aged out fast, s3 abandoned
    }

    @Test("dismissal is per-event: a newer event for the same session pops again")
    func dismissalIsPerEvent() {
        let now = Date()
        let old = event(id: "e1", at: now.addingTimeInterval(-40), kind: .finished, session: "s1")
        let new = event(id: "e2", at: now.addingTimeInterval(-5), kind: .finished, session: "s1")
        #expect(SessionEventFeed.cards(events: [old], dismissedEventIds: ["e1"], now: now).isEmpty)
        #expect(SessionEventFeed.cards(events: [old, new], dismissedEventIds: ["e1"], now: now).count == 1)
    }

    @Test("attention outranks finished; newest first within a kind; capped at maxCards")
    func orderingAndCap() {
        let now = Date()
        var events: [SessionEvent] = [
            event(at: now.addingTimeInterval(-10), kind: .finished, session: "f1"),
            event(at: now.addingTimeInterval(-5), kind: .finished, session: "f2"),
            event(at: now.addingTimeInterval(-60), kind: .attention, session: "a1", message: "permission"),
        ]
        var cards = SessionEventFeed.cards(events: events, now: now)
        #expect(cards.map(\.event.sessionId) == ["a1", "f2", "f1"])

        for index in 0..<SessionEventFeed.maxCards {
            events.append(event(at: now.addingTimeInterval(Double(index - 50)), kind: .attention, session: "extra\(index)"))
        }
        cards = SessionEventFeed.cards(events: events, now: now)
        #expect(cards.count == SessionEventFeed.maxCards)
        #expect(cards.allSatisfy { $0.event.kind == .attention })   // finished pops yield to attention
    }

    // MARK: - Working state

    @Test("a working event swallows the session's pop card — the stale-attention fix")
    func workingSwallowsCards() {
        let now = Date()
        let events = [
            event(at: now.addingTimeInterval(-120), kind: .attention, session: "s1", message: "permission"),
            event(at: now.addingTimeInterval(-40), kind: .finished, session: "s2"),
            // The user approved s1's prompt in the terminal; its next tool call heartbeats.
            event(at: now.addingTimeInterval(-10), kind: .working, session: "s1"),
        ]
        #expect(SessionEventFeed.cards(events: events, now: now).map(\.event.sessionId) == ["s2"])
        #expect(SessionEventFeed.working(events: events, now: now).map(\.event.sessionId) == ["s1"])

        // …and when that turn finishes, the pop card comes back and the strip empties.
        let done = events + [event(at: now, kind: .finished, session: "s1")]
        #expect(SessionEventFeed.cards(events: done, now: now).map(\.event.sessionId) == ["s1", "s2"])
        #expect(SessionEventFeed.working(events: done, now: now).isEmpty)
    }

    @Test("working sessions expire at their TTL, clear on ended, and never appear as cards")
    func workingTTLAndClear() {
        let now = Date()
        let events = [
            event(at: now.addingTimeInterval(-SessionEventFeed.workingTTL - 1), kind: .working, session: "stale"),
            event(at: now.addingTimeInterval(-5), kind: .working, session: "live"),
            event(at: now.addingTimeInterval(-30), kind: .working, session: "gone"),
            event(at: now.addingTimeInterval(-2), kind: .ended, session: "gone"),
        ]
        #expect(SessionEventFeed.working(events: events, now: now).map(\.event.sessionId) == ["live"])
        #expect(SessionEventFeed.cards(events: events, now: now).isEmpty)
    }

    @Test("working rows order by turn start and stay stable across heartbeat refreshes")
    func workingOrderStable() {
        let now = Date()
        let oldTurn = now.addingTimeInterval(-14 * 60)
        let newTurn = now.addingTimeInterval(-3 * 60)
        let events = [
            event(at: now.addingTimeInterval(-25), kind: .working, startedAt: newTurn, session: "young"),
            event(at: now.addingTimeInterval(-20), kind: .working, startedAt: oldTurn, session: "old"),
            // A fresh heartbeat for the young session must not reorder anything.
            event(at: now.addingTimeInterval(-1), kind: .working, startedAt: newTurn, session: "young"),
        ]
        #expect(SessionEventFeed.working(events: events, now: now).map(\.event.sessionId) == ["old", "young"])
    }

    @Test("heartbeats throttle against a fresh working event and inherit the turn's start + title")
    func heartbeatThrottleAndInheritance() {
        let now = Date()
        let turnStart = now.addingTimeInterval(-10 * 60)

        // Fresh working event → throttled; stale (or non-working latest) → append.
        let fresh = [event(at: now.addingTimeInterval(-5), kind: .working, session: "s1")]
        #expect(SessionEventHeartbeat.throttled(events: fresh, sessionId: "s1", now: now))
        #expect(!SessionEventHeartbeat.throttled(events: fresh, sessionId: "other", now: now))
        let staleBeat = [event(at: now.addingTimeInterval(-SessionEventHeartbeat.minInterval - 1),
                               kind: .working, session: "s1")]
        #expect(!SessionEventHeartbeat.throttled(events: staleBeat, sessionId: "s1", now: now))
        let paused = [event(at: now.addingTimeInterval(-5), kind: .attention, session: "s1")]
        #expect(!SessionEventHeartbeat.throttled(events: paused, sessionId: "s1", now: now))

        // An attention pause mid-turn doesn't break the working chain: the beat after approval
        // keeps the original start (so "working 12m" stays honest) and the known title.
        let chain = [
            event(at: turnStart, kind: .working, startedAt: turnStart, session: "s1",
                  title: "Migrate the store"),
            event(at: now.addingTimeInterval(-60), kind: .attention, session: "s1",
                  title: nil, message: "permission"),
        ]
        let inherited = SessionEventHeartbeat.inheritance(events: chain, sessionId: "s1", now: now)
        #expect(inherited.startedAt == turnStart)
        #expect(inherited.title == "Migrate the store")

        // A dead chain (last working beat beyond the TTL) means this beat starts a new turn.
        let dead = [event(at: now.addingTimeInterval(-SessionEventFeed.workingTTL - 60),
                          kind: .working, startedAt: turnStart, session: "s1")]
        #expect(SessionEventHeartbeat.inheritance(events: dead, sessionId: "s1", now: now).startedAt == nil)
    }

    @Test("startedAt round-trips through the log and is omitted from JSON when absent")
    func startedAtCodable() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bare = String(decoding: try encoder.encode(event(kind: .finished, session: "s1")), as: UTF8.self)
        #expect(!bare.contains("\"startedAt\""))

        let dir = try tempDir("sestart")
        defer { try? FileManager.default.removeItem(at: dir) }
        let working = event(
            at: Date(timeIntervalSince1970: 1_784_000_120), kind: .working,
            startedAt: Date(timeIntervalSince1970: 1_784_000_000), session: "s1")
        SessionEventLog.append(working, in: dir)
        #expect(SessionEventLog.recent(in: dir) == [working])
    }

    // MARK: - Titles

    @Test("quickTitle takes the first real user request, skipping tool noise, and truncates")
    func quickTitle() throws {
        let dir = try tempDir("setitle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        let longTail = String(repeating: "x", count: 200)
        let fixture = """
        {"type":"queue-operation","operation":"enqueue","timestamp":"2026-06-01T10:00:00.000Z","sessionId":"s1","content":"noise"}
        {"type":"user","timestamp":"2026-06-01T10:00:01.000Z","cwd":"/Users/x/proj","sessionId":"s1","message":{"role":"user","content":"Caveat: the messages below were generated by the user"}}
        {"type":"user","timestamp":"2026-06-01T10:00:02.000Z","cwd":"/Users/x/proj","sessionId":"s1","message":{"role":"user","content":"<system-reminder>ignore me</system-reminder>"}}
        {"type":"user","timestamp":"2026-06-01T10:00:03.000Z","cwd":"/Users/x/proj","sessionId":"s1","message":{"role":"user","content":"Switch the database\\nfrom MySQL to Postgres \(longTail)"}}
        """
        try Data(fixture.utf8).write(to: transcript)

        let title = try #require(SessionEventLog.quickTitle(transcriptPath: transcript.path))
        #expect(title.hasPrefix("Switch the database from MySQL to Postgres"))
        #expect(title.count <= 90)
        #expect(title.hasSuffix("…"))
        #expect(!title.contains("\n"))

        #expect(SessionEventLog.quickTitle(transcriptPath: dir.appendingPathComponent("missing.jsonl").path) == nil)
    }

    @Test("quickTitle drops a byte-capped truncated final line instead of poisoning the parse")
    func quickTitleTruncatesAtLastNewline() throws {
        let dir = try tempDir("setitle-cap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        let good = #"{"type":"user","timestamp":"2026-06-01T10:00:01.000Z","sessionId":"s1","message":{"role":"user","content":"Recover me"}}"# + "\n"
        let pad = String(repeating: "y", count: 200)
        let truncated = #"{"type":"user","message":{"role":"user","content":"\#(pad)"#  // no closing braces
        let body = good + truncated
        try Data(body.utf8).write(to: transcript)

        let title = SessionEventLog.quickTitle(transcriptPath: transcript.path, maxBytes: body.utf8.count)
        #expect(title == "Recover me")
    }

    // MARK: - Demo preview

    @Test("demo events render three cards (attention first) plus two working rows; clearEvents retracts all")
    func demoEventsAndClear() {
        let now = Date()
        let events = SessionEventDemo.events(
            cwd: "/tmp/demo-proj", hostPids: [7], hostPaths: ["/bin/echo"], tty: nil, now: now)
        #expect(events.count == 5)
        #expect(events.allSatisfy { $0.isDemo })

        let cards = SessionEventFeed.cards(events: events, now: now)
        #expect(cards.count == 3)                        // every age sits inside the finished TTL
        #expect(cards.first?.event.kind == .attention)
        #expect(cards.first?.event.needsPermission == true)
        let working = SessionEventFeed.working(events: events, now: now)
        #expect(working.count == 2)
        #expect(working.allSatisfy { $0.event.startedAt != nil })

        let after = now.addingTimeInterval(1)
        let clearedEvents = events + SessionEventDemo.clearEvents(now: after)
        #expect(SessionEventFeed.cards(events: clearedEvents, now: after).isEmpty)
        #expect(SessionEventFeed.working(events: clearedEvents, now: after).isEmpty)

        // Re-running the demo replaces the cards (same session ids) with fresh event ids, so a
        // dismissed card pops again.
        let rerun = SessionEventDemo.events(cwd: "/tmp/demo-proj", now: after)
        #expect(Set(rerun.map(\.sessionId)) == Set(events.map(\.sessionId)))
        #expect(Set(rerun.map(\.id)).isDisjoint(with: Set(events.map(\.id))))
    }

    @Test("real events omit the demo key from their JSON entirely")
    func demoKeyOmittedForRealEvents() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let real = String(decoding: try encoder.encode(event(kind: .finished, session: "s1")), as: UTF8.self)
        #expect(!real.contains("\"demo\""))
        let demo = String(decoding: try encoder.encode(
            SessionEventDemo.events(cwd: "/tmp/x").first!), as: UTF8.self)
        #expect(demo.contains("\"demo\":true"))
    }

    // MARK: - Ancestry

    @Test("process ancestry walks real parents with usable paths")
    func ancestry() {
        let chain = ProcessAncestry.chain(from: ProcessInfo.processInfo.processIdentifier)
        #expect(!chain.isEmpty)
        #expect(chain.first?.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(chain.allSatisfy { !$0.path.isEmpty })
        // Walking from the parent yields the same chain minus ourselves.
        let fromParent = ProcessAncestry.chain()
        #expect(fromParent.first?.pid == getppid())
        // Must not crash regardless of whether the test runner has a controlling terminal.
        _ = ProcessAncestry.controllingTerminal()
    }
}
