import SwiftUI
import AppKit
import ServiceManagement
import HypermnesiaKit

// MARK: - Model

@MainActor
@Observable
final class SettingsModel {
    enum MCPServerState: Equatable {
        case checking
        case missingClaudeCLI
        case notRegistered
        case registeredDisconnected
        case connected
        case error
    }

    var config: AppConfig { didSet { AppConfigStore.save(config) } }
    var hooksInstalled: Bool
    var recallGuideInstalled: Bool
    var recallPermissionsInstalled: Bool
    var mcpServerState: MCPServerState = .checking
    var cursorHooksInstalled: Bool
    var cursorMCPInstalled: Bool
    var antigravityHooksInstalled: Bool
    var antigravityMCPInstalled: Bool
    var statusMessage: String?

    var recallPathInstalled: Bool { recallGuideInstalled && recallPermissionsInstalled }
    var mcpServerRegistered: Bool {
        switch mcpServerState {
        case .connected, .registeredDisconnected: true
        default: false
        }
    }
    var coreSetupComplete: Bool { hooksInstalled }
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
        case .connected: "Registered and connected"
        case .error: "Could not read MCP server list"
        }
    }

    init() {
        config = AppConfigStore.load()
        hooksInstalled = HookInstaller.isInstalled()
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
        let found = Shell.run(shell, ["-lc", "command -v \(name)"]).stdout
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

    /// Resolve the `hypermnesia` CLI so the hooks can call it (login shell, then known locations).
    private func resolveCLIPath() -> String? {
        Self.resolveCommandPath("hypermnesia", fallbacks: [
            "~/.local/bin/hypermnesia",
            "~/hypermnesia/.build/debug/hypermnesia"
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
        guard let cli = resolveCLIPath() else {
            statusMessage = "Couldn't find the hypermnesia CLI binary to register."
            return
        }
        guard let claudeCLI = Self.resolveClaudeCLIPath() else {
            mcpServerState = .missingClaudeCLI
            statusMessage = "Couldn't find `claude` CLI on your login PATH."
            return
        }
        mcpServerState = .checking
        Task { [weak self] in
            let add = await Task.detached {
                Shell.run(claudeCLI, ["mcp", "add", "hypermnesia", "-s", "user", "--", cli, "mcp"], timeout: 25)
            }.value
            let state = await Task.detached {
                Self.detectMCPServerState(claudeCLI: claudeCLI)
            }.value
            guard let self else { return }
            self.mcpServerState = state
            if state == .connected || state == .registeredDisconnected {
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
        recallGuideInstalled = MemoryGuideInstaller.isInstalled()
        recallPermissionsInstalled = PermissionInstaller.isInstalled()
        cursorHooksInstalled = CursorHookInstaller.isInstalled()
        cursorMCPInstalled = CursorMCPInstaller.isInstalled()
        antigravityHooksInstalled = AntigravityHookInstaller.isInstalled()
        antigravityMCPInstalled = AntigravityMCPInstaller.isInstalled()
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        refreshMCPServerStatus()
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
            let state = await Task.detached { Self.detectMCPServerState() }.value
            self?.mcpServerState = state
        }
    }

    nonisolated private static func detectMCPServerState() -> MCPServerState {
        guard let claudeCLI = resolveClaudeCLIPath() else { return .missingClaudeCLI }
        return detectMCPServerState(claudeCLI: claudeCLI)
    }

    nonisolated private static func detectMCPServerState(claudeCLI: String) -> MCPServerState {
        let list = Shell.run(claudeCLI, ["mcp", "list"], timeout: 20)
        guard list.succeeded else { return .error }
        let output = list.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return .notRegistered }
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let line = lines.first(where: { $0.hasPrefix("hypermnesia:") }) else {
            return .notRegistered
        }
        return line.contains("✔ Connected") ? .connected : .registeredDisconnected
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

// MARK: - Settings window

enum SettingsSection: String, CaseIterable, Identifiable {
    case onboarding, cursor, antigravity, classifier, capture, hydration, storage, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .onboarding: "Onboarding"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        case .classifier: "Classifier"
        case .capture: "Capture"
        case .hydration: "Hydration"
        case .storage: "Storage"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .onboarding: "checklist"
        case .cursor: "cursorarrow.rays"
        case .antigravity: "balloon"
        case .classifier: "brain.head.profile"
        case .capture: "dot.radiowaves.left.and.right"
        case .hydration: "drop.fill"
        case .storage: "externaldrive"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    private static let hasOpenedSettingsKey = "Hypermnesia.hasOpenedSettings"

    @State private var model = SettingsModel()
    // First open lands on the Onboarding checklist; after that, Classifier (the most-edited section).
    @State private var section: SettingsSection? = {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: SettingsView.hasOpenedSettingsKey) { return .classifier }
        defaults.set(true, forKey: SettingsView.hasOpenedSettingsKey)
        return .onboarding
    }()

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(SettingsSection.allCases) { item in
                    let selected = section == item
                    Button { section = item } label: {
                        Label(item.title, systemImage: item.symbol)
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .foregroundStyle(selected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    .listRowBackground(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.brand : .clear))
                }
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch section ?? .classifier {
                    case .onboarding: OnboardingSettings(model: model)
                    case .cursor: CursorSettings(model: model)
                    case .antigravity: AntigravitySettings(model: model)
                    case .classifier: ClassifierSettings(model: model)
                    case .capture: CaptureSettings(model: model)
                    case .hydration: HydrationSettings(model: model)
                    case .storage: StorageSettings()
                    case .about: AboutSettings(model: model)
                    }
                    if let status = model.statusMessage {
                        Label(status, systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 760, height: 560)
        .task { model.refreshSetupStatus() }
    }
}

// MARK: - Sections

private struct SectionHeader: View {
    let title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.bold())
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct OnboardingSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SectionHeader(
            title: "Onboarding checklist",
            subtitle: "Hooks are the core setup. MCP recall path is optional."
        )

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                setupRow(
                    title: "Capture hooks",
                    detail: model.hooksInstalled
                        ? "Installed (SessionStart, UserPromptSubmit, Stop, SessionEnd)."
                        : "Not installed — memory won't auto-capture from Claude sessions.",
                    done: model.hooksInstalled,
                    actionTitle: "Install",
                    optional: false
                ) { model.setHooks(true) }

                setupRow(
                    title: "Launch at login",
                    detail: model.canManageLoginItem
                        ? (model.launchAtLoginEnabled
                            ? "Hypermnesia starts with your Mac — the draft badge, notifications, and daily maintenance stay live."
                            : "Off — hooks still capture, but the badge, notifications, and daily maintenance only run while the app is open.")
                        : "Available when running the installed Hypermnesia.app (not a bare dev build).",
                    done: model.launchAtLoginEnabled,
                    actionTitle: model.canManageLoginItem ? "Enable" : nil,
                    optional: true
                ) { model.setLaunchAtLogin(true) }

                Divider()
                HStack(spacing: 6) {
                    Text("Optional MCP recall path")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Optional enhancement: hooks already provide baseline memory capture + injection. Enable MCP recall when you also want explicit, on-demand pull memory (`recall`) in agent workflows.")
                }

                setupRow(
                    title: "MCP server registration",
                    detail: model.mcpServerStatusText,
                    done: model.mcpServerRegistered,
                    actionTitle: model.mcpServerState == .missingClaudeCLI ? nil : "Register",
                    optional: true
                ) { model.registerMCPServer() }

                setupRow(
                    title: "Recall permissions (read-only tools)",
                    detail: model.recallPermissionsInstalled
                        ? "Pre-approved: mcp__hypermnesia__recall, mcp__hypermnesia__ask."
                        : "Not pre-approved — first recall/ask calls may prompt each session.",
                    done: model.recallPermissionsInstalled,
                    actionTitle: "Allow tools",
                    optional: true
                ) { model.installRecallPermissionsOnly() }

                setupRow(
                    title: "Recall guide in CLAUDE.md",
                    detail: model.recallGuideInstalled
                        ? "Installed — agents are instructed to call recall before editing."
                        : "Missing — agents may skip memory recall on the MCP path.",
                    done: model.recallGuideInstalled,
                    actionTitle: "Install guide",
                    optional: true
                ) { model.installMemoryGuideOnly() }
            }
            .padding(6)
        }

        HStack(spacing: 10) {
            Label(
                model.onboardingComplete ? "Core setup complete" : "Core setup incomplete",
                systemImage: model.onboardingComplete ? "checkmark.seal.fill" : "exclamationmark.triangle"
            )
            .foregroundStyle(model.onboardingComplete ? .positive : .caution)
            if model.onboardingComplete && !model.mcpEnhancementComplete {
                Text("MCP recall is optional.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Refresh status") { model.refreshSetupStatus() }
                .controlSize(.small)
            Spacer()
        }
        .font(.callout)
    }

    @ViewBuilder
    private func setupRow(
        title: String,
        detail: String,
        done: Bool,
        actionTitle: String?,
        optional: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : (optional ? "circle.dashed" : "circle"))
                .foregroundStyle(done ? Color.positive : Color.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.semibold))
                    if optional {
                        Text("Optional")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !done, let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

private struct CursorSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SectionHeader(
            title: "Cursor",
            subtitle: "Use the same local memory in Cursor — capture its sessions and let its agent recall."
        )

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { model.cursorHooksInstalled },
                    set: { model.setCursorHooks($0) }
                )) {
                    Text("Capture + inject in Cursor (hooks)")
                    Text("Installs ~/.cursor/hooks.json · sessionStart → inject memory, stop / sessionEnd → capture + drain")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Toggle(isOn: Binding(
                    get: { model.cursorMCPInstalled },
                    set: { model.setCursorMCP($0) }
                )) {
                    Text("Let Cursor pull memory on demand (MCP)")
                    Text("Registers the hypermnesia server in ~/.cursor/mcp.json (recall / ask / remember).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }

        VStack(alignment: .leading, spacing: 4) {
            Label("Cursor approves MCP tools in its own UI — accept recall / ask / remember when first prompted.",
                  systemImage: "info.circle")
            Label("Hydration in Cursor is session-start only (Cursor has no per-prompt context hook).",
                  systemImage: "info.circle")
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

private struct AntigravitySettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SectionHeader(
            title: "Antigravity",
            subtitle: "Use the same local memory in Google Antigravity — capture its conversations and let its agent recall."
        )

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { model.antigravityHooksInstalled },
                    set: { model.setAntigravityHooks($0) }
                )) {
                    Text("Capture + inject in Antigravity (hooks)")
                    Text("Installs ~/.gemini/config/hooks.json · PreInvocation → inject memory at conversation start, Stop → capture + drain")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Toggle(isOn: Binding(
                    get: { model.antigravityMCPInstalled },
                    set: { model.setAntigravityMCP($0) }
                )) {
                    Text("Let Antigravity pull memory on demand (MCP)")
                    Text("Registers the hypermnesia server in ~/.gemini/config/mcp_config.json (recall / ask / remember).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }

        VStack(alignment: .leading, spacing: 4) {
            Label("Antigravity approves MCP tools in its own UI — accept recall / ask / remember when first prompted.",
                  systemImage: "info.circle")
            Label("Injection is conversation-start only (Antigravity has no per-prompt context hook).",
                  systemImage: "info.circle")
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

private struct ClassifierSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SectionHeader(title: "Classifier", subtitle: "How sessions are turned into memories.")

        Picker("Engine", selection: $model.config.classifier) {
            Text("Automatic").tag("auto")
            Text("Gemini").tag("gemini")
            Text("Claude (claude -p)").tag("claude")
        }
        .pickerStyle(.segmented)

        Text(model.config.classifier == "auto"
             ? "Automatic uses Gemini when a key is available, otherwise Claude headless."
             : " ")
            .font(.caption).foregroundStyle(.secondary)

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Gemini API key").frame(width: 130, alignment: .leading)
                    SecureField("paste key, or leave blank to use $GEMINI_API_KEY", text: Binding(
                        get: { model.config.geminiApiKey ?? "" },
                        set: { model.config.geminiApiKey = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    HStack(spacing: 4) {
                        Circle().fill(model.hasGeminiKey ? .green : .secondary).frame(width: 7, height: 7)
                        Text(model.hasGeminiKey ? "Connected" : "No key").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Test") { model.testConnection() }.disabled(!model.hasGeminiKey)
                }
                Text("Source: \(model.geminiKeySource)").font(.caption2).foregroundStyle(.tertiary)
                Divider()
                HStack {
                    Text("Gemini model").frame(width: 130, alignment: .leading)
                    TextField("gemini-3.5-flash", text: $model.config.geminiModel).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Claude model").frame(width: 130, alignment: .leading)
                    TextField("claude-haiku-4-5-20251001", text: $model.config.claudeModel).textFieldStyle(.roundedBorder)
                }
            }
            .padding(6)
        }
    }
}

private struct CaptureSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SectionHeader(title: "Capture", subtitle: "Build memory from your coding sessions automatically.")

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { model.hooksInstalled },
                    set: { model.setHooks($0) }
                )) {
                    Text("Capture sessions automatically")
                    Text("Installs hooks for all projects · SessionStart, UserPromptSubmit, Stop, SessionEnd")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Capture sensitivity").font(.callout)
                    HStack {
                        Text("Eager").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { Double(model.config.captureThreshold) },
                            set: { model.config.captureThreshold = Int($0) }
                        ), in: 2...16, step: 1)
                        Text("Conservative").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Capture after \(model.config.captureThreshold) new exchanges in a session.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Divider()
                Toggle(isOn: $model.config.autoConfirmConfidentCaptures) {
                    Text("Auto-confirm confident captures")
                    Text("High-confidence captures go live immediately. Revisions that would retire an existing memory, weak captures, and agent `remember` writes always wait for your review.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Stepper(model.config.autoConfirmAfterSightings == 0
                        ? "Auto-confirm drafts: off"
                        : "Auto-confirm after \(model.config.autoConfirmAfterSightings) repeat sighting(s)",
                        value: $model.config.autoConfirmAfterSightings, in: 0...5)
                Text("A draft seen again in this many later sessions is confirmed automatically (0 = never).")
                    .font(.caption2).foregroundStyle(.tertiary)
                Divider()
                Toggle(isOn: $model.config.notifyOnNewDrafts) {
                    Text("Notify when new drafts arrive")
                    Text("One macOS notification per capture pass — the menu-bar badge stays on either way.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }
}

private struct HydrationSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SectionHeader(title: "Hydration", subtitle: "Inject relevant memories back into your sessions.")

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Inject project memory at session start", isOn: $model.config.injectAtSessionStart)
                Toggle("Inject relevant memories per prompt", isOn: $model.config.injectPerPrompt)
                Toggle(isOn: $model.config.injectMomentum) {
                    Text("Carry session momentum")
                    Text("Starts the next session with a short note on where the last one left off (kept 7 days).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Stepper("Max memories injected: \(model.config.maxMemoriesInjected)",
                        value: $model.config.maxMemoriesInjected, in: 5...100, step: 5)
                Divider()
                Toggle(isOn: Binding(
                    get: { model.recallPathInstalled },
                    set: { model.setRecallPath($0) }
                )) {
                    Text("Let the agent pull memory on demand (MCP recall)")
                    Text("Adds a CLAUDE.md instruction to call recall before editing + pre-approves the read-only recall/ask tools.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.recallPathInstalled { MCPServerNudge() }
            }
            .padding(6)
        }
        Text("Only confirmed, non-stale memories are injected.").font(.caption).foregroundStyle(.secondary)
    }
}

/// Shown after the recall (MCP) path is enabled: the one step the app can't do itself — registering
/// the stdio MCP server with Claude Code — with a copy button.
private struct MCPServerNudge: View {
    private let command = "claude mcp add hypermnesia -s user -- hypermnesia mcp"
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("One manual step — register the MCP server so `recall` exists:", systemImage: "terminal")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
        }
        .padding(.leading, 4)
    }
}

private struct StorageSettings: View {
    private var dbURL: URL { StoreLocation.supportDirectory.appendingPathComponent("memory.db") }
    @State private var memoryCount = 0
    @State private var projectCount = 0

    var body: some View {
        SectionHeader(title: "Storage", subtitle: "Everything is stored locally on this Mac.")
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                row("Database", dbURL.path)
                row("Projects", "\(projectCount)")
                row("Memories", "\(memoryCount)")
                Divider()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([dbURL])
                } label: { Label("Reveal in Finder", systemImage: "folder") }
            }
            .padding(6)
        }
        .task {
            if let store = try? MemoryStore() {
                let projects = (try? store.projects()) ?? []
                projectCount = projects.count
                memoryCount = projects.reduce(0) { $0 + ((try? store.nodes(projectId: $1, status: nil, limit: 5000).count) ?? 0) }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }
}

private struct AboutSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SectionHeader(title: "About", subtitle: "Durable, decaying memory for Claude Code, Cursor, and Antigravity.")
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "brain").font(.title); Text("Hypermnesia").font(.title3.bold()) }
                Text("Version \(Hypermnesia.version)").font(.callout).foregroundStyle(.secondary)
                Text("Captures memories from your Claude Code, Cursor, and Google Antigravity sessions, lets them decay over time, and injects the relevant ones back into future sessions — all on-device.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                Toggle(isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                )) {
                    Text("Launch at login")
                    Text("Keeps the menu-bar badge, notifications, and background capture running.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!model.canManageLoginItem)
                if !model.canManageLoginItem {
                    Text("Available when running the installed Hypermnesia.app (not a bare dev build).")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(6)
        }
    }
}
