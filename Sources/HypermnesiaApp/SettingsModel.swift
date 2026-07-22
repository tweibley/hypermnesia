import SwiftUI
import ServiceManagement
import HypermnesiaKit

/// Settings orchestration: install/uninstall of every client integration (hooks, MCP), setup
/// health, and config persistence. UI lives in `Settings.swift`; this model owns the state.
@MainActor
@Observable
final class SettingsModel {
    enum MCPServerState: Equatable {
        case checking
        case missingClaudeCLI
        case notRegistered
        case registeredDisconnected
        /// Registered in `~/.claude.json`, but the live `claude mcp list` health check failed or
        /// timed out (it probes every configured server, so one slow/wedged server sinks it).
        case registeredUnverified
        case connected
        case error
    }

    var config: AppConfig {
        didSet {
            do {
                try AppConfigStore.save(config)
                configPersistenceError = nil
                // Let live surfaces (the notch status display) react now, not on their next poll.
                NotificationCenter.default.post(name: .hypermnesiaConfigChanged, object: nil)
            } catch {
                configPersistenceError = error.localizedDescription
            }
        }
    }
    var hooksInstalled: Bool
    /// Hooks are recorded in settings.json but point at a binary that no longer exists (the app was
    /// moved / run translocated after install) — capture + hydration are silently dead; offer repair.
    var hooksBinaryMissing = false
    /// Hooks installed by an older version, missing the notch status events — offer re-install.
    var hooksNeedUpdate = false
    var recallGuideInstalled: Bool
    var recallPermissionsInstalled: Bool
    var mcpServerState: MCPServerState = .checking
    var cursorHooksInstalled: Bool
    var cursorMCPInstalled: Bool
    var antigravityHooksInstalled: Bool
    var antigravityMCPInstalled: Bool
    /// Cursor/Antigravity hooks recorded but pointing at a vanished binary (the app was moved after
    /// install) — the same silent capture death as `hooksBinaryMissing`; a reinstall re-points them.
    var cursorHooksBinaryMissing = false
    var antigravityHooksBinaryMissing = false
    var statusMessage: String?
    var configPersistenceError: String?

    enum CLIToolState: Equatable {
        case checking
        /// Symlinked and `hypermnesia` resolves in a login shell — documented commands work.
        case onPATH
        /// Symlinked into ~/.local/bin, but that directory isn't on the user's PATH.
        case linkedNotOnPATH
        /// The user manages their own install (from-source symlink or real file) — leave it be.
        case userManaged
        case notInstalled
        /// No bundled CLI next to this executable (bare SwiftPM dev run) — nothing to link.
        case unavailable
    }
    var cliToolState: CLIToolState = .checking

    var recallPathInstalled: Bool { recallGuideInstalled && recallPermissionsInstalled }
    var mcpServerRegistered: Bool {
        switch mcpServerState {
        case .connected, .registeredDisconnected, .registeredUnverified: true
        default: false
        }
    }
    var coreSetupComplete: Bool { hooksInstalled && !hooksBinaryMissing }
    var mcpEnhancementComplete: Bool {
        recallGuideInstalled && recallPermissionsInstalled && mcpServerRegistered
    }
    var onboardingComplete: Bool {
        coreSetupComplete
    }
    var mcpServerStatusText: String {
        switch mcpServerState {
        case .checking: "Checking registration…"
        case .missingClaudeCLI: "`claude` CLI not found on PATH"
        case .notRegistered: "Not registered"
        case .registeredDisconnected: "Registered, not connected"
        case .registeredUnverified: "Registered — connection check timed out (another MCP server responded slowly)"
        case .connected: "Registered and connected"
        case .error: "Could not read MCP server list"
        }
    }

    init() {
        do {
            config = try AppConfigStore.load()
        } catch {
            config = AppConfig()
            configPersistenceError = error.localizedDescription
        }
        hooksInstalled = HookInstaller.isInstalled()
        hooksBinaryMissing = HookInstaller.hasMissingBinary()
        recallGuideInstalled = MemoryGuideInstaller.isInstalled()
        recallPermissionsInstalled = PermissionInstaller.isInstalled()
        cursorHooksInstalled = CursorHookInstaller.isInstalled()
        cursorMCPInstalled = CursorMCPInstaller.isInstalled()
        antigravityHooksInstalled = AntigravityHookInstaller.isInstalled()
        antigravityMCPInstalled = AntigravityMCPInstaller.isInstalled()
        refreshMCPServerStatus()
    }

