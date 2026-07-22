import Foundation

/// Classifies a session by shelling out to the user's Claude Code in headless mode:
/// `claude -p --output-format json --system-prompt …` with the transcript piped on stdin.
///
/// Works on a Claude subscription (OAuth) or with an API key — whatever the CLI is configured with.
/// Deliberately avoids `--bare` (it disables OAuth and hangs on a login prompt) and `--json-schema`
/// (it returns empty in the current CLI build); JSON is enforced via the prompt. Hook recursion is
/// prevented by `HYPERMNESIA_DISABLE=1`, which the installed hook scripts honor.
public struct ClaudeHeadlessClassifier: Classifier {
    public static let defaultModel = "claude-haiku-4-5-20251001"

    public var claudePath: String
    /// Model for classification. `nil` uses the CLI default.
    public var model: String?
    public var timeout: TimeInterval

    public init(
        claudePath: String = "claude",
        model: String? = defaultModel,
        timeout: TimeInterval = 120
    ) {
        self.claudePath = claudePath
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

        var args = ["-p", "--output-format", "json", "--system-prompt", ClassifierPrompts.system]
        if let model { args += ["--model", model] }

        var env = ProcessInfo.processInfo.environment
        env["HYPERMNESIA_DISABLE"] = "1"
        env["HYPERTHYMESIA_DISABLE"] = "1"   // pre-rename hooks may still be installed   // stop the classifier's own session re-triggering hooks

        let result = Shell.run(
            claudePath, args,
            cwd: ClassifierWorkdir.path,
            stdin: ClassifierPrompts.user(conversation, recentMemories: recentMemories, focus: focus),
            environment: env,
            timeout: timeout
        )

        guard result.succeeded else {
            throw ClassifierError.toolFailed(result.stderr.isEmpty ? "exit \(result.status)" : result.stderr)
        }
        return try Self.parse(result.stdout)
    }

    /// Parse the `--output-format json` envelope `{ "type":"result", "result":"<model text>", … }`.
    static func parse(_ stdout: String) throws -> [ClassifiedMemory] {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw ClassifierError.emptyOutput
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if (obj["is_error"] as? Bool) == true {
                throw ClassifierError.toolFailed((obj["result"] as? String) ?? "is_error")
            }
            if let result = obj["result"] as? String {
                return try ClassifierJSON.memories(fromModelText: result)
            }
            if let resultObj = obj["result"] as? [String: Any] {
                let inner = try JSONSerialization.data(withJSONObject: resultObj)
                return try ClassifierJSON.memories(fromModelText: String(decoding: inner, as: UTF8.self))
            }
        }
        // Whole output is (possibly fenced) JSON.
        return try ClassifierJSON.memories(fromModelText: trimmed)
    }
}

extension ClaudeHeadlessClassifier: DreamCompleter {
    /// The CLI can't force JSON output (`--json-schema` returns empty), so JSON is prompt-enforced
    /// and the caller parses defensively (`ClassifierJSON.extractObject` strips fences/prose). The
    /// adapter's `timeout` is the hard ceiling on the subprocess.
    public func completeJSON(system: String, user: String) async throws -> String {
        try await complete(system: system, user: user)
    }
}

extension ClaudeHeadlessClassifier: Completer {
    /// Free-form completion (plain text) — used for natural-language memory queries.
    public func complete(system: String, user: String) async throws -> String {
        var args = ["-p", "--output-format", "json", "--system-prompt", system]
        if let model { args += ["--model", model] }
        var env = ProcessInfo.processInfo.environment
        env["HYPERMNESIA_DISABLE"] = "1"
        env["HYPERTHYMESIA_DISABLE"] = "1"   // pre-rename hooks may still be installed
        let result = Shell.run(claudePath, args, cwd: ClassifierWorkdir.path, stdin: user, environment: env, timeout: timeout)
        guard result.succeeded else {
            throw ClassifierError.toolFailed(result.stderr.isEmpty ? "exit \(result.status)" : result.stderr)
        }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // The CLI can exit 0 with an error envelope (e.g. {"is_error":true,"result":"Credit
            // balance is too low"}); don't return that error string as if it were the answer.
            if obj["is_error"] as? Bool == true {
                throw ClassifierError.toolFailed((obj["result"] as? String) ?? "claude CLI reported an error")
            }
            if let text = obj["result"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }
}
