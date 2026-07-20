import Foundation

/// Local-dev-only screenshot mode: `HYPERMNESIA_HIDE_PROJECTS` hides matching projects from every
/// read surface (sidebar/pickers, notch cards, activity feed, dream journal) without touching the
/// store. Comma-separated, case-insensitive substring match against the raw project id, so
/// `HYPERMNESIA_HIDE_PROJECTS="acme,path:/Users/x/secret"` hides `github.com/acme/app` and the
/// path-based project. Deliberately env-only — never persisted, so a normal launch shows everything.
public enum ProjectVisibility {
    public static let environmentKey = "HYPERMNESIA_HIDE_PROJECTS"

    /// Tokens from the process environment. Read per call: cheap, and keeps tests hermetic via the
    /// token-parameter overloads below rather than mutating global state.
    public static var hiddenTokens: [String] {
        parse(ProcessInfo.processInfo.environment[environmentKey])
    }

    public static func parse(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    public static func isHidden(projectId: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let id = projectId.lowercased()
        return tokens.contains { id.contains($0) }
    }

    public static func isHidden(projectId: String) -> Bool {
        isHidden(projectId: projectId, tokens: hiddenTokens)
    }

    /// Filter any project-tagged rows in one pass; skips work entirely when the env var is unset.
    public static func visible<T>(_ items: [T], projectId: (T) -> String) -> [T] {
        let tokens = hiddenTokens
        guard !tokens.isEmpty else { return items }
        return items.filter { !isHidden(projectId: projectId($0), tokens: tokens) }
    }
}
