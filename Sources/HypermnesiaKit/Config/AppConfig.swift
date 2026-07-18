import Foundation

/// User-editable configuration, shared by the app (Settings UI) and the CLI/hooks. Stored as JSON
/// at `~/Library/Application Support/Hypermnesia/config.json` (0600 — it may hold an API key).
public struct AppConfig: Codable, Sendable, Equatable {
    /// "auto" | "gemini" | "claude"
    public var classifier: String
    public var geminiModel: String
    public var claudeModel: String
    /// Optional explicit Gemini key; when nil, falls back to the `GEMINI_API_KEY` environment.
    public var geminiApiKey: String?
    public var injectAtSessionStart: Bool
    public var injectPerPrompt: Bool
    public var maxMemoriesInjected: Int
    /// New transcript events required before an in-session capture fires (capture sensitivity).
    public var captureThreshold: Int
    /// Auto-confirm a draft after it's been seen again (reinforced) this many times (0 = never).
    public var autoConfirmAfterSightings: Int
    /// Post a macOS notification when a drain lands new draft memories (off by default — the
    /// menu-bar badge is the quiet baseline; this is the opt-in louder channel).
    public var notifyOnNewDrafts: Bool
    /// Inject a short "previous session" working-state note at SessionStart (7-day TTL), so the
    /// next session can pick up where the last one left off.
    public var injectMomentum: Bool
    /// Confirm high-confidence hook captures immediately instead of parking them as drafts.
    /// Revisions (anything that would retire an existing memory), validator-weakened captures,
    /// and MCP `remember` writes always stay draft-gated regardless. Turn off for full review of
    /// every capture (see SECURITY.md for the trade-off).
    public var autoConfirmConfidentCaptures: Bool
    /// Notch status: pop live session status (agent finished / needs you) below the Mac's notch,
    /// with one click back to the session. Master switch — also gates the hook-side event emission.
    public var notchEnabled: Bool
    /// Pop when an agent finishes its turn (suppressed while that session's app is frontmost).
    public var notchOnAgentFinish: Bool
    /// Pop when a session is blocked on the user — a permission request or waiting for input.
    public var notchOnNeedsAttention: Bool
    /// Ambient presence: a slim "N working" strip hangs from the notch while agents are mid-turn
    /// (hover to see the sessions). Never pops — it just exists.
    public var notchShowWorking: Bool

    public init(
        classifier: String = "auto",
        geminiModel: String = GeminiClassifier.defaultModel,
        claudeModel: String = ClaudeHeadlessClassifier.defaultModel,
        geminiApiKey: String? = nil,
        injectAtSessionStart: Bool = true,
        injectPerPrompt: Bool = true,
        maxMemoriesInjected: Int = 40,
        captureThreshold: Int = 6,
        autoConfirmAfterSightings: Int = 1,
        notifyOnNewDrafts: Bool = false,
        injectMomentum: Bool = true,
        autoConfirmConfidentCaptures: Bool = true,
        notchEnabled: Bool = true,
        notchOnAgentFinish: Bool = true,
        notchOnNeedsAttention: Bool = true,
        notchShowWorking: Bool = true
    ) {
        self.classifier = classifier
        self.geminiModel = geminiModel
        self.claudeModel = claudeModel
        self.geminiApiKey = geminiApiKey
        self.injectAtSessionStart = injectAtSessionStart
        self.injectPerPrompt = injectPerPrompt
        self.maxMemoriesInjected = maxMemoriesInjected
        self.captureThreshold = captureThreshold
        self.autoConfirmAfterSightings = autoConfirmAfterSightings
        self.notifyOnNewDrafts = notifyOnNewDrafts
        self.injectMomentum = injectMomentum
        self.autoConfirmConfidentCaptures = autoConfirmConfidentCaptures
        self.notchEnabled = notchEnabled
        self.notchOnAgentFinish = notchOnAgentFinish
        self.notchOnNeedsAttention = notchOnNeedsAttention
        self.notchShowWorking = notchShowWorking
    }

    // Lenient decoding so older/newer config files keep working as fields evolve.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        classifier = try c.decodeIfPresent(String.self, forKey: .classifier) ?? d.classifier
        geminiModel = try c.decodeIfPresent(String.self, forKey: .geminiModel) ?? d.geminiModel
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        geminiApiKey = try c.decodeIfPresent(String.self, forKey: .geminiApiKey)
        injectAtSessionStart = try c.decodeIfPresent(Bool.self, forKey: .injectAtSessionStart) ?? d.injectAtSessionStart
        injectPerPrompt = try c.decodeIfPresent(Bool.self, forKey: .injectPerPrompt) ?? d.injectPerPrompt
        maxMemoriesInjected = try c.decodeIfPresent(Int.self, forKey: .maxMemoriesInjected) ?? d.maxMemoriesInjected
        captureThreshold = try c.decodeIfPresent(Int.self, forKey: .captureThreshold) ?? d.captureThreshold
        autoConfirmAfterSightings = try c.decodeIfPresent(Int.self, forKey: .autoConfirmAfterSightings) ?? d.autoConfirmAfterSightings
        notifyOnNewDrafts = try c.decodeIfPresent(Bool.self, forKey: .notifyOnNewDrafts) ?? d.notifyOnNewDrafts
        injectMomentum = try c.decodeIfPresent(Bool.self, forKey: .injectMomentum) ?? d.injectMomentum
        autoConfirmConfidentCaptures = try c.decodeIfPresent(Bool.self, forKey: .autoConfirmConfidentCaptures)
            ?? d.autoConfirmConfidentCaptures
        notchEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchEnabled) ?? d.notchEnabled
        notchOnAgentFinish = try c.decodeIfPresent(Bool.self, forKey: .notchOnAgentFinish) ?? d.notchOnAgentFinish
        notchOnNeedsAttention = try c.decodeIfPresent(Bool.self, forKey: .notchOnNeedsAttention)
            ?? d.notchOnNeedsAttention
        notchShowWorking = try c.decodeIfPresent(Bool.self, forKey: .notchShowWorking) ?? d.notchShowWorking
    }
}

/// Loads/saves `AppConfig` and resolves the effective Gemini key.
public enum AppConfigStore {
    public static var url: URL {
        StoreLocation.supportDirectory.appendingPathComponent("config.json")
    }

    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    public static func save(_ config: AppConfig) {
        try? FileManager.default.createDirectory(at: StoreLocation.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        // Create with 0600 from the start (it may hold an API key) — avoids a brief world-readable window.
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Effective Gemini key: explicit config value, else the `GEMINI_API_KEY` environment.
    public static func resolvedGeminiKey(_ config: AppConfig) -> String? {
        if let key = config.geminiApiKey, !key.isEmpty { return key }
        let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
        return (env?.isEmpty == false) ? env : nil
    }
}
