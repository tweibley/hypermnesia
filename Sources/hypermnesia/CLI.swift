import ArgumentParser
import Foundation
import HypermnesiaKit

/// Reject an unknown `--classifier` value instead of silently coercing it to the default (which would
/// run a classifier the user didn't ask for).
func validateClassifierFlag(_ raw: String?) throws {
    if let raw, Classifiers.Kind(rawValue: raw) == nil {
        throw ValidationError("Unknown --classifier '\(raw)'. Use one of: auto | gemini | claude.")
    }
}

/// `hypermnesia` — the headless CLI the Claude Code hooks call.
///
/// The hooks must return fast, so these subcommands do only cheap local work:
/// `capture` enqueues a transcript for out-of-band classification, `hydrate` reads the local
/// store and prints `additionalContext`, and `drain` classifies the queued sessions.
@main
struct HypermnesiaCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hypermnesia",
        abstract: "Local-first memory for Claude Code.",
        discussion: """
        First-time setup for a Claude Code project: `install-hooks` (capture + inject), then
        optionally `install-memory-guide` (MCP pull path). `doctor` checks the installation.
        """,
        version: Hypermnesia.version,
        groupedSubcommands: [
            CommandGroup(name: "Memories", subcommands: [
                List.self, Show.self, Delete.self, Export.self, ImportClaudeMd.self,
                Ask.self, Recall.self, Audit.self, Dream.self,
            ]),
            CommandGroup(name: "Capture", subcommands: [
                Backfill.self, Drain.self, Hydrate.self, Capture.self, SessionEventHook.self, MCP.self,
            ]),
            CommandGroup(name: "Setup", subcommands: [
                Setup.self, Doctor.self, InstallHooks.self, InstallMCP.self,
                InstallCursorHooks.self, InstallCursorMCP.self,
                InstallAntigravityHooks.self, InstallAntigravityMCP.self,
                InstallMemoryGuide.self, AllowTools.self,
            ]),
            CommandGroup(name: "Development", subcommands: [
                Inspect.self, Classify.self, Seed.self, SeedMemories.self, NotchDemo.self,
            ]),
        ]
    )
}

/// `hypermnesia seed-memories --file <json> --project <id>` — deterministically load a JSON array
/// of memories into the store under a fixed project id, with explicit confidence/status. Built for
/// the eval harness (and tests): it lets a benchmark pre-populate a clean, isolated store
/// (see `HYPERMNESIA_SUPPORT_DIR`) without going through the classifier.
struct SeedMemories: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seed-memories",
        abstract: "Load a JSON array of memories into the store under a fixed project id (for evals/tests)."
    )

    @Option(name: .long, help: "Path to a JSON array of {type,title,summary,confidence?,status?} objects.")
    var file: String

    @Option(name: .long, help: "Project id to store the memories under (used verbatim).")
    var project: String

    @Flag(name: .long, help: "Print what would be stored without writing.")
    var dryRun = false

    struct Spec: Decodable {
        let type: String
        let title: String
        let summary: String
        let confidence: Double?
        let status: String?
        let category: String?   // facts only; defaults to "state"
        let severity: String?   // concerns only; defaults to "medium"
        let appliesWhen: String?  // conventions + concerns: scope of applicability
        let excludesWhen: String? // conventions + concerns: adjacent cases to exclude
        // Evidence fields (for belief-model eval fixtures). When `belief` is set, the stored confidence
        // is COMPUTED as belief × freshness × outcome factors (what injection actually sees) rather than
        // taken from `confidence`. Omit them for a plain age-only seed.
        let belief: Double?
        let timesSighted: Int?
        let timesAppliedSuccess: Int?
        let timesOverridden: Int?
        let ageDays: Int?         // days since validation → freshness anchor (default 0 = fresh)
    }

    func run() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let specs = try JSONDecoder().decode([Spec].self, from: Data(contentsOf: url))

        var nodes: [MemoryNode] = []
        for spec in specs {
            guard let type = MemoryType(rawValue: spec.type) else {
                FileHandle.standardError.write(Data("Skipping unknown type '\(spec.type)'\n".utf8))
                continue
            }
            let data: MemoryData
            switch type {
            case .decision:   data = .decision(.init(chosen: spec.summary))
            case .convention: data = .convention(.init(rule: spec.summary, appliesWhen: spec.appliesWhen, excludesWhen: spec.excludesWhen))
            case .intent:     data = .intent(.init(goal: spec.summary))
            case .fact:       data = .fact(.init(category: spec.category ?? "state", key: spec.title, value: spec.summary))
            case .concern:    data = .concern(.init(issue: spec.summary, severity: spec.severity ?? "medium", appliesWhen: spec.appliesWhen, excludesWhen: spec.excludesWhen))
            case .backlog:    data = .backlog(.init(idea: spec.summary, priority: "medium"))
            case .codeRef:    data = .codeRef(.init(filePath: spec.summary))
            }
            let status = MemoryStatus(rawValue: spec.status ?? "confirmed") ?? .confirmed
            let anchor = Date().addingTimeInterval(-Double(spec.ageDays ?? 0) * 86_400)
            var node = MemoryNode(
                projectId: project, type: type, status: status,
                title: spec.title, summary: spec.summary, data: data,
                confidence: spec.confidence ?? 1.0,
                belief: spec.belief,
                createdAt: anchor, updatedAt: anchor,
                lastValidatedAt: spec.belief != nil ? anchor : nil,
                timesOverridden: spec.timesOverridden ?? 0,
                timesSighted: spec.timesSighted ?? 0,
                timesAppliedSuccess: spec.timesAppliedSuccess ?? 0
            )
            // Belief-model seed: store the confidence injection will actually see (belief × freshness ×
            // outcome factors). Plain seeds (belief omitted) keep the given confidence, age-only behavior.
            // Non-decaying types (fact/concern/backlog/codeRef) don't run the belief×freshness model, so
            // set confidence straight from belief — otherwise a seeded low-belief fact stays at 1.0.
            if let belief = spec.belief {
                node.confidence = node.type.decaysWithTime
                    ? DecayEngine.decayed(node).confidence
                    : min(1.0, max(0.01, belief))
            }
            nodes.append(node)
        }

        if dryRun {
            print("Would store \(nodes.count) memories under \(project):")
            for n in nodes { print("  [\(n.type.rawValue)] \(n.title) (conf \(String(format: "%.2f", n.confidence)), \(n.status.rawValue))") }
            return
        }
        let store = try MemoryStore()
        try store.upsert(nodes)
        print("Seeded \(nodes.count) memories under \(project).")
    }
}

/// `hypermnesia mcp` — run a Model Context Protocol server (stdio) so any MCP client can use the
/// memory. Reads/writes newline-delimited JSON-RPC; never writes anything else to stdout.
struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run an MCP server exposing memory recall/ask/remember to any MCP client."
    )

    /// Serializes stdout writes so concurrently-handled requests never interleave their JSON-RPC
    /// lines on the wire. JSON-RPC ids let responses come back out of order, so this is safe.
    private actor Emitter {
        func emit(_ out: Data) {
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data([0x0A]))   // newline delimiter
        }
    }

    func run() async throws {
        setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: every response flushes immediately
        let handler = MCPHandler(store: try MemoryStore())
        let emitter = Emitter()
        // Handle each request in its own task so a slow call (e.g. `ask`, which can spend up to
        // ~120s in a `claude -p` subprocess) doesn't head-of-line block every other tool call.
        // The read loop keeps draining stdin while in-flight requests run; the task group awaits
        // all handlers before returning when stdin closes. GRDB's DatabaseQueue serializes the
        // underlying store access, so concurrent `handle` calls are safe.
        await withTaskGroup(of: Void.self) { group in
            while let line = readLine(strippingNewline: true) {
                group.addTask {
                    guard let data = line.data(using: .utf8), !data.isEmpty,
                          let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    else { return }
                    guard let response = await handler.handle(message),
                          let out = try? JSONSerialization.data(withJSONObject: response)
                    else { return }
                    await emitter.emit(out)
                }
            }
        }
    }
}

