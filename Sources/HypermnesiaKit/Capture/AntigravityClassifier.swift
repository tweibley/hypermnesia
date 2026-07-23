import Foundation

/// Classifies a session by shelling out to Google Antigravity's CLI in print mode:
/// `agy --print <prompt> --model <model>`.
///
/// Runs on the user's Antigravity (Google) sign-in — no separate `GEMINI_API_KEY` needed, which is
/// the point: an Antigravity user gets classification with zero extra setup. Unlike `claude -p`
/// the CLI has no system-prompt flag and does not read the prompt from stdin, so the rubric and the
/// (fenced, untrusted) transcript are concatenated into the single `--print` argument. Prompt sizes
/// are bounded upstream (`ConversationBuilder.Options.maxTotalChars`, `DreamSessions.condense`),
/// keeping the argument well under the macOS 1 MB argv limit. Output is the raw model text — no
/// JSON envelope — so it is parsed leniently via `ClassifierJSON` (fences/prose tolerated).
/// Hook recursion is prevented by `HYPERMNESIA_DISABLE=1`, which the installed hooks honor.
public struct AntigravityClassifier: Classifier {
    public static let defaultModel = "gemini-3.6-flash-medium"

    public var agyPath: String
    /// Model for classification (an `agy models` name). `nil` uses the CLI default.
    public var model: String?
    public var timeout: TimeInterval

    public init(
        agyPath: String = "agy",
        model: String? = defaultModel,
        timeout: TimeInterval = 120
    ) {
        self.agyPath = agyPath
        self.model = model
        self.timeout = timeout
    }

    public func classify(
        _ conversation: Conversation,
        recentMemories: [RecentMemoryHint]
    ) async throws -> [ClassifiedMemory] {
        try await classify(conversation, recentMemories: recentMemories, focus: nil)
    }

    public func classify(
        _ conversation: Conversation,
        recentMemories: [RecentMemoryHint],
        focus: String?
    ) async throws -> [ClassifiedMemory] {
        guard !conversation.isEmpty else { return [] }
        let text = try run(
            system: ClassifierPrompts.system,
            user: ClassifierPrompts.user(conversation, recentMemories: recentMemories, focus: focus)
        )
        guard !text.isEmpty else { throw ClassifierError.emptyOutput }
        return try ClassifierJSON.memories(fromModelText: text)
    }

    /// One `agy --print` invocation; returns trimmed stdout (the raw model text).
    ///
    /// Runs from `ClassifierWorkdir.path` for the same self-ingestion reason as the claude adapter:
    /// Antigravity conversations are attributed to a repo via their first directory-carrying tool
    /// call (`AntigravitySessions.firstCwd`), so a print-mode run started in the throwaway temp dir
    /// can never be attributed to a real project and re-ingested.
    private func run(system: String, user: String) throws -> String {
        var args = ["--print", system + "\n\n" + user]
        if let model { args += ["--model", model] }

        // Login-shell merge: see LoginShellEnvironment — the GUI app's bare launchd environment
        // otherwise breaks PATH-dependent auth helpers and profile-exported keys.
        var env = LoginShellEnvironment.classifierEnvironment()
        env["HYPERMNESIA_DISABLE"] = "1"
        env["HYPERTHYMESIA_DISABLE"] = "1"   // pre-rename hooks may still be installed

        let result = Shell.run(agyPath, args, cwd: ClassifierWorkdir.path, environment: env, timeout: timeout)
        guard result.succeeded else {
            throw ClassifierError.toolFailed(result.stderr.isEmpty ? "exit \(result.status)" : result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AntigravityClassifier: Completer {
    /// Free-form completion (plain text) — used for natural-language memory queries.
    public func complete(system: String, user: String) async throws -> String {
        try run(system: system, user: user)
    }
}

extension AntigravityClassifier: DreamCompleter {
    /// Like `claude -p`, JSON is prompt-enforced only; callers parse defensively with
    /// `ClassifierJSON.extractObject`. The adapter's `timeout` is the hard ceiling.
    public func completeJSON(system: String, user: String) async throws -> String {
        let text = try run(system: system, user: user)
        guard !text.isEmpty else { throw ClassifierError.emptyOutput }
        return text
    }
}
