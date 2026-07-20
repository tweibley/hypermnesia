import Foundation

// MARK: - Inventory

/// A skill that already exists on disk (any client's layout) — fed to the dream so it proposes
/// updates instead of duplicates, and consulted for the update-with-diff flow.
public struct SkillInventoryItem: Sendable, Hashable, Codable {
    public let slug: String
    public let description: String
    /// The skill's directory.
    public let path: String

    public init(slug: String, description: String, path: String) {
        self.slug = slug
        self.description = description
        self.path = path
    }
}

public enum SkillInventory {
    /// Scan every DETECTED skill layout near the project: `<project>/.claude/skills`,
    /// `<project>/.cursor/skills`, `~/.claude/skills`, `~/.gemini/skills` (Gemini CLI /
    /// Antigravity). Layouts that don't exist are simply absent — detect, never invent.
    public static func scan(
        projectPath: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [SkillInventoryItem] {
        var roots: [URL] = []
        if let projectPath {
            let project = URL(fileURLWithPath: projectPath, isDirectory: true)
            roots.append(project.appendingPathComponent(".claude/skills", isDirectory: true))
            roots.append(project.appendingPathComponent(".cursor/skills", isDirectory: true))
        }
        roots.append(home.appendingPathComponent(".claude/skills", isDirectory: true))
        roots.append(home.appendingPathComponent(".gemini/skills", isDirectory: true))

        var items: [SkillInventoryItem] = []
        var seen = Set<String>()
        for root in roots {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let slug = child.lastPathComponent
                guard seen.insert(slug).inserted else { continue }
                let skillFile = child.appendingPathComponent("SKILL.md")
                guard FileManager.default.fileExists(atPath: skillFile.path) else { continue }
                items.append(SkillInventoryItem(
                    slug: slug,
                    description: frontmatterDescription(of: skillFile) ?? "",
                    path: child.path))
            }
        }
        return items
    }

    /// The `description:` line from a SKILL.md's YAML frontmatter (bounded head read).
    static func frontmatterDescription(of url: URL, maxBytes: Int = 4_096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: maxBytes) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: data, as: UTF8.self)
        var inFrontmatter = false
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if inFrontmatter { return nil }
                inFrontmatter = true
                continue
            }
            guard inFrontmatter, trimmed.hasPrefix("description:") else { continue }
            return String(trimmed.dropFirst("description:".count))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

// MARK: - Manifest

/// A skill Hypermnesia itself installed (from a dream proposal) — the manifest is what makes the
/// lifecycle real: uninstallable in one tap, usage-scanned with a watermark, reported back on.
public struct InstalledSkillRecord: Codable, Sendable, Hashable, Identifiable {
    /// Composite identity: a project-scoped skill is unique per project, not globally by slug, so
    /// the same slug can be installed into several projects (and into user scope) at once.
    public var id: String { "\(slug)|\(scope)|\(projectId ?? "")" }
    public var slug: String
    public var title: String
    /// Semantic-ish version written to the VERSION file; updates bump the patch component.
    public var version: String
    public var installedAt: Date
    public var updatedAt: Date
    /// "project" | "user".
    public var scope: String
    public var projectId: String?
    /// The primary skill directory (`…/.claude/skills/<slug>`).
    public var primaryPath: String
    /// Detected-layout mirrors that also received the files.
    public var mirrorPaths: [String]
    /// Usage-scan watermark: transcripts modified before this were already scanned. Starts at
    /// `installedAt` — NEVER the dream lookback window, so skipped nights can't hide usage.
    public var lastScanAt: Date?
    /// Distinct sessions observed using the skill since install.
    public var sessionsSeenUsed: Int
    /// Journal entry that proposed it (provenance).
    public var entryId: String?

    public init(
        slug: String, title: String, version: String, installedAt: Date, updatedAt: Date,
        scope: String, projectId: String?, primaryPath: String, mirrorPaths: [String],
        lastScanAt: Date? = nil, sessionsSeenUsed: Int = 0, entryId: String? = nil
    ) {
        self.slug = slug
        self.title = title
        self.version = version
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.scope = scope
        self.projectId = projectId
        self.primaryPath = primaryPath
        self.mirrorPaths = mirrorPaths
        self.lastScanAt = lastScanAt
        self.sessionsSeenUsed = sessionsSeenUsed
        self.entryId = entryId
    }
}

public struct SkillManifest: Codable, Sendable, Equatable {
    public var skills: [InstalledSkillRecord]
    public init(skills: [InstalledSkillRecord] = []) { self.skills = skills }
}

// MARK: - Installer

