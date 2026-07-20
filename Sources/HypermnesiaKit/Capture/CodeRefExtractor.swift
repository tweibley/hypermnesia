import Foundation

/// Deterministic codeRef producer: one aggregated node per repo-relative file path, derived from
/// edit-tool uses in a transcript slice. No LLM — edits are observed facts.
public enum CodeRefExtractor {

    public static let environmentKey = "HYPERMNESIA_CODE_REFS"
    public static let maxFilesPerSession = 10
    /// Observed fact prior — high, but first sighting stays draft (`confirmConfident` is skipped).
    public static let observedConfidence = 0.9

    /// Whether the producer runs: the persisted `captureCodeRefs` setting decides, and the
    /// `HYPERMNESIA_CODE_REFS` environment variable — when set at all — overrides it either way
    /// (a launch-time development escape hatch, per the project's env-var convention).
    public static func isEnabled(config: AppConfig) -> Bool {
        isEnabled(env: ProcessInfo.processInfo.environment[environmentKey], config: config)
    }

    static func isEnabled(env: String?, config: AppConfig) -> Bool {
        if let env, !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return isEnabled(env)
        }
        return config.captureCodeRefs
    }

    /// Truthy parse of the env override (`1`, `true`, `yes` — anything but `0/false/no/off`).
    public static func isEnabled(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !v.isEmpty else { return false }
        return v != "0" && v != "false" && v != "no" && v != "off"
    }

    /// Collect distinct edited paths from `events` and emit draft codeRef nodes.
    ///
    /// Always emits `.draft` regardless of the ingest's status: codeRefs are elevated to confirmed
    /// only by sighting accrual (or a human), never by a caller-level confirm-everything flag.
    ///
    /// - Parameters:
    ///   - projectRoot: Working-tree root used to normalize absolute paths. When nil, resolved from
    ///     event cwd / `projectId` (`path:` ids and session discovery).
    public static func extract(
        from events: [TranscriptEvent],
        projectId: String,
        sessionId: String?,
        createdAt: Date,
        commitSha: String? = nil,
        branch: String? = nil,
        projectRoot: String? = nil
    ) -> [MemoryNode] {
        let root = resolveRoot(projectRoot: projectRoot, projectId: projectId, events: events)
        var counts: [String: Int] = [:]
        var snippets: [String: String] = [:]
        var order: [String] = []

        for event in events {
            for use in event.toolUses {
                guard let raw = use.editedFilePath, !raw.isEmpty else { continue }
                guard let relative = normalize(path: raw, projectRoot: root, cwd: event.cwd),
                      !isDenied(relative)
                else { continue }
                if counts[relative] == nil { order.append(relative) }
                counts[relative, default: 0] += 1
                if let snippet = use.editSnippet, !snippet.isEmpty {
                    snippets[relative] = snippet
                }
            }
        }

        // Respect the project's own noise judgment: anything .gitignore'd is not shared project
        // code (build output, local config), so it never becomes a durable reference.
        let ignored = gitIgnored(order, repoRoot: root)
        if !ignored.isEmpty { order.removeAll { ignored.contains($0) } }

        let ranked = order.sorted { a, b in
            let ca = counts[a] ?? 0, cb = counts[b] ?? 0
            return ca != cb ? ca > cb : a < b
        }
        let selected = Array(ranked.prefix(maxFilesPerSession))

        return selected.map { path in
            let title = URL(fileURLWithPath: path).lastPathComponent
            return MemoryNode(
                projectId: projectId,
                type: .codeRef,
                status: .draft,
                title: title,
                summary: path,
                data: .codeRef(.init(filePath: path, snippet: snippets[path])),
                confidence: observedConfidence,
                belief: observedConfidence,
                createdAt: createdAt,
                updatedAt: createdAt,
                lastValidatedAt: createdAt,
                conversationId: sessionId,
                commitSha: commitSha,
                branch: branch
            )
        }
    }

    // MARK: - Path normalization

    static func resolveRoot(projectRoot: String?, projectId: String, events: [TranscriptEvent]) -> String? {
        if let projectRoot, !projectRoot.isEmpty { return projectRoot }
        for event in events {
            if let cwd = event.cwd, !cwd.isEmpty {
                return ProjectIdentity.repoRoot(cwd: cwd) ?? cwd
            }
        }
        return MemoryAuditor.repoPath(forProjectId: projectId)
    }

    /// Repo-relative path, or nil when outside the project root / unresolvable.
    static func normalize(path: String, projectRoot: String?, cwd: String?) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") {
            guard let root = projectRoot ?? cwd.flatMap({ ProjectIdentity.repoRoot(cwd: $0) ?? $0 })
            else { return nil }
            return relativeIfInside(absolute: trimmed, root: root)
        }

        // Relative — resolve against the client's cwd first, then re-relativize against the repo
        // root. A path relative to a subdirectory cwd (e.g. `public/index.html` while working in
        // `site/`) must not be stored as if it were repo-relative.
        let cleaned = (trimmed as NSString).standardizingPath
        if cleaned.hasPrefix("/") {
            // standardizingPath can absolutize; treat as absolute.
            guard let root = projectRoot else { return nil }
            return relativeIfInside(absolute: cleaned, root: root)
        }
        if let base = cwd ?? projectRoot {
            let absolute = ((base as NSString).appendingPathComponent(cleaned) as NSString).standardizingPath
            guard let root = projectRoot ?? cwd.flatMap({ ProjectIdentity.repoRoot(cwd: $0) ?? $0 })
            else { return nil }
            return relativeIfInside(absolute: absolute, root: root)
        }
        // No cwd and no root: keep the relative path best-effort, rejecting escapes.
        if cleaned.hasPrefix("../") || cleaned == ".." { return nil }
        return cleaned
    }

    static func relativeIfInside(absolute: String, root: String) -> String? {
        let abs = (absolute as NSString).standardizingPath
        let rootStd = (root as NSString).standardizingPath
        let prefix = rootStd.hasSuffix("/") ? rootStd : rootStd + "/"
        guard abs == rootStd || abs.hasPrefix(prefix) else { return nil }
        if abs == rootStd { return nil }
        return String(abs.dropFirst(prefix.count))
    }

    // MARK: - Denylist

    /// Static rules cover only what .gitignore usually does NOT: tracked lockfiles, generated
    /// sources, and secrets-bearing files whose 200-char snippet must never land in the store.
    /// Everything else (build dirs, caches, local config) is delegated to `gitIgnored` — the
    /// project's own noise judgment. Dot-prefixed paths like `.github/workflows/` are legitimate
    /// project code and are deliberately NOT denied.
    static let deniedBasenames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock",
        "package.resolved", "cargo.lock", "poetry.lock", "gemfile.lock", "composer.lock",
        "go.sum", "flake.lock",
        ".npmrc", ".netrc", ".pypirc",
    ]

    /// Fallback for non-git projects (a git repo's .gitignore covers these already).
    static let deniedPathComponents: Set<String> = [
        "node_modules", ".git", "deriveddata", ".build", "build", "dist", "vendor",
        "__pycache__", ".swiftpm", ".cache", "pods", "carthage",
    ]

    static func isDenied(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return true }
        for part in parts where deniedPathComponents.contains(part.lowercased()) { return true }
        let base = parts.last!.lowercased()
        if deniedBasenames.contains(base) { return true }
        if base == ".env" || base.hasPrefix(".env.") { return true }   // secrets, snippet risk
        if base.contains(".generated.") { return true }
        if base.hasSuffix(".pb.swift") || base.hasSuffix(".g.dart") { return true }
        return false
    }

    // MARK: - .gitignore

    /// The subset of `paths` (repo-relative) that the project's own git ignore rules exclude.
    /// Empty when `repoRoot` is nil, isn't a git work tree, or git is unavailable — static rules
    /// then stand alone. One batched `check-ignore` call; `-z` on both ends avoids quoting issues.
    static func gitIgnored(_ paths: [String], repoRoot: String?) -> Set<String> {
        guard !paths.isEmpty, let repoRoot,
              FileManager.default.fileExists(atPath: repoRoot + "/.git")
        else { return [] }
        let result = Shell.run(
            "git", ["-C", repoRoot, "check-ignore", "-z", "--stdin"],
            cwd: repoRoot, stdin: paths.joined(separator: "\0"), timeout: 10
        )
        // Exit 0: some ignored (listed on stdout). Exit 1: none. Anything else: fail open.
        guard result.status == 0 else { return [] }
        return Set(result.stdout.split(separator: "\0").map(String.init))
    }
}
