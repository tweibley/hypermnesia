import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A live session status event appended by the `session-event` hook and watched by the app's
/// notch status display: the agent finished its turn, the session needs the user (a permission
/// request or waiting for input), or the session ended.
public struct SessionEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// UserPromptSubmit / heartbeat — a turn is in flight; the agent is doing work right now.
        case working
        /// Stop — the agent completed its turn and the session is waiting for the user.
        case finished
        /// Notification — the session is blocked on the user (permission / waiting for input).
        case attention
        /// SessionEnd — the session closed; any pending cards for it are stale.
        case ended
    }

    public let id: String
    public let timestamp: Date
    public let kind: Kind
    /// For `working` events: when the current turn began. Turn-start hooks stamp it; heartbeats
    /// inherit it, so "working for 12m" survives timestamp refreshes. Omitted on other kinds.
    public let startedAt: Date?
    /// "claude" | "cursor" | "antigravity" — the emitting client.
    public let client: String
    public let sessionId: String
    public let projectId: String
    public let cwd: String?
    /// Condensed first user request — the "which session is this" label.
    public let title: String?
    /// The client's own notification text (e.g. "Claude needs your permission to use Bash").
    public let message: String?
    /// Ancestor pids of the hook process, nearest-first. The app activates the closest one that
    /// is a GUI app (the terminal or IDE hosting the session) on click.
    public let hostPids: [Int32]
    /// Executable paths matching `hostPids` — lets the app derive the host's .app bundle even
    /// after the processes exit.
    public let hostPaths: [String]
    /// Controlling terminal device (e.g. "ttys004") — exact-tab focus in iTerm2 / Terminal.
    public let tty: String?
    /// Synthetic preview event (`notch-demo` / the Settings Preview button). Demo cards skip the
    /// host-frontmost suppression — you're usually looking at the very app that spawned them.
    /// Optional so real events omit the key entirely.
    public let demo: Bool?

    public var isDemo: Bool { demo ?? false }

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        kind: Kind,
        startedAt: Date? = nil,
        client: String,
        sessionId: String,
        projectId: String,
        cwd: String? = nil,
        title: String? = nil,
        message: String? = nil,
        hostPids: [Int32] = [],
        hostPaths: [String] = [],
        tty: String? = nil,
        demo: Bool? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.startedAt = startedAt
        self.client = client
        self.sessionId = sessionId
        self.projectId = projectId
        self.cwd = cwd
        self.title = title
        self.message = message
        self.hostPids = hostPids
        self.hostPaths = hostPaths
        self.tty = tty
        self.demo = demo
    }

    /// An attention event that is specifically a permission request (vs. idle waiting) — the
    /// clients phrase both through the same Notification hook, distinguished only by message text.
    public var needsPermission: Bool {
        kind == .attention && (message?.localizedCaseInsensitiveContains("permission") ?? false)
    }
}

/// Cross-process JSONL log of `SessionEvent`s (hooks write, the app watches). Same locking and
/// rotation discipline as `MemoryActivityLog`, with smaller bounds — this is a live feed, not
/// history.
public enum SessionEventLog {
    static let filename = "session-events.jsonl"
    static let maxReadBytes = 256_000
    static let maxFileBytes = 2_000_000
    static let rotationRetainBytes = 256_000

