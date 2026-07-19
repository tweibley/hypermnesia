import Foundation

/// A model that answers with a JSON object. Distinct from `Completer` (free-form text) because the
/// two engines guarantee JSON differently — and one of them can't:
///  - Gemini: mime-only JSON mode (`response_format` with NO schema — the interactions API's
///    structured-output schema subset silently drops freeform objects, so the MIME type is
///    constrained but the shape never is).
///  - `claude -p`: JSON is prompt-enforced only; output may arrive fenced or wrapped in prose, so
///    every caller must parse with `ClassifierJSON.extractObject` and always run under the
///    adapter's hard timeout.
public protocol DreamCompleter: Sendable {
    func completeJSON(system: String, user: String) async throws -> String
}

/// Picks the dream engine from saved configuration — the same selection logic as
/// `Classifiers.makeFromConfig`, with a longer hard timeout (a dream reads several transcripts).
public enum DreamCompleters {
    public static let timeout: TimeInterval = 180

    public static func makeFromConfig(
        _ config: AppConfig = AppConfigStore.loadBestEffort()
    ) -> DreamCompleter {
        switch Classifiers.Kind(rawValue: config.classifier) ?? .auto {
        case .gemini:
            return GeminiClassifier(
                apiKey: AppConfigStore.resolvedGeminiKey(config) ?? "",
                model: config.geminiModel, timeout: timeout)
        case .claude:
            return ClaudeHeadlessClassifier(
                claudePath: CLIPath.claude(), model: config.claudeModel, timeout: timeout)
        case .auto:
            if let key = AppConfigStore.resolvedGeminiKey(config) {
                return GeminiClassifier(apiKey: key, model: config.geminiModel, timeout: timeout)
            }
            return ClaudeHeadlessClassifier(
                claudePath: CLIPath.claude(), model: config.claudeModel, timeout: timeout)
        }
    }

    /// Human-readable engine label for stats/consent copy ("gemini (gemini-3.5-flash)").
    public static func label(_ config: AppConfig = AppConfigStore.loadBestEffort()) -> String {
        Classifiers.cliDescription(classifier: nil, config: config)
    }

    /// Order-of-magnitude per-call cost for the honest per-night line. Deliberately conservative
    /// (rounded up); shown with "~" everywhere.
    public static func estimatedCostPerCallUSD(label: String) -> Double {
        label.lowercased().contains("gemini") ? 0.005 : 0.02
    }
}