/// `hypermnesia audit --project <path>` — reality-check memories against the current code.
struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Flag memories whose related files are missing or changed since capture."
    )

    @Option(name: .long, help: "Repository path to check against (defaults to the current directory).")
    var project: String?

    @Flag(name: .long, help: "Also ask the model whether each memory still holds (slower; costs calls).")
    var deep = false

    @Flag(name: .long, help: "Penalize flagged memories' confidence so they surface in Health.")
    var apply = false

    func run() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let repoPath = (project as NSString?)?.expandingTildeInPath ?? FileManager.default.currentDirectoryPath
        let projectId = ProjectIdentity.resolve(cwd: repoPath)
        let store = try MemoryStore()

        var findings = MemoryAuditor.audit(store: store, projectId: projectId, repoPath: repoPath)
        if deep {
            FileHandle.standardError.write(Data("Verifying with \(Classifiers.autoDescription)…\n".utf8))
            findings += await MemoryAuditor.verify(
                store: store, projectId: projectId, repoPath: repoPath, completer: Completers.makeFromConfig()
            )
        }

        if findings.isEmpty {
            print("No issues — memories look consistent with the current code.")
            return
        }
        print("Found \(findings.count) issue(s) across \(Set(findings.map(\.nodeId)).count) memories:")
        for finding in findings {
            print("  [\(finding.issue.rawValue)] \(finding.title) — \(finding.detail)")
        }
        if apply {
            let affected = MemoryAuditor.apply(findings, store: store)
            // Also fold the file-presence reality-check into the belief model: corroborate memories
            // whose files are all present/unchanged, flag drift on the rest. Runs after apply so the
            // evidence-based recompute is the final word for file-backed memories; idempotent, so
            // re-running an unchanged audit doesn't compound.
            let outcomes = MemoryAuditor.recordOutcomes(findings, store: store, projectId: projectId)
            print("\nLowered confidence on \(affected) memories (review them in Health / revalidate to restore).")
            if outcomes.corroborated + outcomes.drifted > 0 {
                print("Belief evidence: \(outcomes.corroborated) corroborated, \(outcomes.drifted) drifted.")
            }
        } else {
            print("\nRe-run with --apply to flag these for review.")
        }
    }
}

/// `hypermnesia ask "question" [--project P]` — natural-language query over a project's memories.
struct Ask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Ask a natural-language question about a project's memories."
    )

    @Argument(help: "The question to ask.")
    var question: String

    @Option(name: .long, help: "Repository path (defaults to the current directory).")
    var project: String?

    func run() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let cwd = (project as NSString?)?.expandingTildeInPath ?? FileManager.default.currentDirectoryPath
        let projectId = ProjectIdentity.resolve(cwd: cwd)
        let store = try MemoryStore()
        FileHandle.standardError.write(Data("Asking via \(Classifiers.autoDescription)…\n".utf8))

        let result = try await MemoryQA.ask(
            question, store: store, projectId: projectId,
            completer: Completers.makeFromConfig(), embedder: AppleEmbedder()
        )
        print(result.answer)
        if !result.sources.isEmpty {
            print("\nSources:")
            for source in result.sources.prefix(6) {
                print("  • [\(source.type.rawValue)] \(source.title)")
            }
        }
    }
}

/// `hypermnesia dream [--project P] [--days N]` — run one project's Memory Dream right now.
/// The manual override: no idle/power/cap gating, and tonight's journal slot is replaced.
struct Dream: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Consolidate recent sessions and memory into tonight's dream (epiphanies, drafts, skill proposals)."
    )

    @Option(name: .long, help: "Repository path (defaults to the current directory).")
    var project: String?

    @Option(name: .long, help: "Override the lookback window in days.")
    var days: Int?

    func run() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let cwd = (project as NSString?)?.expandingTildeInPath ?? FileManager.default.currentDirectoryPath
        let projectId = ProjectIdentity.resolve(cwd: cwd)
        let store = try MemoryStore()
        var config = AppConfigStore.loadBestEffort()
        if let days { config.dreamLookbackDays = max(1, days) }
        FileHandle.standardError.write(Data("Dreaming with \(DreamCompleters.label(config))…\n".utf8))

        let result = await DreamService.dreamProject(projectId: projectId, store: store, appConfig: config)
        if let reason = result.skippedReason {
            print("Skipped: \(reason)")
            return
        }
        guard let entry = result.entry else {
            print("Dream did not complete.")
            throw ExitCode.failure
        }

        switch entry.outcome {
        case .quiet:
            print("Quiet night — nothing cleared the quality gate.")
            if let note = entry.payload.note { print("  \(note)") }
        case .dreamed:
            if let narrative = entry.narrative { print(narrative + "\n") }
            for epiphany in entry.payload.epiphanies {
                print("• [\(epiphany.kind.rawValue)] \(epiphany.title) — \(epiphany.insight)")
                for quote in epiphany.quotes.prefix(2) {
                    print("    “\(quote.text)” (session \(quote.sessionId.prefix(8)))")
                }
            }
            let drafts = entry.payload.proposedMemoryIds.count
            if drafts > 0 {
                print("\nProposed \(drafts) draft memor\(drafts == 1 ? "y" : "ies") — review them in the inbox.")
            }
            for skill in entry.payload.skillProposals {
                print("Proposed skill: \(skill.slug)\(skill.updatesExisting ? " (update)" : "") — install it from the app's Dream Journal.")
            }
        }
        for back in entry.payload.reportBacks { print("↩ \(back.detail)") }

        let stats = entry.payload.stats
        let cost = stats.estCostUSD.map { String(format: "~$%.3f", $0) } ?? "n/a"
        print("\n\(stats.sessionsScanned) session\(stats.sessionsScanned == 1 ? "" : "s") · "
            + "\(stats.memoriesConsidered) memories · \(stats.calls) call (\(stats.classifier), \(cost))")
    }
}

// MARK: - Hook helpers

/// Read and parse the JSON a hook delivers on stdin.
enum HookIO {
    static func readInput() -> [String: Any] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    /// Reads the new env name with the pre-rename variable as a fallback, so anything still
    /// exporting the old name (scripts, the classifier guard in old hook configs) keeps working.
    private static func envFlag(_ name: String, legacy: String) -> Bool {
        let env = ProcessInfo.processInfo.environment
        return !((env[name] ?? env[legacy] ?? "").isEmpty)
    }

    static var isDisabled: Bool {
        envFlag("HYPERMNESIA_DISABLE", legacy: "HYPERTHYMESIA_DISABLE")
    }

    /// Verbose hook tracing — set `HYPERMNESIA_DEBUG` to see per-run "what happened" lines.
    static var isVerbose: Bool {
        envFlag("HYPERMNESIA_DEBUG", legacy: "HYPERTHYMESIA_DEBUG")
    }

    /// Emit a diagnostic to **stderr** — never stdout, which is the hook's structured-output channel.
    /// Used for anomalies a support engineer needs to see (e.g. a hook firing with required fields
    /// absent), which otherwise look identical to a healthy "nothing to capture" run.
    static func note(_ message: String) {
        FileHandle.standardError.write(Data("hypermnesia: \(message)\n".utf8))
    }

    /// Like `note`, but only when `HYPERMNESIA_DEBUG` is set — keeps healthy runs silent.
    static func debug(_ message: @autoclosure () -> String) {
        if isVerbose { note(message()) }
    }
}

/// `HookClient` / `HookContext` live in HypermnesiaKit (reusable + unit-testable); the CLI only
/// adds the ArgumentParser conformance so `--client` accepts `claude` | `cursor` | `antigravity`
/// (with `agy` as a shorthand).
extension HookClient: ExpressibleByArgument {
    public init?(argument: String) {
        if argument.lowercased() == "agy" { self = .antigravity; return }
        self.init(rawValue: argument)
    }
}

