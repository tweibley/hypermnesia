import Foundation
import Testing
@testable import HypermnesiaKit

/// Regressions for the GUI-app classifier failures: a Dock-launched app inherits launchd's bare
/// environment, which broke apiKeyHelper scripts / npm-shim installs / profile-exported keys
/// ("Not logged in", "env: node: No such file or directory", "claude-gateway: command not found"),
/// and a cleared Settings model field persisted "" → `claude --model ""` → API 400.
@Suite("Classifier environment and model normalization")
struct ClassifierEnvironmentTests {

    // MARK: - LoginShellEnvironment.merge

    @Test("login-shell values fill gaps but never override the process environment")
    func mergeFillsGapsOnly() {
        let merged = LoginShellEnvironment.merge(
            ["ANTHROPIC_BASE_URL": "https://proxy.example"],
            loginShell: [
                "ANTHROPIC_API_KEY": "sk-from-profile",
                "ANTHROPIC_BASE_URL": "https://ignored.example",
            ])
        #expect(merged["ANTHROPIC_API_KEY"] == "sk-from-profile")
        #expect(merged["ANTHROPIC_BASE_URL"] == "https://proxy.example")
    }

    @Test("gateway and helper-script variables are preserved, shell bookkeeping is not")
    func mergePreservesGatewayVariables() {
        // A Portkey-style gateway setup exported in the shell profile. The `claude-gateway`
        // apiKeyHelper is an arbitrary script that may read ANY exported variable
        // (PORTKEY_API_KEY, a vault token, …), so everything fills in except the shell's own
        // bookkeeping — a stale PWD would lie to scripts, since the subprocess cwd is set
        // explicitly to ClassifierWorkdir.
        let merged = LoginShellEnvironment.merge(
            [:],
            loginShell: [
                "ANTHROPIC_BASE_URL": "https://portkey.example/v1",
                "ANTHROPIC_AUTH_TOKEN": "pk-token",
                "ANTHROPIC_CUSTOM_HEADERS": "x-portkey-provider: anthropic",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                "CLAUDE_CONFIG_DIR": "/Users/u/.claude-work",
                "PORTKEY_API_KEY": "pk-secret",
                "NODE_EXTRA_CA_CERTS": "/etc/ssl/corp.pem",
                "HTTPS_PROXY": "http://proxy:3128",
                "AWS_PROFILE": "bedrock",
                "GOOGLE_APPLICATION_CREDENTIALS": "/Users/u/gcp.json",
                "PWD": "/Users/u/somewhere",
                "OLDPWD": "/Users/u/elsewhere",
                "SHLVL": "2",
                "_": "/usr/bin/env",
            ])
        #expect(merged["ANTHROPIC_BASE_URL"] == "https://portkey.example/v1")
        #expect(merged["ANTHROPIC_AUTH_TOKEN"] == "pk-token")
        #expect(merged["ANTHROPIC_CUSTOM_HEADERS"] == "x-portkey-provider: anthropic")
        #expect(merged["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        #expect(merged["CLAUDE_CONFIG_DIR"] == "/Users/u/.claude-work")
        #expect(merged["PORTKEY_API_KEY"] == "pk-secret")
        #expect(merged["NODE_EXTRA_CA_CERTS"] == "/etc/ssl/corp.pem")
        #expect(merged["HTTPS_PROXY"] == "http://proxy:3128")
        #expect(merged["AWS_PROFILE"] == "bedrock")
        #expect(merged["GOOGLE_APPLICATION_CREDENTIALS"] == "/Users/u/gcp.json")
        #expect(merged["PWD"] == nil)
        #expect(merged["OLDPWD"] == nil)
        #expect(merged["SHLVL"] == nil)
        #expect(merged["_"] == nil)
    }

    @Test("empty process values are treated as absent")
    func mergeTreatsEmptyAsAbsent() {
        let merged = LoginShellEnvironment.merge(
            ["GEMINI_API_KEY": ""], loginShell: ["GEMINI_API_KEY": "g-key"])
        #expect(merged["GEMINI_API_KEY"] == "g-key")
    }

