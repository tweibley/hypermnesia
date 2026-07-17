import Foundation

/// Discovers Google Antigravity conversation transcripts on disk.
///
/// Antigravity stores each conversation at
/// `<app_data_dir>/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`, where
/// `<app_data_dir>` is `~/.gemini/antigravity` for the app/IDE and `~/.gemini/antigravity-cli` for
/// the CLI — both are scanned. Unlike Claude Code and Cursor there is no per-project directory
/// encoding: the conversation id is an opaque UUID, so the workspace is recovered from the
/// transcript's own tool-call arguments (`firstCwd`).
public enum AntigravitySessions {

    /// The `brain/` conversation roots for every Antigravity variant on this machine.
    public static var brainDirectories: [URL] {
        let gemini = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini", isDirectory: true)
        return ["antigravity", "antigravity-cli"].map {
            gemini.appendingPathComponent($0, isDirectory: true).appendingPathComponent("brain", isDirectory: true)
        }
    }

    public struct Transcript: Sendable, Hashable {
        public let sessionId: String
        public let url: URL
        public let modifiedAt: Date
    }

    /// The transcript inside one conversation directory. Prefers the untruncated
    /// `transcript_full.jsonl` (verified: live hooks in CLI 1.1.3 hand that path out;
    /// `transcript.jsonl` is the checkpoint-truncated variant of the same format), falling back to
    /// `transcript.jsonl` for conversations that only have the truncated file.
    public static func transcriptURL(inConversationDir dir: URL) -> URL {
        let logs = dir.appendingPathComponent(".system_generated", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        let full = logs.appendingPathComponent("transcript_full.jsonl")
        if FileManager.default.fileExists(atPath: full.path) { return full }
        return logs.appendingPathComponent("transcript.jsonl")
    }

    /// Every conversation transcript on disk, across all Antigravity variants, oldest first.
    public static func allTranscripts() -> [Transcript] {
        allTranscripts(in: brainDirectories)
    }

    /// Testable core of `allTranscripts` — scan explicit `brain/` roots.
    static func allTranscripts(in roots: [URL]) -> [Transcript] {
        let fm = FileManager.default
        var out: [Transcript] = []
        for root in roots {
            guard let conversationDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for dir in conversationDirs {
                let file = transcriptURL(inConversationDir: dir)
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                out.append(Transcript(
                    sessionId: dir.lastPathComponent, url: file,
                    modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                ))
            }
        }
        return out.sorted { $0.modifiedAt < $1.modifiedAt }
    }

    /// All transcripts whose workspace is the repo (or a subdirectory of it), oldest first. The
    /// workspace comes from each transcript's own tool-call args, so a conversation that never
    /// touched a directory-carrying tool can't be attributed and is skipped.
    public static func transcripts(forRepoPath repoPath: String) -> [Transcript] {
        let canonRepo = CanonicalPath.resolve(repoPath)
        return allTranscripts().filter { transcript in
            guard let cwd = firstCwd(of: transcript.url).map({ CanonicalPath.resolve($0) }) else { return false }
            return cwd == canonRepo || cwd.hasPrefix(canonRepo + "/")
        }
    }

    /// The workspace directory a conversation ran in, recovered from the first tool call that
    /// carries a directory argument (`run_command`'s `Cwd`, `list_dir`'s `DirectoryPath`, …).
    /// Antigravity transcript lines carry no `cwd` field of their own.
    public static func firstCwd(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 400_000)) ?? Data()
        let directoryKeys = ["Cwd", "DirectoryPath", "SearchDirectory", "SearchPath"]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let toolCalls = object["tool_calls"] as? [[String: Any]] else { continue }
            for call in toolCalls {
                guard let args = call["args"] as? [String: Any] else { continue }
                for key in directoryKeys {
                    if let raw = args[key] as? String {
                        let value = TranscriptParser.unquoteAntigravityArg(raw)
                        if value.hasPrefix("/") { return value }
                    }
                }
            }
        }
        return nil
    }
}