/// `hypermnesia hydrate` — a SessionStart/UserPromptSubmit hook. Reads the hook JSON, looks up the
/// project's memories, and prints `additionalContext` so Claude starts with prior project knowledge.
struct Hydrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Hook: inject relevant project memories into a Claude Code, Cursor, or Antigravity session."
    )

    @Option(name: .long, help: "Agent client whose hook schema to use: claude | cursor | antigravity (default: claude).")
    var client: HookClient = .claude

    func run() async throws {
        // Antigravity parses hook stdout as JSON, so every exit path must end in a valid object —
        // an empty `{}` when there is nothing to inject.
        var wroteOutput = false
        defer {
            if client == .antigravity, !wroteOutput {
                FileHandle.standardOutput.write(Data("{}".utf8))
            }
        }
        // Never hydrate the classifier's own sessions, and never break the user's session on error.
        guard !HookIO.isDisabled else { return }
        let startedAt = Date()
        let ctx = HookContext.parse(HookIO.readInput(), client: client)
        // Antigravity's PreInvocation fires before *every* model call; only the first call of a
        // fresh conversation (normalized to SessionStart) hydrates — later invocations stay silent
        // so the digest is never re-injected mid-session.
        if client == .antigravity, ctx.event != "SessionStart" {
            HookIO.debug("hydrate (antigravity) \(ctx.event): mid-session invocation — nothing to inject")
            return
        }
        let missing = ctx.missingForHydrate(client: client)
        guard missing.isEmpty, let cwd = ctx.cwd else {
            HookIO.note("hydrate (\(client.rawValue)) skipped — missing \(missing.joined(separator: ", "))")
            return
        }
        let sessionId = ctx.sessionId
        let event = ctx.event

        guard let store = try? MemoryStore() else {
            HookIO.note("hydrate (\(client.rawValue)) skipped — could not open the memory store")
            return
        }
        let projectId = ProjectIdentity.resolve(cwd: cwd)

        // SessionStart → full project context; UserPromptSubmit → memories relevant to this prompt.
        // (Cursor has no per-prompt context hook, so it only ever takes the SessionStart branch.)
        let config = AppConfigStore.loadBestEffort()
        let result: MemoryHydrator.ContextResult?
        if event == "UserPromptSubmit" {
            guard config.injectPerPrompt, let prompt = ctx.prompt else { return }
            result = MemoryHydrator.relevantContextResult(store: store, projectId: projectId, query: prompt, embedder: AppleEmbedder())
        } else if config.injectAtSessionStart {
            var options = MemoryHydrator.Options()
            options.maxItems = config.maxMemoriesInjected
            result = MemoryHydrator.contextResult(store: store, projectId: projectId, options: options)
        } else {
            result = nil   // memory injection off — momentum below may still have something to say
        }
        // Momentum rides ahead of memory at SessionStart: "what was I doing?" before "why is the
        // codebase like this?". Never injected per-prompt, and never a session's own snapshot
        // (a resumed session already has that context).
        var momentumBlock: String?
        if event != "UserPromptSubmit", config.injectMomentum,
           let snapshot = Momentum.load(projectId: projectId), snapshot.sessionId != sessionId {
            momentumBlock = Momentum.render(snapshot)
        }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard result != nil || momentumBlock != nil else {
            MemoryActivityLog.append(.init(
                projectId: projectId,
                sessionId: sessionId,
                eventType: .hydrate,
                memoryIds: [],
                count: 0,
                latencyMs: elapsedMs,
                metadata: ["hookEvent": event, "empty": "true", "client": client.rawValue]
            ))
            HookIO.debug("hydrate (\(client.rawValue)) \(event): no memories to inject for \(projectId)")
            return
        }

        let combined = [momentumBlock, result?.context].compactMap { $0 }.joined(separator: "\n\n")
        if let data = try? JSONSerialization.data(withJSONObject: hydrationOutput(event: event, context: combined)) {
            FileHandle.standardOutput.write(data)
            wroteOutput = true
        }
        let memories = result?.memories ?? []
        HookIO.debug("hydrate (\(client.rawValue)) \(event): injected \(memories.count) memories"
            + (momentumBlock != nil ? " + momentum" : "") + " for \(projectId)")
        MemoryActivityLog.append(.init(
            projectId: projectId,
            sessionId: sessionId,
            eventType: .hydrate,
            memoryIds: memories.map(\.id),
            count: memories.count,
            latencyMs: elapsedMs,
            metadata: ["hookEvent": event, "client": client.rawValue,
                       "momentum": momentumBlock != nil ? "true" : "false"]
        ))
    }

    /// The injection payload each client expects: Claude reads `hookSpecificOutput.additionalContext`;
    /// Cursor reads a top-level `additional_context`; Antigravity's PreInvocation hook injects
    /// trajectory steps — an `ephemeralMessage` (a transient system message) carries the context.
    private func hydrationOutput(event: String, context: String) -> [String: Any] {
        switch client {
        case .claude:
            return ["hookSpecificOutput": ["hookEventName": event, "additionalContext": context]]
        case .cursor:
            return ["additional_context": context]
        case .antigravity:
            return ["injectSteps": [["ephemeralMessage": context]]]
        }
    }
}

