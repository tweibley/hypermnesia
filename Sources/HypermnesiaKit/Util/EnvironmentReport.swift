import Foundation

/// A shareable, secret-free environment report for bug reports (`hypermnesia doctor --report`).
///
/// Motivated by classifier failures that only reproduce in the GUI app's launchd environment
/// (apiKeyHelper scripts off PATH, profile-exported keys missing): the report captures exactly the
/// facts needed to diagnose those remotely — how `claude` is installed and authenticated, which
/// relevant variables the login shell provides that the bare environment lacks, whether an
/// `apiKeyHelper` resolves, and a live end-to-end classifier check.
///
/// Redaction contract: environment variable VALUES are never printed, only names; auth status is
/// reduced to method/provider fields (no account email); the Gemini key is reported as a source,
/// never a value.
public enum EnvironmentReport {

    public static func generate(
        config: AppConfig = AppConfigStore.loadBestEffort(), liveCheck: Bool = true
    ) async -> (text: String, healthy: Bool) {
        var out: [String] = []
        var healthy = true

        out.append("## Hypermnesia environment report")
        out.append("- hypermnesia: \(Hypermnesia.version)")
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        out.append("- macOS: \(os) (arm64)")
        #else
        out.append("- macOS: \(os) (x86_64)")
        #endif

        let kind = Classifiers.Kind(rawValue: config.classifier) ?? .auto
        let effective = kind == .auto ? Classifiers.autoKind(config) : kind
        out.append("- classifier: \(config.classifier) → \(Classifiers.cliDescription(classifier: nil, config: config))")
        out.append("- gemini key: \(geminiKeySource(config))")

        if effective == .claude { out.append(contentsOf: claudeSection(&healthy)) }
        if effective == .antigravity {
            let path = CLIPath.findAgy()
            out.append("### agy CLI")
            out.append("- path: \(path ?? "NOT FOUND ✗")")
            if path == nil { healthy = false }
        }

        out.append(contentsOf: environmentSection())

        if liveCheck {
            out.append("### live classifier check")
            let engine = Classifiers.engineForCLI(classifier: nil, model: nil, config: config, timeout: 60)
            let start = Date()
            do {
                let reply = try await engine.complete(
                    system: "You are a connectivity health check. Reply with exactly: ok", user: "health check")
                let secs = String(format: "%.1f", Date().timeIntervalSince(start))
                out.append("- result: ok (\(secs)s, replied \"\(reply.prefix(40))\")")
            } catch {
                out.append("- result: FAILED ✗ — \(error.localizedDescription)")
                healthy = false
            }
        }

        return (out.joined(separator: "\n"), healthy)
    }

    // MARK: - Sections

    private static func claudeSection(_ healthy: inout Bool) -> [String] {
        var out = ["### claude CLI"]
        guard let path = CLIPath.findClaude() else {
            healthy = false
            return out + ["- path: NOT FOUND ✗"]
        }
        out.append("- path: \(path)")
        out.append("- kind: \(binaryKind(path))")
        let env = LoginShellEnvironment.classifierEnvironment()
        let version = Shell.run(path, ["--version"], environment: env, timeout: 15)
        out.append("- version: \(version.succeeded ? version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "unknown (\(version.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))")")

        // Auth method only — deliberately not the account email.
        let auth = Shell.run(path, ["auth", "status"], environment: env, timeout: 15)
        if auth.succeeded,
           let obj = try? JSONSerialization.jsonObject(with: Data(auth.stdout.utf8)) as? [String: Any] {
            let fields = ["loggedIn", "authMethod", "apiProvider", "subscriptionType"]
                .compactMap { key in obj[key].map { "\(key)=\($0)" } }
            out.append("- auth: \(fields.joined(separator: " "))")
        } else {
            out.append("- auth: unavailable (`claude auth status` failed or not supported)")
        }

        // The apiKeyHelper is how gateway setups authenticate (e.g. Portkey's claude-gateway);
        // report whether the command it names resolves in the environment classifiers spawn with.
        if let helper = apiKeyHelper() {
            let resolves = helperResolves(helper, env: env)
            out.append("- apiKeyHelper: \(helper) (\(resolves ? "resolves ✓" : "NOT ON PATH in app environment ✗"))")
            if !resolves { healthy = false }
        } else {
            out.append("- apiKeyHelper: none")
        }
        return out
    }

    /// Names only — values are never printed.
    private static func environmentSection() -> [String] {
        let interesting: (String) -> Bool = { key in
            ["ANTHROPIC_", "CLAUDE_", "GEMINI_", "PORTKEY_", "AWS_", "GOOGLE_"].contains { key.hasPrefix($0) }
                || ["NODE_EXTRA_CA_CERTS", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "CLOUD_ML_REGION"].contains(key)
        }
        let process = Set(ProcessInfo.processInfo.environment.keys.filter(interesting))
        let merged = LoginShellEnvironment.classifierEnvironment()
        let loginOnly = Set(merged.keys.filter(interesting)).subtracting(process)

        var out = ["### environment (variable names only)"]
        out.append("- process: \(process.isEmpty ? "(none)" : process.sorted().joined(separator: ", "))")
        out.append("- login shell adds: \(loginOnly.isEmpty ? "(none)" : loginOnly.sorted().joined(separator: ", "))")
        let processPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").count
        let mergedPath = (merged["PATH"] ?? "").split(separator: ":").count
        out.append("- PATH: \(processPath) dir(s) in process, \(mergedPath) after login-shell merge")
        return out
    }

    // MARK: - Helpers

    private static func binaryKind(_ path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path),
              let head = try? handle.read(upToCount: 256), head.count >= 4 else { return "unreadable" }
        defer { try? handle.close() }
        if head.starts(with: [0x23, 0x21]) {   // "#!" — a shim needs its interpreter on PATH
            let line = String(decoding: head.prefix(while: { $0 != 0x0A }), as: UTF8.self)
            return "script (\(line))"
        }
        let magics: [[UInt8]] = [[0xCF, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0xFE, 0xED, 0xFA, 0xCF]]
        if magics.contains(where: { head.starts(with: $0) }) { return "native binary (Mach-O)" }
        return "unknown"
    }

    /// The `apiKeyHelper` command from the claude settings file, if configured.
    static func apiKeyHelper() -> String? {
        let configDir = LoginShellEnvironment.value("CLAUDE_CONFIG_DIR")
            ?? NSHomeDirectory() + "/.claude"
        let url = URL(fileURLWithPath: configDir).appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["apiKeyHelper"] as? String
    }

    /// Whether the helper's executable (its first token) is reachable — absolute path, or found on
    /// the given environment's PATH the way `/bin/sh` would find it.
    static func helperResolves(_ helper: String, env: [String: String]) -> Bool {
        guard let first = helper.split(separator: " ").first.map(String.init) else { return false }
        let expanded = NSString(string: first).expandingTildeInPath
        if expanded.contains("/") { return FileManager.default.isExecutableFile(atPath: expanded) }
        return (env["PATH"] ?? "").split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/\(first)")
        }
    }

    private static func geminiKeySource(_ config: AppConfig) -> String {
        if config.geminiApiKey?.isEmpty == false { return "set in app settings" }
        if LoginShellEnvironment.value("GEMINI_API_KEY") != nil { return "from $GEMINI_API_KEY" }
        return "not set"
    }
}
