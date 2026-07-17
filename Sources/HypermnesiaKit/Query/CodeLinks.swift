import Foundation

/// Builds navigable destinations for a memory's code provenance — a local file URL when the repo
/// exists on this machine, and a GitHub permalink pinned to the memory's commit when the project id
/// names a github.com repo. Pure URL construction, so the app surfaces stay thin and testable.
public enum CodeLinks {

    /// `github.com/{owner}/{repo}` → ("owner/repo"); nil for path-based or non-GitHub ids.
    public static func githubRepo(projectId: String) -> String? {
        guard projectId.hasPrefix("github.com/") else { return nil }
        let rest = projectId.dropFirst("github.com/".count)
        let parts = rest.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// Permalink to a file at the memory's provenance ref. Prefers the pinned commit (immutable),
    /// falls back to the branch, then the default branch — the design's original resolution order.
    public static func githubFileURL(
        projectId: String, path: String, commitSha: String? = nil, branch: String? = nil, range: String? = nil
    ) -> URL? {
        guard let repo = githubRepo(projectId: projectId), !path.isEmpty else { return nil }
        let ref = (commitSha?.isEmpty == false ? commitSha! : nil)
            ?? (branch?.isEmpty == false ? branch! : nil)
            ?? "main"
        var link = "https://github.com/\(repo)/blob/\(ref)/\(escapePath(path))"
        if let fragment = lineFragment(range) { link += "#\(fragment)" }
        return URL(string: link)
    }

    /// Permalink to the capture commit itself.
    public static func githubCommitURL(projectId: String, commitSha: String?) -> URL? {
        guard let repo = githubRepo(projectId: projectId),
              let sha = commitSha, !sha.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repo)/commit/\(sha)")
    }

    /// The file on disk, when the project's repo root is known and the file still exists.
    public static func localFileURL(repoPath: String?, path: String) -> URL? {
        guard let repoPath, !repoPath.isEmpty, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: repoPath).appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// "L10-L20" / "10-20" / "L7" → GitHub's "#L10-L20" fragment form; nil when unparseable.
    static func lineFragment(_ range: String?) -> String? {
        guard let range, !range.isEmpty else { return nil }
        let numbers = range.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        switch numbers.count {
        case 1: return "L\(numbers[0])"
        case 2...: return "L\(numbers[0])-L\(numbers[1])"
        default: return nil
        }
    }

    private static func escapePath(_ path: String) -> String {
        path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }
}