/// `hypermnesia capture` — a SessionEnd hook. Enqueues the finished session for out-of-band
/// classification (fast; the actual work happens in `drain`).
struct Capture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Hook: enqueue a finished Claude Code, Cursor, or Antigravity session for memory capture."
    )

    @Option(name: .long, help: "Agent client whose hook schema to use: claude | cursor | antigravity (default: claude).")
    var client: HookClient = .claude

    func run() async throws {
        // Antigravity's Stop hook requires a JSON `decision` on stdout; anything but "continue"
        // lets the agent stop, so an empty decision is the "capture never blocks a stop" answer.
        // Emitted on every exit path.
        defer {
            if client == .antigravity {
                FileHandle.standardOutput.write(Data(#"{"decision":""}"#.utf8))
            }
        }
        guard !HookIO.isDisabled else { return }
        let ctx = HookContext.parse(HookIO.readInput(), client: client)
        let missing = ctx.missingForCapture(client: client)
        guard missing.isEmpty, let sessionId = ctx.sessionId, let transcript = ctx.transcriptPath, let cwd = ctx.cwd else {
            HookIO.note("capture (\(client.rawValue)) skipped — missing \(missing.joined(separator: ", "))")
            return
        }
        guard let store = try? MemoryStore() else {
            HookIO.note("capture (\(client.rawValue)) skipped — could not open the memory store")
            return
        }

        // Already fully captured (e.g. backfilled)? Nothing to do.
        if (try? store.isProcessed(sessionId: sessionId)) == true {
            HookIO.debug("capture (\(client.rawValue)): \(sessionId.prefix(8)) already processed — skipping")
            return
        }

        // An empty session: Claude Code only writes `<sessionId>.jsonl` once the first prompt is
        // sent, so a session ending with no transcript on disk (and no cursor from an earlier
        // live slice) was opened and closed without the user ever saying anything — e.g. the
        // desktop app restoring a tab. There is nothing to capture and no retry can ever help;
        // enqueueing would only surface a confusing "failed" row in the queue health banner.
        // Scoped to Claude Code: Cursor's transcript lives at a computed export path whose absence
        // can also mean transcript export is disabled, which deserves the retry + note below.
        if client == .claude,
           !FileManager.default.fileExists(atPath: transcript),
           ((try? store.cursor(sessionId: sessionId)) ?? 0) == 0 {
            HookIO.debug("capture (claude) \(ctx.event): \(sessionId.prefix(8)) has no transcript — "
                + "empty session, skipping")
            return
        }

        // The host may delete its transcript as soon as this hook returns. Snapshot it before
        // enqueueing so the out-of-band drain never races a host-owned temporary file. If the
        // snapshot fails (disk full, source already gone), still enqueue the host path — a later
        // Stop/SessionEnd or drain retry may recover it; dropping the session silently is worse.
        let hostTranscript = URL(fileURLWithPath: transcript)
        let queuedTranscript: URL
        do {
            queuedTranscript = try TranscriptSnapshotStore.snapshot(
                transcript: hostTranscript,
                sessionId: sessionId
            )
        } catch {
            HookIO.note("capture (\(client.rawValue)): snapshot failed at \(transcript) — "
                + "enqueueing host path for retry: \(error.localizedDescription)"
                + (client == .cursor ? " — enable transcript export in Cursor" : ""))
            queuedTranscript = hostTranscript
        }

        // SessionEnd is the final flush; Stop is an in-session checkpoint.
        let projectId = ProjectIdentity.resolve(cwd: cwd)
        do {
            try store.enqueueOrUpdate(
                sessionId: sessionId, projectId: projectId, transcriptPath: queuedTranscript.path, cwd: cwd,
                gitSha: ProjectIdentity.headSha(cwd: cwd),
                gitBranch: ProjectIdentity.currentBranch(cwd: cwd),
                isFinal: ctx.isFinal
            )
        } catch {
            HookIO.note("capture (\(client.rawValue)) skipped — could not enqueue transcript snapshot: "
                + error.localizedDescription)
            return
        }
        HookIO.debug("capture (\(client.rawValue)) \(ctx.event): enqueued \(sessionId.prefix(8)) for \(projectId)"
            + (ctx.isFinal ? " (final)" : ""))

        // Session momentum: the final flush also snapshots where the session left off, so the
        // NEXT session can pick up the thread. Trivial sessions leave no snapshot.
        if ctx.isFinal, AppConfigStore.loadBestEffort().injectMomentum {
            Momentum.recordDeparture(
                transcriptURL: queuedTranscript,
                projectId: projectId, sessionId: sessionId)
        }
    }
}

/// `hypermnesia session-event` — a status hook (Stop / SessionEnd / Notification /
/// UserPromptSubmit / per-tool heartbeats). Appends a live status event (working · agent finished
/// · needs attention · session ended) to the session-event log the app's notch status display
/// watches. Cheap and local: no store, no classifier, a bounded transcript head-read for the card
/// label; heartbeat appends are throttled to one per session per 30s.
struct SessionEventHook: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-event",
        abstract: "Hook: record a live session status event for the notch status display."
    )

    @Option(name: .long, help: "Agent client whose hook schema to use: claude | cursor | antigravity (default: claude).")
    var client: HookClient = .claude

    func run() async throws {
        let input = HookIO.readInput()
        let ctx = HookContext.parse(input, client: client)
        // Some hosts treat hook stdout as a protocol, so every exit path answers: Antigravity
        // parses stdout as JSON on all its hooks (an empty decision never blocks a Stop and is a
        // no-op elsewhere); Cursor's beforeSubmitPrompt must reply `{"continue": true}` or the
        // user's prompt could be held. Claude paths stay silent — UserPromptSubmit stdout would
        // be injected into the model's context.
        defer {
            if client == .antigravity {
                FileHandle.standardOutput.write(Data(#"{"decision":""}"#.utf8))
            } else if client == .cursor, ctx.event == "UserPromptSubmit" {
                FileHandle.standardOutput.write(Data(#"{"continue":true}"#.utf8))
            }
        }
        guard !HookIO.isDisabled else { return }
        // The master switch lives in app config so turning the feature off also stops the writes.
        guard AppConfigStore.loadBestEffort().notchEnabled else { return }

        var kind: SessionEvent.Kind?
        var isHeartbeat = false
        switch ctx.event {
        case "Notification": kind = .attention
        case "Stop": kind = .finished
        // Antigravity's "SessionEnd" means the agent went fully idle — that's a finish, not a
        // closed window (conversations have no close signal there).
        case "SessionEnd": kind = client == .antigravity ? .finished : .ended
        // A submitted prompt starts a turn (Cursor's beforeSubmitPrompt normalizes to this).
        case "UserPromptSubmit": kind = .working
        // Antigravity's conversation start IS its first model call — a turn is beginning. For
        // other clients SessionStart just means a window opened; nothing is running yet.
        case "SessionStart": kind = client == .antigravity ? .working : nil
        // Per-tool hooks: heartbeats proving the turn is still alive (and, right after a
        // permission prompt is approved in the host, the signal that clears its attention card).
        case "PostToolUse", "PreInvocation", "afterFileEdit", "afterShellExecution":
            kind = .working
            isHeartbeat = true
        default: kind = nil
        }
        // A Cursor stop the user aborted isn't a "come look" moment — clear the session's cards
        // silently rather than popping "finished" at the person who just pressed stop.
        if client == .cursor, ctx.event == "Stop", (input["status"] as? String) == "aborted" {
            kind = .ended
        }
        guard let kind else {
            HookIO.debug("session-event (\(client.rawValue)) \(ctx.event): not a status event — skipping")
            return
        }
        guard let sessionId = ctx.sessionId, !sessionId.isEmpty, let cwd = ctx.cwd, !cwd.isEmpty else {
            HookIO.note("session-event (\(client.rawValue)) \(ctx.event) skipped — missing session id or cwd")
            return
        }

        var startedAt: Date?
        var title: String?
        if kind == .working {
            startedAt = Date()
            title = ctx.prompt.flatMap { $0.isEmpty ? nil : SessionEventLog.condense($0, limit: 90) }
            if isHeartbeat {
                let recent = SessionEventLog.recent()
                if SessionEventHeartbeat.throttled(events: recent, sessionId: sessionId) {
                    HookIO.debug("session-event (\(client.rawValue)) \(ctx.event): heartbeat throttled")
                    return
                }
                let inherited = SessionEventHeartbeat.inheritance(events: recent, sessionId: sessionId)
                startedAt = inherited.startedAt ?? startedAt
                title = title ?? inherited.title
            }
        }
        if title == nil, kind != .ended {
            title = ctx.transcriptPath.flatMap { SessionEventLog.quickTitle(transcriptPath: $0) }
        }
        let ancestors = ProcessAncestry.chain()
        SessionEventLog.append(SessionEvent(
            kind: kind,
            startedAt: startedAt,
            client: client.rawValue,
            sessionId: sessionId,
            projectId: ProjectIdentity.resolve(cwd: cwd),
            cwd: cwd,
            title: title,
            message: input["message"] as? String,
            hostPids: ancestors.map(\.pid),
            hostPaths: ancestors.map(\.path),
            tty: ProcessAncestry.controllingTerminal()
        ))
        HookIO.debug("session-event (\(client.rawValue)) \(ctx.event): \(kind.rawValue) for \(sessionId.prefix(8))")
    }
}

/// `hypermnesia drain` — classify any queued sessions into memories. Run by the SessionEnd hook
/// (backgrounded), the menu-bar app on a timer, or manually.
struct Drain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Classify queued sessions into memories."
    )

    @Option(name: .long, help: "Classifier: auto | gemini | claude (default: from app settings).")
    var classifier: String?

    @Option(name: .long, help: "Model override.")
    var model: String?

    @Flag(name: .long, help: "List the queued sessions without classifying anything.")
    var dryRun = false

    @Option(name: .long, help: "Process at most N queued sessions this pass.")
    var limit: Int = 100

    @Flag(name: .customLong("hook-background"),
          help: "Redirect output to the private bounded hook diagnostic log.")
    var hookBackground = false

    @Flag(name: .long, help: "Delete terminal queue failures without deleting memories or source transcripts.")
    var clearFailed = false

    func run() async throws {
        if hookBackground {
            try HookDrainDiagnostics.redirectStandardStreams()
            print("\n[\(Date().ISO8601Format())] background drain")
        }
        try validateClassifierFlag(classifier)
        guard limit > 0 else { throw ValidationError("--limit must be positive.") }
        guard !(dryRun && clearFailed) else {
            throw ValidationError("--dry-run and --clear-failed cannot be used together.")
        }
        setvbuf(stdout, nil, _IONBF, 0)
        let store = try MemoryStore()
        if clearFailed {
            let removed = try store.clearFailedCaptures()
            print("Cleared \(removed) failed capture\(removed == 1 ? "" : "s").")
            return
        }
        if dryRun {
            let queued = (try? store.pendingCaptures(limit: limit)) ?? []
            guard !queued.isEmpty else { print("Queue is empty."); return }
            print("Would classify \(queued.count) session(s):")
            for item in queued {
                print("  \(item.sessionId.prefix(8))  \(item.projectId)  attempts=\(item.attempts)\(item.isFinal ? "  final" : "")")
            }
            return
        }
        let engine = Classifiers.forCLI(classifier: classifier, model: model)
        let pending = (try? store.pendingCaptures(limit: limit))?.count ?? 0
        if pending > 0 { print("Draining \(pending) session(s) via \(Classifiers.cliDescription(classifier: classifier))…") }
        let report = await SessionIngestor.drainQueue(store: store, classifier: engine, limit: limit)
        print(report.added > 0 ? "Done. \(report.added) new memories." : "Nothing to do.")
        if report.failures > 0 {
            FileHandle.standardError.write(Data(
                "\(report.failures) session(s) failed to classify and will be retried; check your classifier configuration (`hypermnesia doctor`).\n".utf8))
            throw ExitCode.failure
        }
    }
}

/// `hypermnesia install-hooks` — register the capture + hydrate hooks in Claude Code settings.
struct InstallHooks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install Hypermnesia's capture + hydrate hooks into Claude Code settings."
    )

    @Option(name: .long, help: "Install into a project's .claude/settings.json instead of user settings.")
    var project: String?

    @Flag(name: .long, help: "Remove the Hypermnesia hooks instead of installing them.")
    var uninstall = false

    @Flag(name: .long, help: "Print the hook config without writing it.")
    var dryRun = false

    func run() async throws {
        let url = HookInstaller.settingsURL(projectPath: project)
        if uninstall {
            if dryRun { print("(dry run) would remove Hypermnesia hooks from \(url.path)"); return }
            try HookInstaller.uninstall(projectPath: project)
            print("Removed Hypermnesia hooks from \(url.path)")
            return
        }
        if dryRun {
            let existing = try ConfigFile.readObject(at: url)
            let merged = HookInstaller.merged(into: existing, binaryPath: Self.selfPath)
            let json = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: json, as: UTF8.self))
            print("\n(dry run — not written to \(url.path))")
            return
        }
        try HookInstaller.install(binaryPath: Self.selfPath, projectPath: project)
        print("Installed hooks into \(url.path)")
        print("  SessionStart / UserPromptSubmit → hydrate (inject memories as the session runs)")
        print("  Stop / SessionEnd               → capture + drain (build memory as the session runs)")
        print("  UserPromptSubmit / PostToolUse / Stop / Notification")
        print("                                  → session-event (live working/finished status for the app's notch display)")
        print("\nNew Claude Code sessions will now build and use memory continuously.")
    }

    static var selfPath: String {
        let arg0 = CommandLine.arguments.first ?? "hypermnesia"
        if arg0.contains("/") {
            return URL(fileURLWithPath: arg0).standardizedFileURL.path
        }
        return arg0 // on PATH
    }
}

