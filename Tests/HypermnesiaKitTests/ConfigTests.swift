import Foundation
import Testing
@testable import HypermnesiaKit

@Suite("Config")
struct ConfigTests {

    @Test("AppConfig round-trips and decodes leniently")
    func appConfig() throws {
        var config = AppConfig()
        config.classifier = "gemini"
        config.geminiApiKey = "secret"
        config.maxMemoriesInjected = 12
        config.injectPerPrompt = false
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(AppConfig.self, from: data) == config)

        // Missing fields fall back to defaults.
        let partial = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"classifier":"claude"}"#.utf8))
        #expect(partial.classifier == "claude")
        #expect(partial.maxMemoriesInjected == 40)
        #expect(partial.injectAtSessionStart == true)
    }

    @Test("HookInstaller installs all five events, preserves other settings, and uninstalls cleanly")
    func hookInstaller() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-existing setting that must survive.
        let settingsURL = HookInstaller.settingsURL(projectPath: dir.path)
        try Data(#"{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}"#.utf8)
            .write(to: settingsURL)

        #expect(!HookInstaller.isInstalled(projectPath: dir.path))
        try HookInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        #expect(HookInstaller.isInstalled(projectPath: dir.path))
        #expect(!HookInstaller.needsReinstall(projectPath: dir.path))

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        #expect(json["theme"] as? String == "dark")  // preserved
        let hooks = json["hooks"] as! [String: Any]
        #expect(Set(hooks.keys)
            == ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd", "Notification"])
        // The pre-existing Stop hook is kept alongside ours; ours carries the capture chain AND
        // the notch status emitter as separate commands (each needs its own stdin copy).
        let stop = hooks["Stop"] as! [[String: Any]]
        #expect(stop.count == 2)
        let ourStopCommands = (stop.last?["hooks"] as! [[String: Any]]).compactMap { $0["command"] as? String }
        #expect(ourStopCommands.count == 2)
        #expect(ourStopCommands.first?.contains("capture") == true)
        #expect(ourStopCommands.last?.contains("session-event") == true)
        let notification = hooks["Notification"] as! [[String: Any]]
        #expect((notification.first?["hooks"] as! [[String: Any]]).first?["command"] as? String
            == "'/usr/local/bin/hypermnesia' session-event")
        // UserPromptSubmit both hydrates and stamps the turn start; PostToolUse is the heartbeat.
        let prompt = hooks["UserPromptSubmit"] as! [[String: Any]]
        let promptCommands = (prompt.first?["hooks"] as! [[String: Any]]).compactMap { $0["command"] as? String }
        #expect(promptCommands.map { $0.contains("hydrate") } == [true, false])
        #expect(promptCommands.last?.contains("session-event") == true)
        let postTool = hooks["PostToolUse"] as! [[String: Any]]
        #expect((postTool.first?["hooks"] as! [[String: Any]]).first?["command"] as? String
            == "'/usr/local/bin/hypermnesia' session-event")

        try HookInstaller.uninstall(projectPath: dir.path)
        #expect(!HookInstaller.isInstalled(projectPath: dir.path))
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        #expect((after["hooks"] as! [String: Any])["Stop"] != nil)  // other Stop hook survives uninstall
        #expect((after["hooks"] as! [String: Any])["Notification"] == nil)
        #expect(after["theme"] as? String == "dark")
    }

    @Test("needsReinstall flags hook configs that predate the notch status events")
    func hookInstallerNeedsReinstall() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-hooks-old-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A pre-notch install: hooks present, but no Notification event and no session-event command.
        let legacy = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/usr/local/bin/hypermnesia' capture"}]}]}}"#
        try Data(legacy.utf8).write(to: HookInstaller.settingsURL(projectPath: dir.path))
        #expect(HookInstaller.isInstalled(projectPath: dir.path))
        #expect(HookInstaller.needsReinstall(projectPath: dir.path))

        // A notch-v1 install (session-event on Stop/Notification, but no PostToolUse heartbeat or
        // UserPromptSubmit turn-start) also predates the working state.
        let v1 = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/usr/local/bin/hypermnesia' capture"},{"type":"command","command":"'/usr/local/bin/hypermnesia' session-event"}]}],"Notification":[{"hooks":[{"type":"command","command":"'/usr/local/bin/hypermnesia' session-event"}]}]}}"#
        try Data(v1.utf8).write(to: HookInstaller.settingsURL(projectPath: dir.path))
        #expect(HookInstaller.needsReinstall(projectPath: dir.path))

        // Re-install upgrades in place.
        try HookInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        #expect(!HookInstaller.needsReinstall(projectPath: dir.path))

        // No hooks at all is "not installed", not "needs update".
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("ht-hooks-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(!HookInstaller.needsReinstall(projectPath: empty.path))
    }

    @Test("Installers refuse to overwrite an unparseable settings file instead of clobbering it")
    func installersRefuseCorruptSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A hand-edited file with a JSONC-style comment — readable by a human, not by JSONSerialization.
        let corrupt = "// my settings\n{\"hooks\": {\"Stop\": []}}"
        let claudeURL = HookInstaller.settingsURL(projectPath: dir.path)
        try Data(corrupt.utf8).write(to: claudeURL)
        let cursorURL = CursorHookInstaller.settingsURL(projectPath: dir.path)
        try Data(corrupt.utf8).write(to: cursorURL)
        let mcpURL = CursorMCPInstaller.configURL(projectPath: dir.path)
        try Data(corrupt.utf8).write(to: mcpURL)
        let antigravityHooksURL = AntigravityHookInstaller.settingsURL(projectPath: dir.path)
        try Data(corrupt.utf8).write(to: antigravityHooksURL)
        let antigravityMCPURL = AntigravityMCPInstaller.configURL(projectPath: dir.path)
        try Data(corrupt.utf8).write(to: antigravityMCPURL)

        #expect(throws: ConfigFile.UnreadableError.self) {
            try HookInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        }
        #expect(throws: ConfigFile.UnreadableError.self) {
            try PermissionInstaller.install(projectPath: dir.path)
        }
        #expect(throws: ConfigFile.UnreadableError.self) {
            try CursorHookInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        }
        #expect(throws: ConfigFile.UnreadableError.self) {
            try CursorMCPInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        }
        #expect(throws: ConfigFile.UnreadableError.self) {
            try AntigravityHookInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        }
        #expect(throws: ConfigFile.UnreadableError.self) {
            try AntigravityMCPInstaller.install(binaryPath: "/usr/local/bin/hypermnesia", projectPath: dir.path)
        }

        // The user's file is untouched — never replaced with just our keys.
        #expect(try String(contentsOf: claudeURL, encoding: .utf8) == corrupt)
        #expect(try String(contentsOf: cursorURL, encoding: .utf8) == corrupt)
        #expect(try String(contentsOf: mcpURL, encoding: .utf8) == corrupt)
        #expect(try String(contentsOf: antigravityHooksURL, encoding: .utf8) == corrupt)
        #expect(try String(contentsOf: antigravityMCPURL, encoding: .utf8) == corrupt)
    }

    @Test("Hook commands quote the binary path so spaces survive the shell")
    func hookCommandQuoting() throws {
        let settings = HookInstaller.merged(into: [:], binaryPath: "/Users/Jane Smith/.local/bin/hypermnesia")
        let hooks = settings["hooks"] as! [String: Any]
        let entry = (hooks["SessionStart"] as! [[String: Any]]).first!
        let command = ((entry["hooks"] as! [[String: Any]]).first!["command"] as! String)
        #expect(command == "'/Users/Jane Smith/.local/bin/hypermnesia' hydrate")

        let cursor = CursorHookInstaller.merged(into: [:], binaryPath: "/Users/Jane Smith/.local/bin/hypermnesia")
        let cursorHooks = cursor["hooks"] as! [String: Any]
        let cursorCmd = (cursorHooks["sessionStart"] as! [[String: Any]]).first!["command"] as! String
        #expect(cursorCmd == "'/Users/Jane Smith/.local/bin/hypermnesia' hydrate --client cursor")

        let antigravity = AntigravityHookInstaller.merged(into: [:], binaryPath: "/Users/Jane Smith/.local/bin/hypermnesia")
        let antigravityHook = antigravity["hypermnesia"] as! [String: Any]
        let antigravityCmd = (antigravityHook["PreInvocation"] as! [[String: Any]]).first!["command"] as! String
        #expect(antigravityCmd == "'/Users/Jane Smith/.local/bin/hypermnesia' hydrate --client antigravity")
    }

    @Test("PermissionInstaller pre-approves only the read-only tools, idempotently, preserving existing rules")
    func permissionInstaller() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-perms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-existing user rule + theme that must survive.
        let url = PermissionInstaller.settingsURL(projectPath: dir.path)
        try Data(#"{"theme":"dark","permissions":{"allow":["Bash(ls:*)"],"deny":["Bash(rm:*)"]}}"#.utf8).write(to: url)

        #expect(!PermissionInstaller.isInstalled(projectPath: dir.path))
        #expect(PermissionInstaller.missing(projectPath: dir.path) == PermissionInstaller.readOnlyTools)

        try PermissionInstaller.install(projectPath: dir.path)
        #expect(PermissionInstaller.isInstalled(projectPath: dir.path))
        #expect(PermissionInstaller.missing(projectPath: dir.path).isEmpty)

        // remember is NOT pre-approved — it writes.
        #expect(!PermissionInstaller.readOnlyTools.contains("mcp__hypermnesia__remember"))

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var perms = json["permissions"] as! [String: Any]
        var allow = perms["allow"] as! [String]
        #expect(allow.contains("mcp__hypermnesia__recall"))
        #expect(allow.contains("mcp__hypermnesia__ask"))
        #expect(allow.contains("Bash(ls:*)"))               // pre-existing rule preserved
        #expect(perms["deny"] as? [String] == ["Bash(rm:*)"]) // deny untouched
        #expect(json["theme"] as? String == "dark")

        // Idempotent: re-install adds no duplicates.
        try PermissionInstaller.install(projectPath: dir.path)
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        perms = json["permissions"] as! [String: Any]
        allow = perms["allow"] as! [String]
        #expect(allow.filter { $0 == "mcp__hypermnesia__recall" }.count == 1)

        // Uninstall removes only ours.
        try PermissionInstaller.uninstall(projectPath: dir.path)
        #expect(!PermissionInstaller.isInstalled(projectPath: dir.path))
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        allow = (json["permissions"] as! [String: Any])["allow"] as! [String]
        #expect(allow == ["Bash(ls:*)"])                    // user rule survives, ours gone
    }

    @Test("RecallPathInstaller install/uninstall is symmetric — uninstall withdraws the tool pre-approval too")
    func recallPathInstaller() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-recall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-existing CLAUDE.md prose + an unrelated permission rule that must survive a round-trip.
        let claudeMd = MemoryGuideInstaller.claudeMdURL(projectPath: dir.path)
        try Data("# project\n\nExisting notes.\n".utf8).write(to: claudeMd)
        let settings = PermissionInstaller.settingsURL(projectPath: dir.path)
        try Data(#"{"permissions":{"allow":["Bash(ls:*)"]}}"#.utf8).write(to: settings)

        #expect(!RecallPathInstaller.isInstalled(projectPath: dir.path))

        // Install writes BOTH halves.
        try RecallPathInstaller.install(projectPath: dir.path)
        #expect(RecallPathInstaller.isInstalled(projectPath: dir.path))
        #expect(MemoryGuideInstaller.isInstalled(projectPath: dir.path))
        #expect(PermissionInstaller.isInstalled(projectPath: dir.path))

        // Uninstall must revert BOTH — the asymmetry the review caught.
        try RecallPathInstaller.uninstall(projectPath: dir.path)
        #expect(!MemoryGuideInstaller.isInstalled(projectPath: dir.path))   // guide block gone
        #expect(!PermissionInstaller.isInstalled(projectPath: dir.path))    // ← pre-approval NOT left behind

        // Unrelated rule + prose both survive the round-trip.
        let perms = (try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any])["permissions"] as! [String: Any]
        #expect((perms["allow"] as! [String]) == ["Bash(ls:*)"])
        #expect(try String(contentsOf: claudeMd, encoding: .utf8).contains("Existing notes."))
    }

    @Test("an orphaned open marker doesn't cause install+uninstall to delete the user's own content")
    func orphanMarkerDoesNotEatContent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-orphan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claudeMd = MemoryGuideInstaller.claudeMdURL(projectPath: dir.path)

        // A stray open marker (left by a bad merge) sits ABOVE the user's own prose, with no close.
        let content = """
        # My project notes
        <!-- hypermnesia:memory-guide -->
        ## Important user section A
        keep me one
        keep me two
        """
        try Data(content.utf8).write(to: claudeMd)

        try MemoryGuideInstaller.install(projectPath: dir.path)   // appends a fresh complete block
        try MemoryGuideInstaller.uninstall(projectPath: dir.path) // must not span orphan-open → real-close

        let after = try String(contentsOf: claudeMd, encoding: .utf8)
        #expect(after.contains("Important user section A"))
        #expect(after.contains("keep me one"))
        #expect(after.contains("keep me two"))
        #expect(!after.contains("recall"))   // the installed guide block itself is gone
    }

    @Test("an orphaned close marker before a valid block doesn't block removing that block")
    func orphanCloseMarkerDoesNotBlockRemoval() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-orphanclose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claudeMd = MemoryGuideInstaller.claudeMdURL(projectPath: dir.path)

        // A stray CLOSE marker (no matching open) sits ABOVE the real installed block.
        let content = """
        # My project notes
        <!-- /hypermnesia:memory-guide -->
        Some user prose.
        """
        try Data(content.utf8).write(to: claudeMd)
        try MemoryGuideInstaller.install(projectPath: dir.path)   // appends a real block below
        #expect(MemoryGuideInstaller.isInstalled(projectPath: dir.path))

        try MemoryGuideInstaller.uninstall(projectPath: dir.path)
        let after = try String(contentsOf: claudeMd, encoding: .utf8)
        #expect(!after.contains("recall"))              // the valid block WAS removed despite the orphan close
        #expect(after.contains("Some user prose."))     // and user content survives
    }
}