    public static func fileURL(in directory: URL = StoreLocation.supportDirectory) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Create the (empty) log file if missing, so a vnode watcher can attach before the first event.
    public static func touch(in directory: URL = StoreLocation.supportDirectory) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(fileURL(in: directory).path, O_CREAT | O_WRONLY, 0o600)
        if fd >= 0 { close(fd) }
    }

    public static func append(_ event: SessionEvent, in directory: URL = StoreLocation.supportDirectory) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = open(fileURL(in: directory).path, O_CREAT | O_RDWR | O_APPEND, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            guard MemoryActivityLog.acquireLockBriefly(fd: fd) else { return }
            defer { flock(fd, LOCK_UN) }

            MemoryActivityLog.rotateIfNeeded(fd: fd, maxFileBytes: maxFileBytes, retainBytes: rotationRetainBytes)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let line = String(decoding: try encoder.encode(event), as: UTF8.self) + "\n"
            guard let data = line.data(using: .utf8) else { return }
            MemoryActivityLog.writeAll(fd: fd, data: data)
        } catch {
            return
        }
    }

    /// Recent events in append order (the tail window of the log).
    public static func recent(limit: Int = 400, in directory: URL = StoreLocation.supportDirectory) -> [SessionEvent] {
        guard limit > 0,
              let data = MemoryActivityLog.tailData(url: fileURL(in: directory), maxBytes: maxReadBytes),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [SessionEvent] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(SessionEvent.self, from: lineData) else { continue }
            events.append(event)
        }
        return Array(events.suffix(limit))
    }

    /// A short "what this session is about" label: the first real user request in the transcript,
    /// flattened and truncated. Bounded head read — never parses a whole multi-MB transcript.
    public static func quickTitle(transcriptPath: String, maxBytes: Int = 131_072) -> String? {
        let url = URL(fileURLWithPath: (transcriptPath as NSString).expandingTildeInPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        // A hard byte cap often splits mid-JSONL line; drop the truncated tail so the tolerant
        // parser sees only complete records (otherwise the cut line can poison the first user turn).
        if data.count == maxBytes, let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            data = Data(data[..<lastNewline])
        }
        guard !data.isEmpty else { return nil }
        for event in TranscriptParser.parse(jsonl: String(decoding: data, as: UTF8.self))
        where event.role == .user && !event.isSidechain {
            for block in event.textBlocks {
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip tool noise the clients wrap in user turns: XML-ish system reminders /
                // command output, and Claude Code's "Caveat:" preamble.
                guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Caveat:") else { continue }
                return condense(trimmed, limit: 90)
            }
        }
        return nil
    }

    /// Single line, hard-capped — card labels must never wrap or carry transcript formatting.
    public static func condense(_ text: String, limit: Int) -> String {
        let flat = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }
}

/// Synthetic cards for previewing the notch UI on demand (`hypermnesia notch-demo`, or the
/// Preview button in Settings → Notch) — they ride the real pipeline end-to-end: appended to the
/// real log, picked up by the real watcher, reduced and rendered like any hook event, and (when
/// spawned from a terminal) clicking one exercises real jump-back into that terminal.
///
/// Deterministic session ids let `clearEvents` retract them and let a re-run replace instead of
/// stack; event ids stay fresh so a re-run pops again even after a dismissal.
public enum SessionEventDemo {
    static let sessionIds = ["demo-1", "demo-2", "demo-3", "demo-4", "demo-5"]

    public static func events(
        cwd: String = FileManager.default.currentDirectoryPath,
        hostPids: [Int32] = [],
        hostPaths: [String] = [],
        tty: String? = nil,
        now: Date = Date()
    ) -> [SessionEvent] {
        let project = ProjectIdentity.resolve(cwd: cwd)
        func make(_ index: Int, at age: TimeInterval, kind: SessionEvent.Kind, client: String,
                  projectId: String, title: String, message: String? = nil,
                  startedAt: TimeInterval? = nil) -> SessionEvent {
            SessionEvent(
                timestamp: now.addingTimeInterval(-age), kind: kind,
                startedAt: startedAt.map { now.addingTimeInterval(-$0) }, client: client,
                sessionId: sessionIds[index], projectId: projectId, cwd: cwd,
                title: title, message: message,
                hostPids: hostPids, hostPaths: hostPaths, tty: tty, demo: true)
        }
        // One of each flavor (ages staggered but inside the finished TTL so everything renders),
        // plus two live turns so the working strip shows a plural count.
        return [
            make(0, at: 8, kind: .attention, client: "claude", projectId: project,
                 title: "Polish the multi-agent session panel for release",
                 message: "Claude needs your permission to use Bash"),
            make(1, at: 45, kind: .finished, client: "claude", projectId: project,
                 title: "Fix the flaky auth test and re-run CI"),
            make(2, at: 75, kind: .finished, client: "cursor", projectId: "github.com/acme/widgets",
                 title: "Migrate the store to UUID primary keys"),
            make(3, at: 12, kind: .working, client: "claude", projectId: project,
                 title: "Refactor the billing reconciliation job", startedAt: 14 * 60),
            make(4, at: 6, kind: .working, client: "antigravity", projectId: "github.com/acme/api",
                 title: "Write end-to-end tests for the export flow", startedAt: 3 * 60),
        ]
    }

    /// Retraction: an `ended` event per demo session clears its card through the normal reducer path.
    public static func clearEvents(now: Date = Date()) -> [SessionEvent] {
        sessionIds.map {
            SessionEvent(timestamp: now, kind: .ended, client: "claude",
                         sessionId: $0, projectId: "demo", demo: true)
        }
    }
}

