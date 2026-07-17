import ArgumentParser
import Foundation
import HypermnesiaKit

/// `hypermnesia install-mcp` — register the stdio MCP server with Claude Code, the analogue of
/// `install-cursor-mcp`. Project scope writes `.mcp.json`; user scope goes through `claude mcp`
/// (its own state file isn't ours to rewrite).
struct InstallMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-mcp",
        abstract: "Register the hypermnesia MCP server with Claude Code (.mcp.json or user scope)."
    )

    @Option(name: .long, help: "Register in a project's .mcp.json instead of user scope.")
    var project: String?

    @Flag(name: .long, help: "Remove the hypermnesia MCP server entry instead of adding it.")
    var uninstall = false

    @Flag(name: .long, help: "Print what would change without writing it.")
    var dryRun = false

    func run() async throws {
        if let project {
            try Self.runProjectScope(project: project, uninstall: uninstall, dryRun: dryRun)
        } else {
            try Self.runUserScope(uninstall: uninstall, dryRun: dryRun)
        }
    }

    static func runProjectScope(project: String, uninstall: Bool, dryRun: Bool) throws {
        let url = ClaudeMCPInstaller.configURL(projectPath: project)
        if uninstall {
            if dryRun { print("(dry run) would remove hypermnesia MCP server from \(url.path)"); return }
            try ClaudeMCPInstaller.uninstall(projectPath: project)
            print("Removed hypermnesia MCP server from \(url.path)")
            return
        }
        if dryRun {
            let merged = ClaudeMCPInstaller.merged(
                into: try ConfigFile.readObject(at: url), binaryPath: InstallHooks.selfPath)
            let json = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: json, as: UTF8.self))
            print("\n(dry run — not written to \(url.path))")
            return
        }
        try ClaudeMCPInstaller.install(binaryPath: InstallHooks.selfPath, projectPath: project)
        print("Registered hypermnesia MCP server in \(url.path)")
        print("  Claude Code sessions in this project can now call recall / ask / remember.")
    }

    static func runUserScope(uninstall: Bool, dryRun: Bool) throws {
        let arguments = uninstall
            ? ["mcp", "remove", "--scope", "user", ClaudeMCPInstaller.server]
            : ["mcp", "add", "--scope", "user", ClaudeMCPInstaller.server, "--", InstallHooks.selfPath, "mcp"]
        if dryRun {
            print("(dry run) would run: claude \(arguments.joined(separator: " "))")
            return
        }
        let result = Shell.run("claude", arguments, timeout: 30)
        guard result.succeeded else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ValidationError("""
            `claude \(arguments.prefix(2).joined(separator: " "))` failed\(detail.isEmpty ? "." : ": \(detail)")
            Is the Claude Code CLI installed and on PATH? For a single project you can use
            `hypermnesia install-mcp --project <path>` instead (writes .mcp.json directly).
            """)
        }
        print(uninstall
            ? "Removed hypermnesia MCP server from Claude Code user scope."
            : "Registered hypermnesia MCP server in Claude Code user scope.")
    }
}

/// `hypermnesia setup` — one-shot setup, replacing the four-step manual sequence. Defaults to the
/// proven hooks path; `--with-mcp` also enables the opt-in pull path (memory guide + read-only tool
/// pre-approval + MCP registration). `--uninstall` reverses everything setup can install.
struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up Hypermnesia for Claude Code in one command (hooks; --with-mcp for the pull path)."
    )

    @Option(name: .long, help: "Set up a single project instead of user-global.")
    var project: String?

    @Flag(name: .long, help: "Also enable the MCP pull path (memory guide, recall/ask pre-approval, MCP server).")
    var withMcp = false

    @Flag(name: .long, help: "Remove everything setup can install (hooks, guide, pre-approval, MCP entry).")
    var uninstall = false

    @Flag(name: .long, help: "Show what would change without writing anything.")
    var dryRun = false

    func run() async throws {
        if uninstall {
            try runUninstall()
        } else {
            try runInstall()
        }
        if !dryRun {
            print("\nRun `hypermnesia doctor` to verify the installation.")
        }
    }

    private func runInstall() throws {
        let hooksURL = HookInstaller.settingsURL(projectPath: project)
        if dryRun {
            print("(dry run) would install capture + hydrate hooks into \(hooksURL.path)")
        } else {
            try HookInstaller.install(binaryPath: InstallHooks.selfPath, projectPath: project)
            print("✓ Hooks installed (\(hooksURL.path)) — sessions now build and use memory.")
        }
        guard withMcp else {
            if !dryRun { print("  (MCP pull path not enabled — add it any time with `hypermnesia setup --with-mcp`.)") }
            return
        }
        let guideURL = MemoryGuideInstaller.claudeMdURL(projectPath: project)
        if dryRun {
            print("(dry run) would install the memory guide into \(guideURL.path) and pre-approve recall/ask")
        } else {
            try RecallPathInstaller.install(projectPath: project)
            print("✓ Memory guide installed (\(guideURL.path)); recall/ask pre-approved (remember stays prompted).")
        }
        if let project {
            try InstallMCP.runProjectScope(project: project, uninstall: false, dryRun: dryRun)
        } else {
            try InstallMCP.runUserScope(uninstall: false, dryRun: dryRun)
        }
    }

    private func runUninstall() throws {
        // Reverse everything setup can have written, tolerating pieces that were never installed —
        // install and uninstall must be inverses even when the user mixed and matched.
        let hooksURL = HookInstaller.settingsURL(projectPath: project)
        if dryRun {
            print("(dry run) would remove hooks from \(hooksURL.path)")
        } else {
            try HookInstaller.uninstall(projectPath: project)
            print("✓ Hooks removed (\(hooksURL.path)).")
        }
        let guideURL = MemoryGuideInstaller.claudeMdURL(projectPath: project)
        if dryRun {
            print("(dry run) would remove the memory guide from \(guideURL.path) and withdraw recall/ask pre-approval")
        } else {
            try RecallPathInstaller.uninstall(projectPath: project)
            print("✓ Memory guide removed (\(guideURL.path)); recall/ask pre-approval withdrawn.")
        }
        if let project {
            try InstallMCP.runProjectScope(project: project, uninstall: true, dryRun: dryRun)
        } else if ClaudeMCPUserScope.probablyInstalled() {
            try InstallMCP.runUserScope(uninstall: true, dryRun: dryRun)
        } else {
            print(dryRun ? "(dry run) no user-scope MCP entry detected — nothing to remove"
                         : "✓ No user-scope MCP entry detected — nothing to remove.")
        }
        if !dryRun {
            print("\nYour memories are untouched — the database stays in place until you delete it.")
        }
    }
}

/// Cheap, read-only check whether the user-scope `claude mcp` entry exists, so `setup --uninstall`
/// doesn't fail on a machine that never registered it (or has no `claude` CLI at all).
enum ClaudeMCPUserScope {
    static func probablyInstalled() -> Bool {
        let result = Shell.run("claude", ["mcp", "get", ClaudeMCPInstaller.server], timeout: 15)
        return result.succeeded
    }
}
