import Foundation
import Darwin

/// User-editable configuration, shared by the app (Settings UI) and the CLI/hooks. Stored as JSON
/// at `~/Library/Application Support/Hypermnesia/config.json` (0600 — it may hold an API key).
public struct AppConfig: Codable, Sendable, Equatable {
    /// "auto" | "gemini" | "claude" | "antigravity"
    public var classifier: String
    public var geminiModel: String
    public var claudeModel: String
    /// Model name for the Antigravity `agy` CLI (an `agy models` name — effort is in the name).
    public var antigravityModel: String
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
    /// Capture edited files as code-reference memories (one draft per file, confirmed by repeat
    /// sightings). The `HYPERMNESIA_CODE_REFS` environment variable, when set, overrides this for
    /// development runs.
    public var captureCodeRefs: Bool
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
    /// Memory Dreams: the idle-after-wake consolidation pass. Off by default — enabling shows a
    /// cost estimate first (one classifier call per project per night, capped).
    public var dreamsEnabled: Bool
    /// Morning digest cadence: "nightly" | "weekly" | "off". Quiet nights never notify.
    public var dreamDigestCadence: String
    /// How many days of sessions a dream reads.
    public var dreamLookbackDays: Int
    /// Let dreams propose draft memories (through the normal triage inbox).
    public var dreamProposeMemories: Bool
    /// Let dreams stage skill proposals (install is always a separate explicit confirm).
    public var dreamProposeSkills: Bool
    /// Default install target for dream skills: "project" (.claude/skills) | "user" (~/.claude/skills).
    public var dreamSkillTarget: String
    /// Max classifier calls per night across all projects (0 = uncapped). Projects beyond the cap
    /// roll to the next night, most recently active first.
    public var dreamNightlyCallCap: Int

    public init(
        classifier: String = "auto",
        geminiModel: String = GeminiClassifier.defaultModel,
        claudeModel: String = ClaudeHeadlessClassifier.defaultModel,
        antigravityModel: String = AntigravityClassifier.defaultModel,
        geminiApiKey: String? = nil,
        injectAtSessionStart: Bool = true,
        injectPerPrompt: Bool = true,
        maxMemoriesInjected: Int = 40,
        captureThreshold: Int = 6,
        autoConfirmAfterSightings: Int = 1,
        notifyOnNewDrafts: Bool = false,
        injectMomentum: Bool = true,
        autoConfirmConfidentCaptures: Bool = true,
        captureCodeRefs: Bool = false,
        notchEnabled: Bool = true,
        notchOnAgentFinish: Bool = true,
        notchOnNeedsAttention: Bool = true,
        notchShowWorking: Bool = true,
        dreamsEnabled: Bool = false,
        dreamDigestCadence: String = "nightly",
        dreamLookbackDays: Int = 3,
        dreamProposeMemories: Bool = true,
        dreamProposeSkills: Bool = true,
        dreamSkillTarget: String = "project",
        dreamNightlyCallCap: Int = 4
    ) {
        self.classifier = classifier
        self.geminiModel = geminiModel
        self.claudeModel = claudeModel
        self.antigravityModel = antigravityModel
        self.geminiApiKey = geminiApiKey
        self.injectAtSessionStart = injectAtSessionStart
        self.injectPerPrompt = injectPerPrompt
        self.maxMemoriesInjected = maxMemoriesInjected
        self.captureThreshold = captureThreshold
        self.autoConfirmAfterSightings = autoConfirmAfterSightings
        self.notifyOnNewDrafts = notifyOnNewDrafts
        self.injectMomentum = injectMomentum
        self.autoConfirmConfidentCaptures = autoConfirmConfidentCaptures
        self.captureCodeRefs = captureCodeRefs
        self.notchEnabled = notchEnabled
        self.notchOnAgentFinish = notchOnAgentFinish
        self.notchOnNeedsAttention = notchOnNeedsAttention
        self.notchShowWorking = notchShowWorking
        self.dreamsEnabled = dreamsEnabled
        self.dreamDigestCadence = dreamDigestCadence
        self.dreamLookbackDays = dreamLookbackDays
        self.dreamProposeMemories = dreamProposeMemories
        self.dreamProposeSkills = dreamProposeSkills
        self.dreamSkillTarget = dreamSkillTarget
        self.dreamNightlyCallCap = dreamNightlyCallCap
    }