    var geminiKeySource: String {
        if let key = config.geminiApiKey, !key.isEmpty { return "Stored in app settings" }
        if (ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?.isEmpty == false) { return "From shell environment" }
        return "Not set"
    }
    var hasGeminiKey: Bool { AppConfigStore.resolvedGeminiKey(config) != nil }

    /// Resolve a CLI binary using login-shell PATH first (Finder-launched apps have a minimal PATH),
    /// then known fallback install locations.
    nonisolated private static func resolveCommandPath(_ name: String, fallbacks: [String]) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Bounded so a wedged login-shell rc file can't hang the resolver (callers still must run
        // this off the MainActor — a `nonisolated` sync function executes on the caller's thread).
        let found = Shell.run(shell, ["-lc", "command -v \(name)"], timeout: 10).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !found.isEmpty, FileManager.default.isExecutableFile(atPath: found) { return found }
        for fallback in fallbacks {
            let expanded = NSString(string: fallback).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return expanded }
        }
        return nil
    }

    nonisolated private static func resolveClaudeCLIPath() -> String? {
        resolveCommandPath("claude", fallbacks: [
            "~/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ])
    }

    /// Resolve the `hypermnesia` CLI so the hooks can call it. Prefer the copy bundled inside this
    /// app so hook installs stay version-matched with the running UI (a stale `~/.local/bin` copy
    /// otherwise wins via PATH and silently drops durability fixes). Fall back to login-shell PATH,
    /// then known install / dev locations.
    private func resolveCLIPath() -> String? { Self.resolveCLIPathStatic() }

    /// `nonisolated` twin of `resolveCLIPath()` so it can run inside `Task.detached` (its login-shell
    /// fallback shells out and must never block the MainActor). Reads only thread-safe globals.
    nonisolated private static func resolveCLIPathStatic() -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("hypermnesia").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return resolveCommandPath("hypermnesia", fallbacks: [
            "~/.local/bin/hypermnesia",
            "~/hypermnesia/.build/debug/hypermnesia",
        ])
    }

    func setHooks(_ install: Bool) {
        guard let cli = resolveCLIPath() else {
            statusMessage = "Couldn't find the hypermnesia CLI. Run `hypermnesia install-hooks` once in Terminal."
            hooksInstalled = HookInstaller.isInstalled()
            return
        }
        do {
            if install { try HookInstaller.install(binaryPath: cli) } else { try HookInstaller.uninstall() }
            hooksInstalled = HookInstaller.isInstalled()
            hooksBinaryMissing = HookInstaller.hasMissingBinary()
            statusMessage = install ? "Hooks installed — new sessions will build memory." : "Hooks removed."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Enable/disable the MCP **pull** path: writes the CLAUDE.md recall instruction + pre-approves the
    /// read-only recall/ask tools (user-global). Independent of hooks.
    func setRecallPath(_ install: Bool) {
        do {
            if install { try RecallPathInstaller.install() } else { try RecallPathInstaller.uninstall() }
            recallGuideInstalled = MemoryGuideInstaller.isInstalled()
            recallPermissionsInstalled = PermissionInstaller.isInstalled()
            statusMessage = install
                ? "Recall guide + recall/ask pre-approval installed."
                : "Recall path removed (guide + tool pre-approval)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func installMemoryGuideOnly() {
        do {
            try MemoryGuideInstaller.install()
            recallGuideInstalled = MemoryGuideInstaller.isInstalled()
            statusMessage = "Installed recall guide in CLAUDE.md."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func installRecallPermissionsOnly() {
        do {
            try PermissionInstaller.install()
            recallPermissionsInstalled = PermissionInstaller.isInstalled()
            statusMessage = "Pre-approved recall/ask permissions."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func registerMCPServer() {
        // Resolve both CLIs off the MainActor: `resolveCLIPath`/`resolveClaudeCLIPath` shell out to a
        // login shell (`claude` is never bundled, so it always spawns), which would otherwise freeze
        // the whole Settings window before any "Checking…" feedback is even drawn.
        let previousState = mcpServerState
        mcpServerState = .checking
        Task { [weak self] in
            let resolved = await Task.detached { () -> (cli: String?, claude: String?) in
                (Self.resolveCLIPathStatic(), Self.resolveClaudeCLIPath())
            }.value
            guard let self else { return }
            guard let cli = resolved.cli else {
                self.mcpServerState = previousState
                self.statusMessage = "Couldn't find the hypermnesia CLI binary to register."
                return
            }
            guard let claudeCLI = resolved.claude else {
                self.mcpServerState = .missingClaudeCLI
                self.statusMessage = "Couldn't find `claude` CLI on your login PATH."
                return
            }
            let add = await Task.detached {
                Shell.run(claudeCLI, ["mcp", "add", "hypermnesia", "-s", "user", "--", cli, "mcp"], timeout: 25)
            }.value
            let state = await Task.detached {
                Self.mcpServerState(health: ClaudeMCPInstaller.health(claudeCLI: claudeCLI))
            }.value
            self.mcpServerState = state
            if state == .connected || state == .registeredDisconnected || state == .registeredUnverified {
                self.statusMessage = "MCP server registered: hypermnesia"
            } else if add.succeeded {
                self.statusMessage = "Registration command succeeded, but server was not found in `claude mcp list`."
            } else {
                let detail = [add.stderr, add.stdout]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "Unknown error"
                self.statusMessage = "Failed to register MCP server: \(detail)"
            }
        }
    }

    /// Install/remove the Cursor capture + hydrate hooks (~/.cursor/hooks.json). Mirrors `setHooks`.
    func setCursorHooks(_ install: Bool) {
        guard let cli = resolveCLIPath() else {
            statusMessage = "Couldn't find the hypermnesia CLI. Run `hypermnesia install-cursor-hooks` once in Terminal."
            cursorHooksInstalled = CursorHookInstaller.isInstalled()
            return
        }
        do {
            if install { try CursorHookInstaller.install(binaryPath: cli) } else { try CursorHookInstaller.uninstall() }
            cursorHooksInstalled = CursorHookInstaller.isInstalled()
            cursorHooksBinaryMissing = CursorHookInstaller.hasMissingBinary()
            statusMessage = install ? "Cursor hooks installed — new Cursor sessions will build memory." : "Cursor hooks removed."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Register/remove the hypermnesia MCP server in Cursor (~/.cursor/mcp.json). Unlike the Claude
    /// path this is a direct file write — no `claude mcp add` shell-out.
    func setCursorMCP(_ install: Bool) {
        guard let cli = resolveCLIPath() else {
            statusMessage = "Couldn't find the hypermnesia CLI binary to register."
            cursorMCPInstalled = CursorMCPInstaller.isInstalled()
            return
        }
        do {
            if install { try CursorMCPInstaller.install(binaryPath: cli) } else { try CursorMCPInstaller.uninstall() }
            cursorMCPInstalled = CursorMCPInstaller.isInstalled()
            statusMessage = install
                ? "Registered hypermnesia in Cursor — approve recall/ask/remember in Cursor when prompted."
                : "Removed hypermnesia MCP server from Cursor."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Install/remove the Antigravity capture + hydrate hooks (~/.gemini/config/hooks.json).
    /// Mirrors `setCursorHooks`.
    func setAntigravityHooks(_ install: Bool) {
        guard let cli = resolveCLIPath() else {
            statusMessage = "Couldn't find the hypermnesia CLI. Run `hypermnesia install-antigravity-hooks` once in Terminal."
            antigravityHooksInstalled = AntigravityHookInstaller.isInstalled()
            return
        }
        do {
            if install { try AntigravityHookInstaller.install(binaryPath: cli) } else { try AntigravityHookInstaller.uninstall() }
            antigravityHooksInstalled = AntigravityHookInstaller.isInstalled()
            antigravityHooksBinaryMissing = AntigravityHookInstaller.hasMissingBinary()
            statusMessage = install
                ? "Antigravity hooks installed — new conversations will build memory."
                : "Antigravity hooks removed."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Register/remove the hypermnesia MCP server in Antigravity (~/.gemini/config/mcp_config.json).
    /// A direct file write, like the Cursor path.
    func setAntigravityMCP(_ install: Bool) {
        guard let cli = resolveCLIPath() else {
            statusMessage = "Couldn't find the hypermnesia CLI binary to register."
            antigravityMCPInstalled = AntigravityMCPInstaller.isInstalled()
            return
        }
        do {
            if install { try AntigravityMCPInstaller.install(binaryPath: cli) } else { try AntigravityMCPInstaller.uninstall() }
            antigravityMCPInstalled = AntigravityMCPInstaller.isInstalled()
            statusMessage = install
                ? "Registered hypermnesia in Antigravity — approve recall/ask/remember when prompted."
                : "Removed hypermnesia MCP server from Antigravity."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshSetupStatus() {
        hooksInstalled = HookInstaller.isInstalled()
        hooksBinaryMissing = HookInstaller.hasMissingBinary()
        recallGuideInstalled = MemoryGuideInstaller.isInstalled()
        recallPermissionsInstalled = PermissionInstaller.isInstalled()
        cursorHooksInstalled = CursorHookInstaller.isInstalled()
        cursorMCPInstalled = CursorMCPInstaller.isInstalled()
        antigravityHooksInstalled = AntigravityHookInstaller.isInstalled()
        antigravityMCPInstalled = AntigravityMCPInstaller.isInstalled()
        cursorHooksBinaryMissing = CursorHookInstaller.hasMissingBinary()
        antigravityHooksBinaryMissing = AntigravityHookInstaller.hasMissingBinary()
        hooksNeedUpdate = HookInstaller.needsReinstall()
            || CursorHookInstaller.needsReinstall()
            || AntigravityHookInstaller.needsReinstall()
            || cursorHooksBinaryMissing
            || antigravityHooksBinaryMissing
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        refreshMCPServerStatus()
        refreshCLIToolStatus()
    }

    /// The CLI bundled inside this .app, or nil for a bare SwiftPM dev run.
    nonisolated private static func bundledCLIPath() -> String? {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("hypermnesia").path,
              FileManager.default.isExecutableFile(atPath: bundled) else { return nil }
        return bundled
    }

    /// Symlink state is a cheap filesystem read, but the PATH check shells out to a login
    /// shell — so the whole probe runs detached, mirroring `refreshMCPServerStatus`.
    private func refreshCLIToolStatus() {
        cliToolState = .checking
        Task { [weak self] in
            let state = await Task.detached { () -> CLIToolState in
                guard let bundled = Self.bundledCLIPath() else { return .unavailable }
                switch CLIToolInstaller.status(bundledPath: bundled) {
                case .userManaged: return .userManaged
                case .notInstalled, .stale: return .notInstalled
                case .current:
                    return CLIToolInstaller.isOnLoginShellPATH() ? .onPATH : .linkedNotOnPATH
                }
            }.value
            self?.cliToolState = state
        }
    }

    /// Symlink the bundled CLI into ~/.local/bin so the documented terminal commands work.
    func installCLITool() {
        guard let bundled = Self.bundledCLIPath() else {
            statusMessage = "No bundled CLI found — dev builds are linked manually (see README)."
            return
        }
        do {
            try CLIToolInstaller.install(bundledPath: bundled)
            statusMessage = "Linked \(CLIToolInstaller.linkURL().path) → bundled CLI."
            refreshCLIToolStatus()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// VS Code-style PATH install: create /usr/local/bin/hypermnesia via a macOS administrator
    /// prompt, for users whose shell PATH lacks ~/.local/bin. The system link points at the
    /// ~/.local/bin link (which the app refreshes each launch), so this only ever prompts once.
    func installCLIToolSystemWide() {
        guard let bundled = Self.bundledCLIPath() else {
            statusMessage = "No bundled CLI found — dev builds are linked manually (see README)."
            return
        }
        statusMessage = "Waiting for administrator approval…"
        Task { [weak self] in
            let failure = await Task.detached { () -> String? in
                do {
                    // The system link chains through the user link — make sure it exists first.
                    try CLIToolInstaller.install(bundledPath: bundled)
                } catch {
                    return error.localizedDescription
                }
                // AppleScript string literal: escape backslashes, then quotes.
                let shellCommand = CLIToolInstaller.systemWideInstallCommand()
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let script = "do shell script \"\(shellCommand)\" with administrator privileges"
                let result = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 180)
                if result.succeeded { return nil }
                // -128 = the user dismissed the password dialog; not an error worth alarming over.
                return result.stderr.contains("-128")
                    ? "Installation canceled."
                    : "Couldn't create \(CLIToolInstaller.systemLinkPath): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }.value
            guard let self else { return }
            self.statusMessage = failure ?? "Installed \(CLIToolInstaller.systemLinkPath) — `hypermnesia` now works in any terminal."
            self.refreshCLIToolStatus()
        }
    }

    /// Re-run every installed client's hook install so old configs pick up the notch status
    /// events (Notification + session-event). Idempotent — merged entries replace ours in place.
    func updateHooksForNotch() {
        if HookInstaller.isInstalled() { setHooks(true) }
        if CursorHookInstaller.isInstalled() { setCursorHooks(true) }
        if AntigravityHookInstaller.isInstalled() { setAntigravityHooks(true) }
        cursorHooksBinaryMissing = CursorHookInstaller.hasMissingBinary()
        antigravityHooksBinaryMissing = AntigravityHookInstaller.hasMissingBinary()
        hooksNeedUpdate = HookInstaller.needsReinstall()
            || CursorHookInstaller.needsReinstall()
            || AntigravityHookInstaller.needsReinstall()
            || cursorHooksBinaryMissing
            || antigravityHooksBinaryMissing
        if !hooksNeedUpdate { statusMessage = "Hooks updated — sessions now report live status." }
    }

    // MARK: - Launch at login

    var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    /// Login items need a real bundle identity; a bare SwiftPM dev run has none.
    var canManageLoginItem: Bool { Bundle.main.bundleIdentifier != nil }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            statusMessage = "Couldn't update the login item: \(error.localizedDescription)"
        }
        // Reflect only the state the service actually reports.
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func refreshMCPServerStatus() {
        mcpServerState = .checking
        Task { [weak self] in
            let state = await Task.detached { () -> MCPServerState in
                guard let claudeCLI = Self.resolveClaudeCLIPath() else { return .missingClaudeCLI }
                return Self.mcpServerState(health: ClaudeMCPInstaller.health(claudeCLI: claudeCLI))
            }.value
            self?.mcpServerState = state
        }
    }

    /// The detection itself (probe + user-scope registration peek) lives in the kit next to
    /// `ClaudeMCPInstaller`; this only maps its health onto view state.
    nonisolated private static func mcpServerState(health: ClaudeMCPInstaller.Health) -> MCPServerState {
        switch health {
        case .connected: .connected
        case .registeredDisconnected: .registeredDisconnected
        case .registeredUnverified: .registeredUnverified
        case .notRegistered: .notRegistered
        case .unreadable: .error
        }
    }

    func testConnection() {
        statusMessage = "Testing…"
        let cfg = config
        Task {
            let result = await Task.detached { () -> String in
                guard let key = AppConfigStore.resolvedGeminiKey(cfg) else { return "No API key available." }
                let probe = Conversation(
                    sessionId: "test", cwd: nil, gitBranch: nil,
                    messages: [ConversationMessage(role: "user", content: "This project uses SQLite.", timestamp: nil)]
                )
                do {
                    _ = try await GeminiClassifier(apiKey: key, model: cfg.geminiModel).classify(probe, recentMemories: [])
                    return "Connected ✓"
                } catch {
                    return "Failed: \(error.localizedDescription)"
                }
            }.value
            self.statusMessage = result
        }
    }
}
