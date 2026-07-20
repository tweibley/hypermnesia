import Foundation
import Testing
@testable import HypermnesiaKit

// Regression coverage for cluster LOW-app.
//
// The kit-level bug in this cluster is SessionEventFeed.cards truncating to `maxCards` BEFORE the
// notch controller applies the user's kind preferences: four live `.attention` events (15-minute
// TTL) would consume the entire card budget and starve the `.finished` pops a user explicitly
// enabled while disabling attention. The fix pushes a kind allow-list into `cards()` so the
// `prefix(maxCards)` cap is taken over the cards the user actually wants.
//
// The remaining bugs in the cluster live in the SwiftUI app target (BrainMRIView layout
// memoization, Settings storage counting off the main actor, the Notch dream-chip subtitle), which
// has no unit-test target — they are covered by the compile step.

@Suite("BugFix LOW-app")
struct BugFix_LOWappTests {

    private func event(
        id: String = UUID().uuidString,
        at timestamp: Date = Date(),
        kind: SessionEvent.Kind,
        session: String
    ) -> SessionEvent {
        SessionEvent(
            id: id, timestamp: timestamp, kind: kind, client: "claude",
            sessionId: session, projectId: "p", title: "Task \(session)")
    }

    @Test("finished pops survive a flood of attention events when only finished is allowed")
    func finishedNotStarvedByAttentionFlood() {
        let now = Date()
        // Five recent attention events (well inside the 15-minute attention TTL) plus one finished.
        var events: [SessionEvent] = (0..<5).map {
            event(at: now.addingTimeInterval(-Double($0)), kind: .attention, session: "att-\($0)")
        }
        events.append(event(at: now.addingTimeInterval(-1), kind: .finished, session: "fin"))

        // User disabled attention pops, kept finished pops: only .finished is allowed.
        let cards = SessionEventFeed.cards(events: events, allowedKinds: [.finished], now: now)

        #expect(cards.count == 1)
        #expect(cards.first?.event.sessionId == "fin")
        #expect(cards.allSatisfy { $0.event.kind == .finished })
    }

    @Test("default allow-list keeps both poppable kinds and still honors the maxCards cap")
    func defaultAllowsBothKindsAndCaps() {
        let now = Date()
        // Six finished events, all fresh (finished TTL is 90s).
        let events: [SessionEvent] = (0..<6).map {
            event(at: now.addingTimeInterval(-Double($0)), kind: .finished, session: "s-\($0)")
        }
        let cards = SessionEventFeed.cards(events: events, now: now)
        #expect(cards.count == SessionEventFeed.maxCards)
    }

    @Test("attention-only allow-list drops finished cards entirely")
    func attentionOnlyDropsFinished() {
        let now = Date()
        let events = [
            event(at: now, kind: .finished, session: "fin"),
            event(at: now, kind: .attention, session: "att"),
        ]
        let cards = SessionEventFeed.cards(events: events, allowedKinds: [.attention], now: now)
        #expect(cards.count == 1)
        #expect(cards.first?.event.kind == .attention)
    }
}