/// Reduces the raw event log to the cards the notch should show right now. Pure and clock-driven,
/// so the whole policy is unit-testable: latest event per session wins, `ended` clears, kinds have
/// different lifetimes, attention outranks finished.
public enum SessionEventFeed {
    public struct Card: Sendable, Equatable, Identifiable {
        public let event: SessionEvent
        /// One card per session — a newer event for the session replaces the old card.
        public var id: String { event.sessionId }
        public init(event: SessionEvent) { self.event = event }
    }

    /// A session blocked on the user stays visible until handled or clearly abandoned.
    public static let attentionTTL: TimeInterval = 15 * 60
    /// "Agent finished" is a glanceable pop, not a todo list.
    public static let finishedTTL: TimeInterval = 90
    /// A working session with no news for this long is presumed dead (crashed host, interrupted
    /// turn) — heartbeat hooks refresh the timestamp far more often than this while alive.
    public static let workingTTL: TimeInterval = 15 * 60
    public static let maxCards = 4

    /// Pop cards: sessions that finished or need the user. A newer `working` event swallows the
    /// session's card — the moment an agent resumes (e.g. its permission prompt was answered in
    /// the terminal), a stale "needs your input" card disappears.
    public static func cards(
        events: [SessionEvent],
        dismissedEventIds: Set<String> = [],
        now: Date = Date()
    ) -> [Card] {
        var cards: [Card] = []
        for event in latestPerSession(events) {
            guard event.kind != .ended, event.kind != .working,
                  !dismissedEventIds.contains(event.id) else { continue }
            let age = now.timeIntervalSince(event.timestamp)
            let ttl = event.kind == .attention ? attentionTTL : finishedTTL
            guard age < ttl else { continue }
            cards.append(Card(event: event))
        }
        cards.sort {
            if ($0.event.kind == .attention) != ($1.event.kind == .attention) {
                return $0.event.kind == .attention
            }
            return $0.event.timestamp > $1.event.timestamp
        }
        return Array(cards.prefix(maxCards))
    }

    /// Sessions with a turn in flight right now — the notch's ambient presence strip, not pops.
    /// Ordered longest-running first: heartbeats refresh `timestamp`, so sorting by turn start
    /// keeps rows from shuffling on every beat.
    public static func working(events: [SessionEvent], now: Date = Date()) -> [Card] {
        latestPerSession(events)
            .filter { $0.kind == .working && now.timeIntervalSince($0.timestamp) < workingTTL }
            .sorted { ($0.startedAt ?? $0.timestamp) < ($1.startedAt ?? $1.timestamp) }
            .map(Card.init)
    }

    /// The newest event per session, in first-seen session order. Append order is authoritative;
    /// the timestamp check only guards against a log merged from processes with skewed clocks.
    private static func latestPerSession(_ events: [SessionEvent]) -> [SessionEvent] {
        var latest: [String: SessionEvent] = [:]
        var order: [String] = []
        for event in events {
            if let existing = latest[event.sessionId], existing.timestamp > event.timestamp { continue }
            if latest[event.sessionId] == nil { order.append(event.sessionId) }
            latest[event.sessionId] = event
        }
        return order.compactMap { latest[$0] }
    }
}

/// Capture-time policy for `working` heartbeat hooks (PostToolUse and friends): they fire on every
/// tool call, so appends are throttled, and a heartbeat inherits the turn's start time and title
/// from the log instead of re-deriving them.
public enum SessionEventHeartbeat {
    /// Minimum gap between appended heartbeats for one session.
    public static let minInterval: TimeInterval = 30

    /// True when the log already carries a fresh `working` event for this session — the heartbeat
    /// should skip its append entirely.
    public static func throttled(events: [SessionEvent], sessionId: String, now: Date = Date()) -> Bool {
        guard let last = events.last(where: { $0.sessionId == sessionId && !$0.isDemo }) else { return false }
        return last.kind == .working && now.timeIntervalSince(last.timestamp) < minInterval
    }

    /// What a heartbeat should carry forward: the turn start from the session's live `working`
    /// chain (an attention event in between — an approval pause — doesn't break the chain), and
    /// the last known title. A dead chain (older than `workingTTL`) means this beat begins a
    /// fresh turn.
    public static func inheritance(
        events: [SessionEvent], sessionId: String, now: Date = Date()
    ) -> (startedAt: Date?, title: String?) {
        let title = events.last(where: { $0.sessionId == sessionId && !$0.isDemo && $0.title != nil })?.title
        guard let lastWorking = events.last(where: { $0.sessionId == sessionId && $0.kind == .working && !$0.isDemo }),
              now.timeIntervalSince(lastWorking.timestamp) < SessionEventFeed.workingTTL else {
            return (nil, title)
        }
        return (lastWorking.startedAt ?? lastWorking.timestamp, title)
    }
}
