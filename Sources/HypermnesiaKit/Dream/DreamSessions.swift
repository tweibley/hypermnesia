import Foundation

/// Discovers the recent session transcripts a dream reads, across all three clients (Claude Code,
/// Cursor, Antigravity), mapped to project ids the same way backfill discovery does. Client-owned
/// transcripts are read in place and never modified.
public enum DreamSessions {

    public struct Ref: Sendable, Hashable {
        public let sessionId: String
        public let url: URL
        public let modifiedAt: Date
        public let projectId: String

        public init(sessionId: String, url: URL, modifiedAt: Date, projectId: String) {
            self.sessionId = sessionId
            self.url = url
            self.modifiedAt = modifiedAt
            self.projectId = projectId
        }
    }

    /// All clients' transcripts modified since `since`, excluding likely-live sessions (a dream
    /// must not read a session that's still being written) and throwaway temp workspaces.
    public static func discover(since: Date, now: Date = Date()) -> [Ref] {
        var refs: [Ref] = []
        var seen = Set<String>()

        func add(sessionId: String, url: URL, modifiedAt: Date, cwd: String?) {
            guard modifiedAt >= since,
                  !SessionIngestor.isLikelyLive(modifiedAt: modifiedAt, now: now),
                  let cwd, !ClaudeCodeSessions.isEphemeral(cwd: cwd),
                  seen.insert(sessionId).inserted else { return }
            refs.append(Ref(
                sessionId: sessionId, url: url, modifiedAt: modifiedAt,
                projectId: ProjectIdentity.resolve(cwd: cwd)))
        }

        for t in ClaudeCodeSessions.allTranscripts() where t.modifiedAt >= since {
            add(sessionId: t.sessionId, url: t.url, modifiedAt: t.modifiedAt,
                cwd: ClaudeCodeSessions.firstCwd(of: t.url))
        }
        var decodedDirs: [String: String?] = [:]
        for (encodedDir, t) in CursorSessions.allTranscriptsByProjectDir() where t.modifiedAt >= since {
            let cwd = decodedDirs[encodedDir] ?? {
                let value = CursorSessions.decode(encodedDir: encodedDir)
                decodedDirs[encodedDir] = value
                return value
            }()
            add(sessionId: t.sessionId, url: t.url, modifiedAt: t.modifiedAt, cwd: cwd)
        }
        for t in AntigravitySessions.allTranscripts() where t.modifiedAt >= since {
            add(sessionId: t.sessionId, url: t.url, modifiedAt: t.modifiedAt,
                cwd: AntigravitySessions.firstCwd(of: t.url))
        }
        return refs.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public static func refs(
        forProject projectId: String, since: Date, now: Date = Date()
    ) -> [Ref] {
        discover(since: since, now: now).filter { $0.projectId == projectId }
    }

    /// Condense one transcript for the dream prompt: the same parser + budget discipline the
    /// classifier uses, bounded per session so a handful of sessions fit one call.
    public static func condense(_ ref: Ref, maxChars: Int = 7_000) -> DreamSessionInput? {
        var options = ConversationBuilder.Options()
        options.maxTotalChars = maxChars
        guard let conversation = try? ConversationBuilder.build(
            transcriptAt: ref.url, sessionId: ref.sessionId, options: options),
            !conversation.isEmpty else { return nil }
        return DreamSessionInput(
            sessionId: ref.sessionId,
            endedAt: conversation.endedAt ?? ref.modifiedAt,
            text: conversation.transcriptText())
    }
}

/// End-to-end orchestration for one project's dream — shared verbatim by the CLI command, the
/// Dream-now button, the first-dream-after-backfill moment, and the app's nightly loop (which adds
/// the idle/power/cap gating around it).
public enum DreamService {

    /// Session budget per dream: newest-first, capped so one model call stays bounded.
    public static let maxSessionsPerDream = 8

    public static func runConfig(_ appConfig: AppConfig) -> DreamRunConfig {
        DreamRunConfig(
            lookbackDays: max(1, appConfig.dreamLookbackDays),
            proposeMemories: appConfig.dreamProposeMemories,
            proposeSkills: appConfig.dreamProposeSkills,
            classifierLabel: DreamCompleters.label(appConfig))
    }