public enum SkillInstallError: Error, LocalizedError, Equatable {
    case invalidSlug(String)
    /// A same-slug skill exists on disk that Hypermnesia did not install — never clobbered;
    /// the caller must go through the explicit update-with-diff flow instead.
    case existsUnmanaged(path: String)
    case notInstalled(slug: String)
    case noTarget

    public var errorDescription: String? {
        switch self {
        case .invalidSlug(let s): "'\(s)' can't be used as a skill directory name."
        case .existsUnmanaged(let path):
            "A skill already exists at \(path) that Hypermnesia didn't install — review the diff and update explicitly."
        case .notInstalled(let slug): "No installed dream skill named '\(slug)'."
        case .noTarget: "No install target directory could be resolved."
        }
    }
}

public enum SkillInstaller {

    public static func manifestURL(in supportDirectory: URL = StoreLocation.supportDirectory) -> URL {
        supportDirectory.appendingPathComponent("dream-skills.json")
    }

    /// A manifest record identifies the SAME install only when slug AND scope match, and — for
    /// project scope — the projectId too. Keying on slug alone treats a project-scoped skill as
    /// globally unique, so a second project's install would clobber the first project's copy.
    static func recordMatches(
        _ record: InstalledSkillRecord, slug: String, scope: String, projectId: String?
    ) -> Bool {
        guard record.slug == slug else { return false }
        if scope == "user" { return record.scope == "user" }
        return record.scope == "project" && record.projectId == projectId
    }