/// `hypermnesia install-cursor-hooks` — register the capture + hydrate hooks in Cursor's
/// `hooks.json`, the Cursor analogue of `install-hooks`.
struct InstallCursorHooks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-cursor-hooks",
        abstract: "Install Hypermnesia's capture + hydrate hooks into Cursor (~/.cursor/hooks.json)."
    )

    @Option(name: .long, help: "Install into a project's .cursor/hooks.json instead of user settings.")
    var project: String?

    @Flag(name: .long, help: "Remove the Hypermnesia Cursor hooks instead of installing them.")
    var uninstall = false

    @Flag(name: .long, help: "Print the hook config without writing it.")
    var dryRun = false

    func run() async throws {
        let url = CursorHookInstaller.settingsURL(projectPath: project)
        if uninstall {
            if dryRun { print("(dry run) would remove Hypermnesia Cursor hooks from \(url.path)"); return }
            try CursorHookInstaller.uninstall(projectPath: project)
            print("Removed Hypermnesia Cursor hooks from \(url.path)")
            return
        }
        if dryRun {
            let existing = try ConfigFile.readObject(at: url)
            let merged = CursorHookInstaller.merged(into: existing, binaryPath: InstallHooks.selfPath)
            let json = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: json, as: UTF8.self))
            print("\n(dry run — not written to \(url.path))")
            return
        }
        try CursorHookInstaller.install(binaryPath: InstallHooks.selfPath, projectPath: project)
        print("Installed Cursor hooks into \(url.path)")
        print("  sessionStart       → hydrate (inject memories when a Cursor session starts)")
        print("  stop / sessionEnd  → capture + drain (build memory as the session runs)")
        print("  beforeSubmitPrompt / afterFileEdit / afterShellExecution")
        print("                     → session-event (live working/finished status for the app's notch display)")
        print("\nNew Cursor agent sessions will now build and use memory.")
        print("(If capture finds nothing, enable transcript export in Cursor so a transcript_path is provided.)")
    }
}

/// `hypermnesia install-cursor-mcp` — register the stdio MCP server in Cursor's `mcp.json` so
/// Cursor can call recall / ask / remember. The Cursor analogue of `claude mcp add`.
struct InstallCursorMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-cursor-mcp",
        abstract: "Register the hypermnesia MCP server in Cursor (~/.cursor/mcp.json)."
    )

    @Option(name: .long, help: "Install into a project's .cursor/mcp.json instead of user settings.")
    var project: String?

    @Flag(name: .long, help: "Remove the hypermnesia MCP server entry instead of adding it.")
    var uninstall = false

    @Flag(name: .long, help: "Print the mcp.json config without writing it.")
    var dryRun = false

    func run() async throws {
        let url = CursorMCPInstaller.configURL(projectPath: project)
        if uninstall {
            if dryRun { print("(dry run) would remove hypermnesia MCP server from \(url.path)"); return }
            try CursorMCPInstaller.uninstall(projectPath: project)
            print("Removed hypermnesia MCP server from \(url.path)")
            return
        }
        if dryRun {
            let existing = try ConfigFile.readObject(at: url)
            let merged = CursorMCPInstaller.merged(into: existing, binaryPath: InstallHooks.selfPath)
            let json = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: json, as: UTF8.self))
            print("\n(dry run — not written to \(url.path))")
            return
        }
        try CursorMCPInstaller.install(binaryPath: InstallHooks.selfPath, projectPath: project)
        print("Registered hypermnesia MCP server in \(url.path)")
        print("  Cursor will offer recall / ask / remember — approve the tools in Cursor when prompted.")
    }
}

/// `hypermnesia install-antigravity-hooks` — register the capture + hydrate hooks in Google
/// Antigravity's `hooks.json`, the Antigravity analogue of `install-hooks`.
struct InstallAntigravityHooks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-antigravity-hooks",
        abstract: "Install Hypermnesia's capture + hydrate hooks into Google Antigravity (~/.gemini/config/hooks.json)."
    )

    @Option(name: .long, help: "Install into a workspace's .agents/hooks.json instead of user settings.")
    var project: String?

    @Flag(name: .long, help: "Remove the Hypermnesia Antigravity hooks instead of installing them.")
    var uninstall = false

    @Flag(name: .long, help: "Print the hook config without writing it.")
    var dryRun = false

    func run() async throws {
        let url = AntigravityHookInstaller.settingsURL(projectPath: project)
        if uninstall {
            if dryRun { print("(dry run) would remove Hypermnesia Antigravity hooks from \(url.path)"); return }
            try AntigravityHookInstaller.uninstall(projectPath: project)
            print("Removed Hypermnesia Antigravity hooks from \(url.path)")
            return
        }
        if dryRun {
            let existing = try ConfigFile.readObject(at: url)
            let merged = AntigravityHookInstaller.merged(into: existing, binaryPath: InstallHooks.selfPath)
            let json = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: json, as: UTF8.self))
            print("\n(dry run — not written to \(url.path))")
            return
        }
        try AntigravityHookInstaller.install(binaryPath: InstallHooks.selfPath, projectPath: project)
        print("Installed Antigravity hooks into \(url.path)")
        print("  PreInvocation (conversation start) → hydrate (inject memories)")
        print("  Stop                               → capture + drain (build memory as sessions end)")
        print("  PreInvocation / Stop               → session-event (live working/finished status for the app's notch display)")
        print("\nNew Antigravity conversations will now build and use memory.")
    }
}

/// `hypermnesia install-antigravity-mcp` — register the stdio MCP server in Google Antigravity's
/// `mcp_config.json` so its agent can call recall / ask / remember.
struct InstallAntigravityMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-antigravity-mcp",
        abstract: "Register the hypermnesia MCP server in Google Antigravity (~/.gemini/config/mcp_config.json)."
    )

    @Option(name: .long, help: "Install into a workspace's .agents/mcp_config.json instead of user settings.")
    var project: String?

    @Flag(name: .long, help: "Remove the hypermnesia MCP server entry instead of adding it.")
    var uninstall = false

    @Flag(name: .long, help: "Print the mcp_config.json config without writing it.")
    var dryRun = false

    func run() async throws {
        let url = AntigravityMCPInstaller.configURL(projectPath: project)
        if uninstall {
            if dryRun { print("(dry run) would remove hypermnesia MCP server from \(url.path)"); return }
            try AntigravityMCPInstaller.uninstall(projectPath: project)
            print("Removed hypermnesia MCP server from \(url.path)")
            return
        }
        if dryRun {
            let existing = try ConfigFile.readObject(at: url)
            let merged = AntigravityMCPInstaller.merged(into: existing, binaryPath: InstallHooks.selfPath)
            let json = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: json, as: UTF8.self))
            print("\n(dry run — not written to \(url.path))")
            return
        }
        try AntigravityMCPInstaller.install(binaryPath: InstallHooks.selfPath, projectPath: project)
        print("Registered hypermnesia MCP server in \(url.path)")
        print("  Antigravity will offer recall / ask / remember — approve the tools when prompted.")
    }
}