    /// Dream one project now (no idle/cap gating — callers that need gating do it around this).
    public static func dreamProject(
        projectId: String,
        store: MemoryStore,
        appConfig: AppConfig = AppConfigStore.loadBestEffort(),
        completer: DreamCompleter? = nil,
        manifestURL: URL? = nil,
        now: Date = Date()
    ) async -> DreamRunner.RunResult {
        // Advisory cross-process lock (mirrors `drain.lock`): the app's nightly pass, the "Dream
        // now" button, and the `hypermnesia dream` CLI must never dream the same night concurrently
        // — two runs both write tonight's `(projectId, night)` entry and `upsertDreamEntry` deletes
        // the other, destroying one dream's journal narrative while its drafts survive orphaned.
        try? FileManager.default.createDirectory(
            at: StoreLocation.supportDirectory, withIntermediateDirectories: true)
        let lockPath = StoreLocation.supportDirectory.appendingPathComponent("dream.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            return .skipped("another dream is already running")
        }
        defer { flock(fd, LOCK_UN); close(fd) }

        let config = runConfig(appConfig)
        let lookbackCutoff = now.addingTimeInterval(-Double(config.lookbackDays) * 86_400)

        // The usage-scan watermark may reach further back than the dream window — a skipped night
        // must not hide skill usage — so discovery covers whichever is older.
        let manifest = SkillInstaller.loadManifest(from: manifestURL)
        let relevantSkills = manifest.skills.filter { $0.projectId == projectId || $0.scope == "user" }
        let oldestWatermark = relevantSkills
            .map { $0.lastScanAt ?? $0.installedAt }
            .min()
        let since = min(lookbackCutoff, oldestWatermark ?? lookbackCutoff)

        // Discover once across all clients/projects; the dream prompt reads only THIS project's
        // sessions, but a user-scope skill's usage must be scanned across every project.
        let allRefs = DreamSessions.discover(since: since, now: now)
        let refs = allRefs.filter { $0.projectId == projectId }
        let windowRefs = refs.filter { $0.modifiedAt >= lookbackCutoff }
        let sessions = windowRefs
            .prefix(maxSessionsPerDream)
            .compactMap { DreamSessions.condense($0) }

        // Project-scope skills scan this project's transcripts; user-scope skills scan ALL projects'
        // (they are used everywhere). Advanced watermarks are NOT persisted here — only after the run
        // produces a journal entry carrying these report-backs, so a pre-gate-skipped night can't
        // consume the scan window and silently swallow the usage it found.
        let (skillBacks, scannedRecords) = scanSkillUsage(
            records: relevantSkills,
            projectTranscripts: refs.map { ($0.sessionId, $0.url, $0.modifiedAt) },
            userTranscripts: allRefs.map { ($0.sessionId, $0.url, $0.modifiedAt) },
            now: now)

        let projectPath = MemoryAuditor.repoPath(forProjectId: projectId)
        let inventory = SkillInventory.scan(projectPath: projectPath)

        let result = await DreamRunner.run(
            projectId: projectId,
            store: store,
            completer: completer ?? DreamCompleters.makeFromConfig(appConfig),
            sessions: Array(sessions),
            skillInventory: inventory,
            skillReportBacks: skillBacks,
            config: config,
            now: now)

        // Persist the advanced usage watermarks only when the run actually recorded an entry that
        // carries `skillBacks`; a skipped/failed-to-persist run leaves the watermark untouched so
        // the usage isn't lost to a window nobody reported on.
        if result.entry != nil {
            for record in scannedRecords {
                try? SkillInstaller.recordUsage(record, manifestURL: manifestURL)
            }
        }
        return result
    }

    /// Watermark-scan every installed dream skill and turn results into plain-spoken report-backs
    /// (positive AND negative — the system says whether its suggestions worked). Does NOT persist
    /// the advanced watermarks — the returned records are persisted by the caller only once a run
    /// has recorded them. User-scope skills scan across ALL projects' transcripts; project-scope
    /// skills scan only their own project's — so a user-scope skill used in another project is not
    /// wrongly reported as unused, and no project consumes the scan window on another's behalf.
    static func scanSkillUsage(
        records: [InstalledSkillRecord],
        projectTranscripts: [(sessionId: String, url: URL, modifiedAt: Date)],
        userTranscripts: [(sessionId: String, url: URL, modifiedAt: Date)],
        now: Date
    ) -> (backs: [DreamReportBack], updated: [InstalledSkillRecord]) {
        var backs: [DreamReportBack] = []
        var updatedRecords: [InstalledSkillRecord] = []
        for record in records {
            let transcripts = record.scope == "user" ? userTranscripts : projectTranscripts
            let (updated, newSessions) = SkillInstaller.scanUsage(
                record: record, transcripts: transcripts, now: now)
            updatedRecords.append(updated)
            let daysSinceInstall = Int(now.timeIntervalSince(record.installedAt) / 86_400)
            if newSessions > 0 {
                backs.append(DreamReportBack(
                    kind: .skill, subject: record.slug, title: record.title,
                    detail: "The \(record.slug) skill you installed was used in \(newSessions) "
                        + "session\(newSessions == 1 ? "" : "s") since the last dream."))
            } else if updated.sessionsSeenUsed == 0, daysSinceInstall >= 3 {
                backs.append(DreamReportBack(
                    kind: .skill, subject: record.slug, title: record.title,
                    detail: "The \(record.slug) skill hasn't been used since you installed it "
                        + "\(daysSinceInstall) days ago — consider uninstalling it."))
            }
        }
        return (backs, updatedRecords)
    }
}