    public static func loadManifest(from url: URL? = nil) -> SkillManifest {
        let target = url ?? manifestURL()
        guard let data = try? Data(contentsOf: target) else { return SkillManifest() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SkillManifest.self, from: data)) ?? SkillManifest()
    }

    static func saveManifest(_ manifest: SkillManifest, to url: URL? = nil) throws {
        let target = url ?? manifestURL()
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".dream-skills-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Where an install lands for a scope: the primary directory plus DETECTED mirrors only.
    public struct Targets: Sendable, Equatable {
        public let primary: URL
        public let mirrors: [URL]
    }

    /// Project scope: primary `<project>/.claude/skills`, mirror `<project>/.cursor/skills` when
    /// that layout already exists. User scope: primary `~/.claude/skills`, mirrors
    /// `~/.gemini/skills` (Gemini CLI / Antigravity) and `~/.cursor/skills` when they exist.
    /// All three clients feed dreams; all three detected layouts are honored.
    public static func targets(
        scope: String, projectPath: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Targets? {
        func detected(_ url: URL) -> URL? {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return exists && isDir.boolValue ? url : nil
        }
        if scope == "project" {
            guard let projectPath else { return nil }
            let project = URL(fileURLWithPath: projectPath, isDirectory: true)
            return Targets(
                primary: project.appendingPathComponent(".claude/skills", isDirectory: true),
                mirrors: [detected(project.appendingPathComponent(".cursor/skills", isDirectory: true))]
                    .compactMap { $0 })
        }
        return Targets(
            primary: home.appendingPathComponent(".claude/skills", isDirectory: true),
            mirrors: [
                detected(home.appendingPathComponent(".gemini/skills", isDirectory: true)),
                detected(home.appendingPathComponent(".cursor/skills", isDirectory: true)),
            ].compactMap { $0 })
    }

    /// Install a staged proposal: write `<target>/<slug>/SKILL.md` + `VERSION` (1.0.0) to the
    /// primary and every detected mirror, and record it in the manifest.
    ///
    /// No-clobber: a same-slug directory that ISN'T in the manifest throws `existsUnmanaged` —
    /// updating someone else's skill requires the explicit diff-confirmed `update` call.
    @discardableResult
    public static func install(
        _ proposal: DreamSkillProposal,
        scope: String,
        projectPath: String?,
        projectId: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        manifestURL explicitManifestURL: URL? = nil,
        entryId: String? = nil,
        now: Date = Date()
    ) throws -> InstalledSkillRecord {
        guard let slug = DreamValidator.sanitizeSlug(proposal.slug) else {
            throw SkillInstallError.invalidSlug(proposal.slug)
        }
        guard let targets = targets(scope: scope, projectPath: projectPath, home: home) else {
            throw SkillInstallError.noTarget
        }
        var manifest = loadManifest(from: explicitManifestURL)
        let primaryDir = targets.primary.appendingPathComponent(slug, isDirectory: true)

        let managed = manifest.skills.first {
            recordMatches($0, slug: slug, scope: scope, projectId: projectId)
        }
        if let existing = managed, FileManager.default.fileExists(atPath: existing.primaryPath) {
            // Already managed FOR THIS scope/project → this is an update (version bump).
            return try update(
                slug: slug, markdown: proposal.markdown, title: proposal.title,
                manifestURL: explicitManifestURL, now: now, existing: existing, manifest: &manifest)
        }
        if FileManager.default.fileExists(atPath: primaryDir.path) {
            throw SkillInstallError.existsUnmanaged(path: primaryDir.path)
        }
        // A managed record whose directory has since vanished is stale — drop it and reinstall
        // fresh, rather than silently writing nothing and reporting success.
        manifest.skills.removeAll { recordMatches($0, slug: slug, scope: scope, projectId: projectId) }

        let version = "1.0.0"
        var written: [URL] = []
        for root in [targets.primary] + targets.mirrors {
            let dir = root.appendingPathComponent(slug, isDirectory: true)
            // A mirror dir that exists unmanaged is skipped (never clobbered) — the primary's
            // existence was already vetoed above.
            if FileManager.default.fileExists(atPath: dir.path), dir != primaryDir { continue }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(proposal.markdown.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
            try Data((version + "\n").utf8).write(to: dir.appendingPathComponent("VERSION"))
            written.append(dir)
        }
        guard let primary = written.first else { throw SkillInstallError.noTarget }

        let record = InstalledSkillRecord(
            slug: slug, title: proposal.title, version: version,
            installedAt: now, updatedAt: now, scope: scope, projectId: projectId,
            primaryPath: primary.path, mirrorPaths: written.dropFirst().map(\.path),
            lastScanAt: now, sessionsSeenUsed: 0, entryId: entryId)
        manifest.skills.append(record)
        try saveManifest(manifest, to: explicitManifestURL)
        return record
    }

    /// Rewrite an installed (or diff-confirmed foreign) skill's SKILL.md and bump its VERSION.
    /// For a foreign skill (`existing == nil` in the manifest) the caller has ALREADY shown the
    /// diff and gotten confirmation — this adopts it into the manifest as version 1.0.1.
    @discardableResult
    public static func update(
        slug rawSlug: String,
        markdown: String,
        title: String,
        scope: String = "project",
        projectPath: String? = nil,
        projectId: String? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        manifestURL explicitManifestURL: URL? = nil,
        entryId: String? = nil,
        now: Date = Date()
    ) throws -> InstalledSkillRecord {
        guard let slug = DreamValidator.sanitizeSlug(rawSlug) else {
            throw SkillInstallError.invalidSlug(rawSlug)
        }
        var manifest = loadManifest(from: explicitManifestURL)
        if let existing = manifest.skills.first(where: {
            recordMatches($0, slug: slug, scope: scope, projectId: projectId)
        }) {
            return try update(
                slug: slug, markdown: markdown, title: title,
                manifestURL: explicitManifestURL, now: now, existing: existing, manifest: &manifest)
        }
        // Foreign skill, diff-confirmed by the caller: adopt in place.
        guard let targets = targets(scope: scope, projectPath: projectPath, home: home) else {
            throw SkillInstallError.noTarget
        }
        let dir = targets.primary.appendingPathComponent(slug, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw SkillInstallError.notInstalled(slug: slug)
        }
        let version = "1.0.1"
        try Data(markdown.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        try Data((version + "\n").utf8).write(to: dir.appendingPathComponent("VERSION"))
        let record = InstalledSkillRecord(
            slug: slug, title: title, version: version,
            installedAt: now, updatedAt: now, scope: scope, projectId: projectId,
            primaryPath: dir.path, mirrorPaths: [],
            lastScanAt: now, sessionsSeenUsed: 0, entryId: entryId)
        manifest.skills.append(record)
        try saveManifest(manifest, to: explicitManifestURL)
        return record
    }

    private static func update(
        slug: String, markdown: String, title: String,
        manifestURL explicitManifestURL: URL?, now: Date,
        existing: InstalledSkillRecord, manifest: inout SkillManifest
    ) throws -> InstalledSkillRecord {
        var record = existing
        record.version = bumpPatch(record.version)
        record.updatedAt = now
        record.title = title
        var wroteAny = false
        for path in [record.primaryPath] + record.mirrorPaths {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            try Data(markdown.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
            try Data((record.version + "\n").utf8).write(to: dir.appendingPathComponent("VERSION"))
            wroteAny = true
        }
        // Every recorded directory is gone: writing nothing yet returning success would report a
        // phantom install/update. Surface it instead of lying about the outcome.
        guard wroteAny else { throw SkillInstallError.notInstalled(slug: slug) }
        manifest.skills = manifest.skills.map { $0.id == record.id ? record : $0 }
        try saveManifest(manifest, to: explicitManifestURL)
        return record
    }

    /// One-tap uninstall: remove the skill directory (and every mirror) and drop the record.
    /// Pass `scope`/`projectId` to target one project's copy — omitting them falls back to a
    /// slug-only match, which is ambiguous once the same slug is installed in several projects.
    @discardableResult
    public static func uninstall(
        slug: String, scope: String? = nil, projectId: String? = nil,
        manifestURL explicitManifestURL: URL? = nil
    ) throws -> InstalledSkillRecord {
        var manifest = loadManifest(from: explicitManifestURL)
        let match: (InstalledSkillRecord) -> Bool
        if let scope {
            match = { recordMatches($0, slug: slug, scope: scope, projectId: projectId) }
        } else {
            match = { $0.slug == slug }
        }
        guard let record = manifest.skills.first(where: match) else {
            throw SkillInstallError.notInstalled(slug: slug)
        }
        for path in [record.primaryPath] + record.mirrorPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        manifest.skills.removeAll { $0.id == record.id }
        try saveManifest(manifest, to: explicitManifestURL)
        return record
    }

    /// The currently installed SKILL.md content (for the update diff), if readable.
    public static func currentMarkdown(record: InstalledSkillRecord) -> String? {
        let url = URL(fileURLWithPath: record.primaryPath, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Read a foreign (unmanaged) skill's markdown at a scope's primary target, for the
    /// update-with-diff flow.
    public static func unmanagedMarkdown(
        slug: String, scope: String, projectPath: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard let targets = targets(scope: scope, projectPath: projectPath, home: home) else { return nil }
        let url = targets.primary
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Usage scan (watermark-based report-back)

    /// Scan transcripts modified AFTER the record's watermark for invocations of the skill, and
    /// advance the watermark. Sessions are counted once. The watermark starts at install time and
    /// moves to `now` on every scan — never tied to the dream lookback window, so skipped dream
    /// nights can't hide usage.
    public static func scanUsage(
        record: InstalledSkillRecord,
        transcripts: [(sessionId: String, url: URL, modifiedAt: Date)],
        now: Date = Date(),
        maxBytesPerTranscript: Int = 2_000_000
    ) -> (record: InstalledSkillRecord, newSessions: Int) {
        var updated = record
        let watermark = record.lastScanAt ?? record.installedAt
        var newSessions = 0
        for transcript in transcripts where transcript.modifiedAt > watermark {
            guard let handle = try? FileHandle(forReadingFrom: transcript.url),
                  let data = try? handle.read(upToCount: maxBytesPerTranscript) else { continue }
            try? handle.close()
            if mentionsSkill(String(decoding: data, as: UTF8.self), slug: record.slug) {
                newSessions += 1
            }
        }
        updated.lastScanAt = now
        updated.sessionsSeenUsed += newSessions
        return (updated, newSessions)
    }

    /// Persist a scanned record back into the manifest.
    public static func recordUsage(
        _ record: InstalledSkillRecord, manifestURL explicitManifestURL: URL? = nil
    ) throws {
        var manifest = loadManifest(from: explicitManifestURL)
        manifest.skills = manifest.skills.map { $0.id == record.id ? record : $0 }
        try saveManifest(manifest, to: explicitManifestURL)
    }

    /// A transcript "uses" a skill when the slug appears at a word boundary — matches Skill-tool
    /// invocations, `/slug` slash commands, and skill-name mentions, while `foo-bar` never matches
    /// slug `bar`.
    static func mentionsSkill(_ text: String, slug: String) -> Bool {
        guard !slug.isEmpty else { return false }
        var from = text.startIndex
        while let range = text.range(of: slug, range: from..<text.endIndex) {
            let beforeOK: Bool = range.lowerBound == text.startIndex || {
                let c = text[text.index(before: range.lowerBound)]
                return !(c.isLetter || c.isNumber || c == "-")
            }()
            let afterOK: Bool = range.upperBound == text.endIndex || {
                let c = text[range.upperBound]
                return !(c.isLetter || c.isNumber || c == "-")
            }()
            if beforeOK && afterOK { return true }
            from = range.upperBound
        }
        return false
    }

    /// "1.0.0" → "1.0.1"; unparseable versions restart at "1.0.1".
    static func bumpPatch(_ version: String) -> String {
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else {
            return "1.0.1"
        }
        return "\(major).\(minor).\(patch + 1)"
    }

    /// Line-level added/removed counts for the update-with-diff card.
    public static func diffSummary(old: String, new: String) -> (added: Int, removed: Int) {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false)
        var oldCounts: [Substring: Int] = [:]
        for line in oldLines { oldCounts[line, default: 0] += 1 }
        var added = 0
        var remaining = oldCounts
        for line in newLines {
            if let count = remaining[line], count > 0 {
                remaining[line] = count - 1
            } else {
                added += 1
            }
        }
        let removed = remaining.values.reduce(0, +)
        return (added, removed)
    }
}
