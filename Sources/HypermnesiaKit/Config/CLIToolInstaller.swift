import Foundation

/// Puts the `hypermnesia` terminal command on the user's PATH by symlinking the CLI bundled
/// inside the .app (`Contents/Resources/hypermnesia`) into `~/.local/bin`.
///
/// A downloaded install has no other route to a working terminal command: the site and README
/// say "run `hypermnesia install-…`", but the binary lives inside the app bundle where no shell
/// can find it. The app refreshes this symlink on every launch, which also keeps terminal
/// installs version-matched with the running UI and heals the link after the app is moved.
public enum CLIToolInstaller {
    public enum Status: Equatable {
        /// Symlink present and pointing at the given bundled binary.
        case current
        /// Symlink broken or pointing into a different (old/moved) app bundle — safe to refresh.
        case stale
        /// A regular file, or a working symlink to something outside an app bundle (e.g. the
        /// from-source `.build/debug` link the README describes) — deliberate, never touched.
        case userManaged
        case notInstalled
    }

    public static func defaultBinDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin", isDirectory: true)
    }

    public static func linkURL(binDirectory: URL? = nil) -> URL {
        (binDirectory ?? defaultBinDirectory()).appendingPathComponent("hypermnesia")
    }

    public static func status(bundledPath: String, binDirectory: URL? = nil) -> Status {
        let link = linkURL(binDirectory: binDirectory)
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else {
            // Not a symlink: either absent, or a regular file someone put there themselves.
            return fm.fileExists(atPath: link.path) ? .userManaged : .notInstalled
        }
        let resolved = URL(fileURLWithPath: dest, relativeTo: link.deletingLastPathComponent())
            .standardizedFileURL.path
        if resolved == URL(fileURLWithPath: bundledPath).standardizedFileURL.path { return .current }
        if !fm.isExecutableFile(atPath: resolved) { return .stale }
        return resolved.contains(".app/Contents/") ? .stale : .userManaged
    }

    /// Create or refresh the symlink. No-op when already current; refuses to clobber a
    /// user-managed file or link. Returns the resulting status.
    @discardableResult
    public static func install(bundledPath: String, binDirectory: URL? = nil) throws -> Status {
        switch status(bundledPath: bundledPath, binDirectory: binDirectory) {
        case .current: return .current
        case .userManaged: return .userManaged
        case .stale, .notInstalled: break
        }
        let link = linkURL(binDirectory: binDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: bundledPath)
        return .current
    }

    /// Remove the symlink — but only one that points into an app bundle (i.e. one we made).
    public static func uninstall(binDirectory: URL? = nil) throws {
        let link = linkURL(binDirectory: binDirectory)
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return }
        let resolved = URL(fileURLWithPath: dest, relativeTo: link.deletingLastPathComponent())
            .standardizedFileURL.path
        guard resolved.contains(".app/Contents/") || !FileManager.default.fileExists(atPath: resolved) else { return }
        try FileManager.default.removeItem(at: link)
    }

    // MARK: - System-wide install (/usr/local/bin, VS Code style)

    /// Fallback for users whose PATH lacks `~/.local/bin`: a link in `/usr/local/bin`, which is
    /// on every macOS default PATH. Creating it needs admin rights, so the app runs
    /// `systemWideInstallCommand()` through an osascript administrator prompt.
    public static let systemLinkPath = "/usr/local/bin/hypermnesia"

    /// The shell command a privileged runner executes. Deliberately links to the `~/.local/bin`
    /// link rather than the bundle: the app refreshes that user link on every launch without
    /// privileges, so the root-owned system link survives app updates and moves without ever
    /// prompting again.
    public static func systemWideInstallCommand(binDirectory: URL? = nil) -> String {
        let target = ConfigFile.shellQuote(linkURL(binDirectory: binDirectory).path)
        return "mkdir -p /usr/local/bin && ln -sf \(target) \(ConfigFile.shellQuote(systemLinkPath))"
    }

    /// Whether `/usr/local/bin/hypermnesia` exists and resolves to something executable
    /// (`isExecutableFile` follows the whole symlink chain).
    public static func systemLinkWorks() -> Bool {
        FileManager.default.isExecutableFile(atPath: systemLinkPath)
    }

    /// Whether `hypermnesia` actually resolves in the user's login shell — the symlink only
    /// helps if `~/.local/bin` is on PATH. Shells out; never call on the MainActor.
    public static func isOnLoginShellPATH() -> Bool {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let found = Shell.run(shell, ["-lc", "command -v hypermnesia"], timeout: 10).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !found.isEmpty
    }
}