/// `hypermnesia install-memory-guide` — write a marker-delimited recall instruction block into
/// CLAUDE.md so MCP-path agents know to call `recall` before editing code.
struct InstallMemoryGuide: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-memory-guide",
        abstract: "Install a CLAUDE.md recall-instruction block so MCP agents call recall before editing."
    )

    @Option(name: .long, help: "Write into <path>/CLAUDE.md instead of the user-global ~/.claude/CLAUDE.md.")
    var project: String?

    @Flag(name: .long, help: "Remove the Hypermnesia memory-guide block instead of installing it.")
    var uninstall = false

    @Flag(name: .long, help: "Print what would be written without making changes.")
    var dryRun = false

    func run() async throws {
        let url = MemoryGuideInstaller.claudeMdURL(projectPath: project)
        let settings = PermissionInstaller.settingsURL(projectPath: project)
        let tools = PermissionInstaller.readOnlyTools.joined(separator: ", ")
        if uninstall {
            if dryRun {
                print("(dry run) would remove Hypermnesia memory-guide block from \(url.path)")
                print("(dry run) would withdraw \(tools) pre-approval from \(settings.path)")
                return
            }
            try RecallPathInstaller.uninstall(projectPath: project)   // symmetric: guide block AND tool pre-approval
            print("Removed Hypermnesia memory-guide block from \(url.path)")
            print("Withdrew \(tools) pre-approval from \(settings.path)")
            return
        }
        if dryRun {
            print(MemoryGuideInstaller.preview(projectPath: project))
            print("\n+ pre-approve \(tools) in \(settings.path)")
            print("(dry run — not written to \(url.path))")
            return
        }
        try RecallPathInstaller.install(projectPath: project)        // guide + tool pre-approval, paired
        print("Installed memory-guide into \(url.path)")
        print("  Agents on the MCP path will now call recall before editing code.")
        print("  Pre-approved recall / ask in \(settings.path)")
        print("  (no per-session prompt; remember stays prompted — it writes a memory)")
        print("\nIf you haven't yet, register the MCP server so `recall` exists:")
        print("  hypermnesia install-mcp\(project.map { " --project \($0)" } ?? "")")
    }
}

/// `hypermnesia allow-tools` — pre-approve the read-only MCP tools (recall/ask) in Claude Code's
/// `permissions.allow`, so an agent's first call doesn't trip the per-session permission prompt.
struct AllowTools: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "allow-tools",
        abstract: "Pre-approve the read-only MCP tools (recall, ask) so they run without a per-session prompt."
    )

    @Option(name: .long, help: "Write into <path>/.claude/settings.json instead of user-global ~/.claude/settings.json.")
    var project: String?

    @Flag(name: .long, help: "Remove the read-only-tool pre-approval instead of adding it.")
    var uninstall = false

    @Flag(name: .long, help: "Print what would change without writing.")
    var dryRun = false

    func run() async throws {
        let url = PermissionInstaller.settingsURL(projectPath: project)
        let tools = PermissionInstaller.readOnlyTools.joined(separator: ", ")
        if uninstall {
            if dryRun { print("(dry run) would remove pre-approval for \(tools) from \(url.path)"); return }
            try PermissionInstaller.uninstall(projectPath: project)
            print("Removed pre-approval for \(tools) from \(url.path)")
            return
        }
        if dryRun {
            let existing = try ConfigFile.readObject(at: url)
            let merged = PermissionInstaller.merged(into: existing)
            let json = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: json, as: UTF8.self))
            print("\n(dry run — not written to \(url.path))")
            return
        }
        let missing = PermissionInstaller.missing(projectPath: project)
        try PermissionInstaller.install(projectPath: project)
        if missing.isEmpty {
            print("Already pre-approved (no change): \(tools)")
        } else {
            print("Pre-approved \(missing.joined(separator: ", ")) in \(url.path)")
            print("  (remember stays prompted — it writes a memory)")
        }
    }
}