    // Lenient decoding so older/newer config files keep working as fields evolve.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        classifier = try c.decodeIfPresent(String.self, forKey: .classifier) ?? d.classifier
        geminiModel = try c.decodeIfPresent(String.self, forKey: .geminiModel) ?? d.geminiModel
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        antigravityModel = try c.decodeIfPresent(String.self, forKey: .antigravityModel) ?? d.antigravityModel
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
        captureCodeRefs = try c.decodeIfPresent(Bool.self, forKey: .captureCodeRefs) ?? d.captureCodeRefs
        notchEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchEnabled) ?? d.notchEnabled
        notchOnAgentFinish = try c.decodeIfPresent(Bool.self, forKey: .notchOnAgentFinish) ?? d.notchOnAgentFinish
        notchOnNeedsAttention = try c.decodeIfPresent(Bool.self, forKey: .notchOnNeedsAttention)
            ?? d.notchOnNeedsAttention
        notchShowWorking = try c.decodeIfPresent(Bool.self, forKey: .notchShowWorking) ?? d.notchShowWorking
        dreamsEnabled = try c.decodeIfPresent(Bool.self, forKey: .dreamsEnabled) ?? d.dreamsEnabled
        dreamDigestCadence = try c.decodeIfPresent(String.self, forKey: .dreamDigestCadence) ?? d.dreamDigestCadence
        dreamLookbackDays = try c.decodeIfPresent(Int.self, forKey: .dreamLookbackDays) ?? d.dreamLookbackDays
        dreamProposeMemories = try c.decodeIfPresent(Bool.self, forKey: .dreamProposeMemories) ?? d.dreamProposeMemories
        dreamProposeSkills = try c.decodeIfPresent(Bool.self, forKey: .dreamProposeSkills) ?? d.dreamProposeSkills
        dreamSkillTarget = try c.decodeIfPresent(String.self, forKey: .dreamSkillTarget) ?? d.dreamSkillTarget
        dreamNightlyCallCap = try c.decodeIfPresent(Int.self, forKey: .dreamNightlyCallCap) ?? d.dreamNightlyCallCap
    }
}

public enum AppConfigLoadError: Error, Sendable, Equatable, LocalizedError {
    case unreadable(path: String, reason: String)
    case corrupt(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            "Could not read settings at \(path): \(reason)"
        case .corrupt(let path, let reason):
            "Settings at \(path) are invalid JSON: \(reason)"
        }
    }
}

public enum AppConfigSaveError: Error, Sendable, Equatable, LocalizedError {
    case createDirectory(path: String, reason: String)
    case encode(reason: String)
    case createTemporary(path: String, reason: String)
    case writeTemporary(path: String, reason: String)
    case replace(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .createDirectory(let path, let reason):
            "Could not create the settings directory at \(path): \(reason)"
        case .encode(let reason):
            "Could not encode settings: \(reason)"
        case .createTemporary(let path, let reason):
            "Could not create a private temporary settings file at \(path): \(reason)"
        case .writeTemporary(let path, let reason):
            "Could not write settings at \(path): \(reason)"
        case .replace(let path, let reason):
            "Could not atomically replace settings at \(path): \(reason)"
        }
    }
}

/// Loads/saves `AppConfig` and resolves the effective Gemini key.
public enum AppConfigStore {
    public static var url: URL {
        StoreLocation.supportDirectory.appendingPathComponent("config.json")
    }

    /// Strict load for observable surfaces such as Settings. A missing file means defaults; an
    /// unreadable or corrupt existing file is a typed error and is never silently overwritten.
    public static func load() throws -> AppConfig {
        try load(from: url)
    }

    public static func load(from target: URL) throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: target.path) else { return AppConfig() }
        let data: Data
        do {
            data = try Data(contentsOf: target)
        } catch {
            throw AppConfigLoadError.unreadable(path: target.path, reason: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            throw AppConfigLoadError.corrupt(path: target.path, reason: error.localizedDescription)
        }
    }

    /// Hook/CLI-safe fallback. Corrupt settings degrade to defaults so capture can continue, but the
    /// diagnostic is emitted to stderr (or the supplied sink) instead of disappearing.
    public static func loadBestEffort(
        from target: URL? = nil,
        diagnostic: ((String) -> Void)? = nil
    ) -> AppConfig {
        do {
            return try load(from: target ?? url)
        } catch {
            let message = "hypermnesia: warning: \(error.localizedDescription)\n"
            if let diagnostic {
                diagnostic(message.trimmingCharacters(in: .newlines))
            } else {
                try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            }
            return AppConfig()
        }
    }

    public static func save(_ config: AppConfig) throws {
        try save(config, to: url)
    }

    /// Encode to a same-directory 0600 temporary file, fsync it, then rename over the destination.
    /// `rename(2)` is atomic and the temporary inode is private from creation, so an API key is never
    /// exposed through a partially-written or briefly world-readable config file.
    public static func save(_ config: AppConfig, to target: URL) throws {
        let directory = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AppConfigSaveError.createDirectory(path: directory.path, reason: error.localizedDescription)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(config)
        } catch {
            throw AppConfigSaveError.encode(reason: error.localizedDescription)
        }

        let temporary = directory.appendingPathComponent(".config-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw AppConfigSaveError.createTemporary(
                path: temporary.path, reason: String(cString: strerror(errno)))
        }
        var shouldRemoveTemporary = true
        defer {
            close(fd)
            if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporary) }
        }

        let writeError: String? = data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    return String(cString: strerror(errno))
                }
                written += count
            }
            return nil
        }
        if let writeError {
            throw AppConfigSaveError.writeTemporary(path: temporary.path, reason: writeError)
        }
        guard fsync(fd) == 0 else {
            throw AppConfigSaveError.writeTemporary(
                path: temporary.path, reason: String(cString: strerror(errno)))
        }
        guard rename(temporary.path, target.path) == 0 else {
            throw AppConfigSaveError.replace(path: target.path, reason: String(cString: strerror(errno)))
        }
        shouldRemoveTemporary = false
    }

    /// Effective Gemini key: explicit config value, else the `GEMINI_API_KEY` environment.
    public static func resolvedGeminiKey(_ config: AppConfig) -> String? {
        if let key = config.geminiApiKey, !key.isEmpty { return key }
        let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
        return (env?.isEmpty == false) ? env : nil
    }
}