    @Test("PATH is joined, process entries first, without duplicates")
    func mergeJoinsPath() {
        // The launchd default PATH plus a login-shell PATH containing ~/.local/bin — the
        // apiKeyHelper (`claude-gateway`) case: the helper's directory must become reachable.
        let merged = LoginShellEnvironment.merge(
            ["PATH": "/usr/bin:/bin"],
            loginShell: ["PATH": "/Users/u/.local/bin:/usr/bin:/opt/homebrew/bin"])
        #expect(merged["PATH"] == "/usr/bin:/bin:/Users/u/.local/bin:/opt/homebrew/bin")
    }

    @Test("missing login-shell capture leaves the environment untouched")
    func mergeNoopWithoutCapture() {
        let env = ["PATH": "/usr/bin:/bin", "HOME": "/Users/u"]
        #expect(LoginShellEnvironment.merge(env, loginShell: [:]) == env)
    }

    // MARK: - Model normalization

    @Test("empty and whitespace models fall back to the backend default")
    func normalizedModel() {
        #expect(Classifiers.normalizedModel("", default: "fallback") == "fallback")
        #expect(Classifiers.normalizedModel("  \n", default: "fallback") == "fallback")
        #expect(Classifiers.normalizedModel(" m1 ", default: "fallback") == "m1")
    }

    @Test("engine never hands a backend an empty model string")
    func engineNormalizesConfiguredModels() {
        var config = AppConfig()
        config.claudeModel = ""          // a cleared Settings field persists exactly this
        config.geminiModel = "   "
        config.antigravityModel = ""

        let claude = Classifiers.engine(.claude, config: config) as? ClaudeHeadlessClassifier
        #expect(claude?.model == ClaudeHeadlessClassifier.defaultModel)
        let gemini = Classifiers.engine(.gemini, config: config) as? GeminiClassifier
        #expect(gemini?.model == GeminiClassifier.defaultModel)
        let agy = Classifiers.engine(.antigravity, config: config) as? AntigravityClassifier
        #expect(agy?.model == AntigravityClassifier.defaultModel)
    }

    @Test("decoding a config with empty model fields self-heals to defaults")
    func decodeSelfHealsEmptyModels() throws {
        let json = #"{"claudeModel":"","geminiModel":" ","antigravityModel":"\n"}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.claudeModel == ClaudeHeadlessClassifier.defaultModel)
        #expect(config.geminiModel == GeminiClassifier.defaultModel)
        #expect(config.antigravityModel == AntigravityClassifier.defaultModel)
    }

    @Test("decoding keeps explicitly configured models")
    func decodeKeepsRealModels() throws {
        let json = #"{"claudeModel":"claude-sonnet-5"}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.claudeModel == "claude-sonnet-5")
    }
}

/// `doctor --report` building blocks — the helper-resolution check is the exact Portkey
/// `claude-gateway` failure mode: a helper on the login-shell PATH but not the bare app PATH.
@Suite("Environment report")
struct EnvironmentReportTests {

    @Test("helperResolves finds a bare command only via the given PATH")
    func helperResolvesViaPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyp-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appendingPathComponent("claude-gateway")
        try "#!/bin/sh\necho key\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        // Bare launchd PATH: not found — Nathan's bug. With the login-shell dir joined: found.
        #expect(!EnvironmentReport.helperResolves("claude-gateway", env: ["PATH": "/usr/bin:/bin"]))
        #expect(EnvironmentReport.helperResolves("claude-gateway", env: ["PATH": "/usr/bin:/bin:\(dir.path)"]))
        // Absolute and tilde-free paths bypass PATH entirely; extra arguments are ignored.
        #expect(EnvironmentReport.helperResolves("\(helper.path) --refresh", env: [:]))
        #expect(!EnvironmentReport.helperResolves("/nonexistent/helper", env: [:]))
    }

    @Test("report renders the claude section without leaking env values")
    func reportClaudeSection() async {
        var config = AppConfig()
        config.classifier = "claude"
        let (text, _) = await EnvironmentReport.generate(config: config, liveCheck: false)
        #expect(text.contains("### claude CLI"))
        #expect(text.contains("- apiKeyHelper:"))
        // Redaction: names may appear, but no env var VALUE may. Spot-check with a canary.
        setenv("ANTHROPIC_TEST_CANARY", "super-secret-value", 1)
        defer { unsetenv("ANTHROPIC_TEST_CANARY") }
        let (text2, _) = await EnvironmentReport.generate(config: config, liveCheck: false)
        #expect(text2.contains("ANTHROPIC_TEST_CANARY"))
        #expect(!text2.contains("super-secret-value"))
    }
}