/// `hypermnesia backfill --project <path>` — replay a repo's past Claude Code sessions into
/// memories, oldest→newest, with backdated decay and idempotency.
struct Backfill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Process a repo's previous Claude Code sessions into memories (backdated decay)."
    )

    @Option(name: .long, help: "Path to the repository to backfill (omit with --all).")
    var project: String?

    @Flag(name: .long, help: "Backfill every project with transcripts for the chosen --client.")
    var all = false

    @Option(name: .long, help: "Agent client whose past sessions to replay: claude | cursor | antigravity (default: claude).")
    var client: HookClient = .claude

    @Flag(name: .long, help: "List the sessions that would be processed, without classifying.")
    var dryRun = false

    @Option(name: .long, help: "Only process the most recent N unprocessed sessions.")
    var limit: Int?

    @Option(name: .long, help: "Classifier: auto | gemini | claude (default: from app settings).")
    var classifier: String?

    @Option(name: .long, help: "Model override for the chosen classifier.")
    var model: String?

    @Flag(name: .long, help: "Store memories as confirmed instead of drafts.")
    var confirm = false

    func validate() throws {
        // --all and --project are mutually exclusive: --all replays every project's transcripts
        // (one classifier call per session, machine-wide), so silently ignoring an explicit
        // --project would be an expensive, surprising footgun.
        if all && project != nil {
            throw ValidationError(
                "Pass --project or --all, not both: --all backfills every project with transcripts; "
                + "drop --all to backfill just this repo, or drop --project to run the machine-wide backfill.")
        }
    }

    func run() async throws {
        try validateClassifierFlag(classifier)
        if let limit, limit < 0 { throw ValidationError("--limit must be 0 or greater.") }
        setvbuf(stdout, nil, _IONBF, 0)   // unbuffered so per-session progress streams live
        let store = try MemoryStore()
        if all {
            try await runAll(store: store); return
        }
        guard let project else { throw ValidationError("Specify --project <path> or --all.") }

        let repoPath = (project as NSString).expandingTildeInPath
        let projectId = ProjectIdentity.resolve(cwd: repoPath)

        let sessions: [(sessionId: String, url: URL, modifiedAt: Date)]
        switch client {
        case .claude:
            sessions = ClaudeCodeSessions.transcripts(forRepoPath: repoPath).map { ($0.sessionId, $0.url, $0.modifiedAt) }
        case .cursor:
            sessions = CursorSessions.transcripts(forRepoPath: repoPath).map { ($0.sessionId, $0.url, $0.modifiedAt) }
        case .antigravity:
            sessions = AntigravitySessions.transcripts(forRepoPath: repoPath).map { ($0.sessionId, $0.url, $0.modifiedAt) }
        }
        var pending: [(sessionId: String, url: URL, modifiedAt: Date)] = []
        var liveSkipped = 0
        for t in sessions where !((try? store.isProcessed(sessionId: t.sessionId)) ?? false) {
            // Don't seal a session that's still being written; its own hooks (or a later backfill) finish it.
            if SessionIngestor.isLikelyLive(modifiedAt: t.modifiedAt) { liveSkipped += 1; continue }
            pending.append(t)
        }
        if let limit, pending.count > limit { pending = Array(pending.suffix(limit)) }

        print("Project:  \(projectId)")
        print("Client:   \(client.rawValue)")
        print("Sessions: \(sessions.count) total, \(pending.count) new to process"
            + (liveSkipped > 0 ? ", \(liveSkipped) skipped (recently active)" : ""))

        if dryRun {
            for t in pending {
                print("  • \(t.sessionId.prefix(8))  \(ISO8601DateFormatter().string(from: t.modifiedAt))")
            }
            print("\n(dry run — nothing stored). Re-run without --dry-run to classify with \(Classifiers.cliDescription(classifier: classifier)).")
            return
        }
        guard !pending.isEmpty else { print("Nothing to do."); return }

        let engine = Classifiers.forCLI(classifier: classifier, model: model)
        let status: MemoryStatus = confirm ? .confirmed : .draft
        var totalMemories = 0

        var failed = 0
        for (index, t) in pending.enumerated() {
            switch await SessionIngestor.ingestSession(
                transcript: t.url, sessionId: t.sessionId, projectId: projectId,
                classifier: engine, store: store, source: .backfill, status: status
            ) {
            case .captured(let count):
                totalMemories += count
                print("[\(index + 1)/\(pending.count)] \(t.sessionId.prefix(8))  → \(count) memories")
            case .waiting:
                print("[\(index + 1)/\(pending.count)] \(t.sessionId.prefix(8))  → skipped (still being captured live)")
            case .failed(let reason, _):
                failed += 1
                print("[\(index + 1)/\(pending.count)] \(t.sessionId.prefix(8))  → failed: \(reason)")
            }
        }

        print("\nBackfilled \(totalMemories) memories into \(projectId). Open the app to review.")
        if failed > 0 {
            print("\(failed) session(s) failed (not memory-less) — check your classifier configuration "
                + "with `hypermnesia doctor`, then re-run to retry them.")
        }
    }

    /// Backfill across every project with transcripts, classifying each unprocessed session directly
    /// (honoring --limit and --confirm, the same way `--project` does).
    private func runAll(store: MemoryStore) async throws {
        var candidates: [(sessionId: String, url: URL, cwd: String)] = []
        var liveSkipped = 0
        var undecodable: Set<String> = []

        switch client {
        case .claude:
            for transcript in ClaudeCodeSessions.allTranscripts() {
                if (try? store.isProcessed(sessionId: transcript.sessionId)) == true { continue }
                if SessionIngestor.isLikelyLive(modifiedAt: transcript.modifiedAt) { liveSkipped += 1; continue }
                guard let cwd = ClaudeCodeSessions.firstCwd(of: transcript.url) else {
                    // cwd unreadable (not just ephemeral) — report it instead of vanishing from the count.
                    undecodable.insert(transcript.sessionId); continue
                }
                guard !ClaudeCodeSessions.isEphemeral(cwd: cwd) else { continue }
                candidates.append((transcript.sessionId, transcript.url, cwd))
            }
        case .cursor:
            // Cursor transcript lines carry no cwd — recover it from the (lossy) encoded project
            // directory name, skipping directories whose original path no longer exists on disk.
            for (encodedDir, transcript) in CursorSessions.allTranscriptsByProjectDir() {
                if (try? store.isProcessed(sessionId: transcript.sessionId)) == true { continue }
                if SessionIngestor.isLikelyLive(modifiedAt: transcript.modifiedAt) { liveSkipped += 1; continue }
                guard let cwd = CursorSessions.decode(encodedDir: encodedDir) else {
                    undecodable.insert(encodedDir); continue
                }
                guard !ClaudeCodeSessions.isEphemeral(cwd: cwd) else { continue }
                candidates.append((transcript.sessionId, transcript.url, cwd))
            }
        case .antigravity:
            // Antigravity transcripts carry no cwd either — recover the workspace from each
            // transcript's own tool-call args; conversations that never touched a
            // directory-carrying tool can't be attributed and are skipped.
            for transcript in AntigravitySessions.allTranscripts() {
                if (try? store.isProcessed(sessionId: transcript.sessionId)) == true { continue }
                if SessionIngestor.isLikelyLive(modifiedAt: transcript.modifiedAt) { liveSkipped += 1; continue }
                guard let cwd = AntigravitySessions.firstCwd(of: transcript.url) else {
                    undecodable.insert(transcript.sessionId); continue
                }
                guard !ClaudeCodeSessions.isEphemeral(cwd: cwd) else { continue }
                candidates.append((transcript.sessionId, transcript.url, cwd))
            }
        }

        print("Found \(candidates.count) unprocessed session(s) across all projects."
            + (liveSkipped > 0 ? " (\(liveSkipped) recently-active session(s) skipped.)" : ""))
        if !undecodable.isEmpty {
            let what: String
            switch client {
            case .cursor:
                what = "Cursor project dir(s) whose original path couldn't be recovered (the workspace was moved or deleted)"
            case .antigravity:
                what = "Antigravity conversation(s) with no recoverable workspace directory"
            case .claude:
                what = "Claude Code session(s) whose working directory couldn't be read from the transcript"
            }
            print("Skipped \(undecodable.count) \(what): \(undecodable.sorted().joined(separator: ", "))")
        }
        if let limit, candidates.count > limit {
            candidates = Array(candidates.suffix(limit))
            print("Limiting to the \(limit) most recent.")
        }
        if dryRun {
            let byProject = Dictionary(grouping: candidates) { ProjectIdentity.resolve(cwd: $0.cwd) }
            for (pid, items) in byProject.sorted(by: { $0.value.count > $1.value.count }) {
                print("  \(items.count)  \(pid)")
            }
            print("\n(dry run — nothing classified).")
            return
        }
        let engine = Classifiers.forCLI(classifier: classifier, model: model)
        let status: MemoryStatus = confirm ? .confirmed : .draft
        var total = 0
        var failed = 0
        for (index, candidate) in candidates.enumerated() {
            switch await SessionIngestor.ingestSession(
                transcript: candidate.url, sessionId: candidate.sessionId,
                projectId: ProjectIdentity.resolve(cwd: candidate.cwd),
                classifier: engine, store: store, source: .backfill, status: status
            ) {
            case .captured(let count):
                total += count
                print("[\(index + 1)/\(candidates.count)] \(candidate.sessionId.prefix(8))  → \(count) memories")
            case .waiting:
                print("[\(index + 1)/\(candidates.count)] \(candidate.sessionId.prefix(8))  → skipped (still being captured live)")
            case .failed(let reason, _):
                failed += 1
                print("[\(index + 1)/\(candidates.count)] \(candidate.sessionId.prefix(8))  → failed: \(reason)")
            }
        }
        print("Added \(total) memories."
            + (failed > 0 ? " \(failed) session(s) failed to classify — check `hypermnesia doctor` and re-run." : ""))
    }
}

/// `hypermnesia classify <transcript>` — run the classifier on a transcript and print the
/// proposed memories (a dry-run of capture; `--store` actually persists them as drafts).
struct Classify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Classify a transcript into proposed memories (dry-run by default)."
    )

    @Argument(help: "Path to a transcript .jsonl file.")
    var path: String

    @Option(name: .long, help: "Classifier: auto | gemini | claude (default: from app settings).")
    var classifier: String?

    @Option(name: .long, help: "Model override for the chosen classifier.")
    var model: String?

    @Flag(name: .long, help: "Persist the proposed memories as drafts in the store.")
    var store = false

    func run() async throws {
        try validateClassifierFlag(classifier)
        setvbuf(stdout, nil, _IONBF, 0)   // unbuffered so progress streams live
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let convo = try ConversationBuilder.build(transcriptAt: url, sessionId: nil)
        let which = Classifiers.cliDescription(classifier: classifier)
        FileHandle.standardError.write(Data("Condensed to \(convo.messages.count) messages; classifying via \(which)…\n".utf8))

        let memories = try await Classifiers.forCLI(classifier: classifier, model: model).classify(convo, recentMemories: [])

        print("→ \(memories.count) proposed memories:")
        for m in memories {
            print("  [\(m.type.rawValue)] \(m.title)  (conf \(String(format: "%.2f", m.confidence)))")
            print("      \(m.summary)")
        }

        if store, let cwd = convo.cwd {
            let projectId = ProjectIdentity.resolve(cwd: cwd)
            let db = try MemoryStore()
            let drafts = memories.map {
                $0.toDraftNode(projectId: projectId, sessionId: convo.sessionId,
                               createdAt: convo.endedAt ?? Date())
            }
            try db.upsert(drafts)
            print("\nStored \(drafts.count) drafts under project \(projectId).")
        }
    }
}

/// `hypermnesia seed` — populate the local store with sample memories so the app has content to
/// show before live capture exists.
struct Seed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Insert sample memories into the local store (for trying out the app)."
    )

    @Option(name: .long, help: "Project id to seed under.")
    var project = "github.com/acme/widgets"

    func run() async throws {
        let store = try MemoryStore()
        let nodes = SampleMemories.make(projectId: project)
        try store.upsert(nodes)
        print("Seeded \(nodes.count) sample memories into project \(project).")
        print("Run the app with:  swift run HypermnesiaApp")
    }
}

/// `hypermnesia notch-demo` — pop sample cards in the app's notch status display, riding the real
/// pipeline (log append → app watcher → reducer → panel). Clicking the cards exercises real
/// jump-back into the terminal this command ran from.
struct NotchDemo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notch-demo",
        abstract: "Pop sample cards in the app's notch status display (UI preview)."
    )

    @Flag(name: .long, help: "Retract the sample cards instead of showing them.")
    var clear = false

    func run() async throws {
        if clear {
            for event in SessionEventDemo.clearEvents() { SessionEventLog.append(event) }
            print("Cleared the sample cards.")
            return
        }
        if !AppConfigStore.loadBestEffort().notchEnabled {
            print("⚠ Notch status is turned off — enable it in Hypermnesia Settings → Notch, then re-run.")
            return
        }
        // Same capture a real hook does, so clicking a card jumps back to THIS terminal tab.
        let ancestors = ProcessAncestry.chain()
        for event in SessionEventDemo.events(
            hostPids: ancestors.map(\.pid), hostPaths: ancestors.map(\.path),
            tty: ProcessAncestry.controllingTerminal()
        ) {
            SessionEventLog.append(event)
        }
        print("Appended 3 sample cards and 2 working sessions — they should pop from the notch now.")
        print("Hover the panel to unfold the working rows; click any row to test jump-back (it returns here).")
        print("Dismiss cards with the hover-× or `hypermnesia notch-demo --clear`.")
        if ProcessAncestry.controllingTerminal() == nil {
            print("⚠ No controlling terminal here, so clicking these sample cards can only focus the hosting app.")
            print("  Run this from iTerm2/Terminal to feel the real jump-back-to-tab.")
        }
        if !Self.appLooksRunning() {
            print("⚠ The Hypermnesia app doesn't seem to be running — launch it to see the cards.")
        }
    }

    /// Installed bundle runs as "Hypermnesia"; a `swift run` dev build as "HypermnesiaApp".
    private static func appLooksRunning() -> Bool {
        ["Hypermnesia", "HypermnesiaApp"].contains { name in
            !Shell.run("/usr/bin/pgrep", ["-x", name]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// `hypermnesia inspect <transcript.jsonl>` — parse a transcript and summarize the condensed
/// conversation the classifier would see. A debugging aid for the capture pipeline.
struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Parse a Claude Code transcript and summarize the condensed conversation."
    )

    @Argument(help: "Path to a transcript .jsonl file.")
    var path: String

    @Flag(name: .long, help: "Print the full condensed transcript text.")
    var full = false

    func run() async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let convo = try ConversationBuilder.build(transcriptAt: url, sessionId: nil)
        let span = [convo.startedAt, convo.endedAt].compactMap { $0 }
            .map { ISO8601DateFormatter().string(from: $0) }
        print("messages: \(convo.messages.count)")
        print("cwd:      \(convo.cwd ?? "-")")
        print("branch:   \(convo.gitBranch ?? "-")")
        print("span:     \(span.first ?? "-") → \(span.last ?? "-")")
        let chars = convo.messages.reduce(0) { $0 + $1.content.count }
        print("chars:    \(chars)")
        if full {
            print("\n----\n")
            print(convo.transcriptText())
        }
    }
}

/// `hypermnesia doctor` — sanity-check the local environment.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the local environment (toolchain, classifier, paths)."
    )

    func run() async throws {
        var healthy = true
        print("hypermnesia \(Hypermnesia.version)")

        // Report the classifier that is actually configured (what drain/backfill/classify use),
        // not a hardcoded probe for `claude` on PATH — a Gemini user gets a false "found ✓" for a
        // binary they never use, or a false "MISSING ✗" for one they don't need.
        let config = AppConfigStore.loadBestEffort()
        let classifierKind = Classifiers.Kind(rawValue: config.classifier) ?? .auto
        let geminiKeyResolved = AppConfigStore.resolvedGeminiKey(config) != nil
        print("classifier:              \(Classifiers.cliDescription(classifier: nil, config: config))")
        print("  gemini key:            \(geminiKeyResolved ? "resolved ✓" : "not set")")
        if classifierKind == .gemini, !geminiKeyResolved {
            print("  status:                no Gemini key — classification will fail  NEEDS ATTENTION ✗")
            healthy = false
        }
        // The `claude` CLI only matters when the effective classifier actually resolves to it.
        if classifierKind == .claude || (classifierKind == .auto && !geminiKeyResolved) {
            let claudeFound = Self.commandExists("claude")
            print("  claude CLI:            \(claudeFound ? "found ✓" : "MISSING ✗")")
            if !claudeFound { healthy = false }
        }

        func mark(_ ok: Bool) -> String { ok ? "installed ✓" : "not installed" }
        // Hooks can be "installed" (our name is in settings.json) yet dead — the recorded binary
        // path no longer exists after the app is moved/translocated. Report that distinctly instead
        // of a false "installed ✓".
        func hookHealthMark(installed: Bool, missing: String?) -> String {
            guard installed else { return "not installed" }
            if let missing {
                return "installed but binary missing at \(missing) — re-run install-hooks ✗"
            }
            return "installed ✓"
        }
        func hookMark(projectPath: String? = nil) -> String {
            hookHealthMark(
                installed: HookInstaller.isInstalled(projectPath: projectPath),
                missing: HookInstaller.missingBinaryPaths(projectPath: projectPath).first)
        }
        print("\nClaude Code (user-global):")
        print("  capture hooks:   \(hookMark())")
        print("  recall guide:    \(mark(MemoryGuideInstaller.isInstalled()))")
        print("  recall perms:    \(mark(PermissionInstaller.isInstalled()))")

        // "Am I set up for THIS project?" — project-local install state plus what's stored for it.
        // (User-global hooks above apply here too; this shows the project's own .claude/ config.)
        let cwd = FileManager.default.currentDirectoryPath
        let projectId = ProjectIdentity.resolve(cwd: cwd)
        print("\nThis project (\(cwd)):")
        print("  project id:      \(projectId)")
        print("  capture hooks:   \(hookMark(projectPath: cwd)) (project-local)")
        print("  recall guide:    \(mark(MemoryGuideInstaller.isInstalled(projectPath: cwd))) (project-local)")
        print("  recall perms:    \(mark(PermissionInstaller.isInstalled(projectPath: cwd))) (project-local)")
        if let store = try? MemoryStore() {
            let total = ((try? store.counts(projectId: projectId)) ?? [:]).values.reduce(0, +)
            let confirmed = ((try? store.counts(projectId: projectId, status: .confirmed)) ?? [:]).values.reduce(0, +)
            print("  memories:        \(total) (\(confirmed) confirmed, \(total - confirmed) draft)")
        } else {
            print("  memories:        (store unavailable)")
        }

        let cursorPresent = FileManager.default.fileExists(atPath: CursorSessions.projectsDirectory.deletingLastPathComponent().path)
        print("\nCursor\(cursorPresent ? "" : " (no ~/.cursor — app not set up?)"):")
        print("  capture hooks:   \(hookHealthMark(installed: CursorHookInstaller.isInstalled(), missing: CursorHookInstaller.missingBinaryPaths().first)) (\(CursorHookInstaller.settingsURL().path))")
        print("  MCP server:      \(CursorMCPInstaller.isInstalled() ? "registered ✓" : "not registered") (\(CursorMCPInstaller.configURL().path))")

        let antigravityPresent = FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini").path)
        print("\nAntigravity\(antigravityPresent ? "" : " (no ~/.gemini — app not set up?)"):")
        print("  capture hooks:   \(hookHealthMark(installed: AntigravityHookInstaller.isInstalled(), missing: AntigravityHookInstaller.missingBinaryPaths().first)) (\(AntigravityHookInstaller.settingsURL().path))")
        print("  MCP server:      \(AntigravityMCPInstaller.isInstalled() ? "registered ✓" : "not registered") (\(AntigravityMCPInstaller.configURL().path))")

        print("\nStore: \(StoreLocation.supportDirectory.appendingPathComponent("memory.db").path)")
        if let store = try? MemoryStore(), let health = try? store.captureQueueHealth() {
            print("Capture queue:")
            print("  pending:         \(health.pending)")
            print("  processing:      \(health.processing)")
            print("  retrying:        \(health.retrying)")
            print("  terminal errors: \(health.terminalErrors)\(health.hasErrors ? "  NEEDS ATTENTION ✗" : "")")
            if health.hasErrors { healthy = false }
            if let failure = health.lastError {
                print("  last error:      \(failure.sessionId.prefix(8)) attempt \(failure.attempts) — \(failure.message)")
            }
        } else {
            print("Capture queue:     (store unavailable)")
        }
        print("Drain diagnostics: \(HookDrainDiagnostics.logURL.path)")
        print("Set HYPERMNESIA_DEBUG=1 to trace hook runs on stderr.")
        // Exit non-zero when anything above was flagged, so `hypermnesia doctor && …` and CI checks
        // don't succeed on a machine doctor itself just marked NEEDS ATTENTION ✗.
        if healthy {
            print("OK")
        } else {
            print("NEEDS ATTENTION ✗ — see the ✗ marks above")
            throw ExitCode.failure
        }
    }

    static func commandExists(_ name: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", name]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return false
        }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
