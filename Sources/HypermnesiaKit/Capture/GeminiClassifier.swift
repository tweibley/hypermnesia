import Foundation

/// Classifies a session via the Google Gemini **interactions** API (`/v1beta/interactions`) using
/// `GEMINI_API_KEY`.
///
/// The interactions endpoint takes a single `input` prompt plus a `system_instruction`, and returns
/// a list of `steps` — internal "thought" steps followed by a final "model_output" step. Gemini 3.x
/// Flash "thinks" by default, giving higher-quality extraction than a small headless model.
///
/// For classification we request `response_format: {type: text, mime_type: application/json}` so the
/// model output is guaranteed valid JSON (no fences, no prose). We deliberately pass **no `schema`**:
/// Gemini's structured-output schema subset can't represent our freeform per-type `context` object
/// and silently drops it, so we constrain the MIME type but not the shape. `ClassifierJSON` still
/// tolerates fences as defense-in-depth. Free-form completion (`complete`) omits `response_format`.
public struct GeminiClassifier: Classifier {
    public static let defaultModel = "gemini-3.5-flash"

    public var apiKey: String
    public var model: String
    public var temperature: Double
    public var timeout: TimeInterval

    public init(
        apiKey: String,
        model: String = defaultModel,
        temperature: Double = 0.2,
        timeout: TimeInterval = 120
    ) {
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.timeout = timeout
    }

    /// Build from `GEMINI_API_KEY`, or `nil` if it isn't set.
    public static func fromEnvironment(model: String = defaultModel) -> GeminiClassifier? {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
            return nil
        }
        return GeminiClassifier(apiKey: key, model: model)
    }

    public func classify(
        _ conversation: Conversation,
        recentMemories: [RecentMemoryHint]
    ) async throws -> [ClassifiedMemory] {
        try await classify(conversation, recentMemories: recentMemories, focus: nil)
    }

    public func classify(
        _ conversation: Conversation,
        recentMemories: [RecentMemoryHint],
        focus: String?
    ) async throws -> [ClassifiedMemory] {
        guard !conversation.isEmpty else { return [] }
        let text = try await generate(
            system: ClassifierPrompts.system,
            input: ClassifierPrompts.user(conversation, recentMemories: recentMemories, focus: focus),
            temperature: temperature,
            json: true
        )
        // An empty model_output (thinking consumed the budget, a safety block, or interactions-API
        // schema drift) is a *failure*, not "0 memories" — treat it like the claude adapter so the
        // drain retries instead of silently sealing the session with nothing captured.
        guard !text.isEmpty else { throw ClassifierError.emptyOutput }
        return try ClassifierJSON.memories(fromModelText: text)
    }

    // MARK: - Interactions request

    /// POST to the interactions endpoint and return the concatenated `model_output` text
    /// (internal "thought" steps are skipped). `json` requests guaranteed JSON output.
    private func generate(system: String, input: String, temperature: Double, json: Bool) async throws -> String {
        guard !apiKey.isEmpty else { throw ClassifierError.toolFailed("GEMINI_API_KEY not set") }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: model,
            input: input,
            system_instruction: system,
            generation_config: .init(temperature: temperature),
            response_format: json ? .jsonObject : nil
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClassifierError.toolFailed("no HTTP response from Gemini")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? "HTTP \(http.statusCode)"
            throw ClassifierError.toolFailed("Gemini: \(message)")
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        return decoded.modelOutputText
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        let model: String
        let input: String
        let system_instruction: String
        let generation_config: GenerationConfig
        /// Omitted (nil → key absent) for plain-text completion; set for guaranteed-JSON classification.
        let response_format: ResponseFormat?
        struct GenerationConfig: Encodable { let temperature: Double }
        struct ResponseFormat: Encodable {
            let type: String
            let mime_type: String
            /// JSON object mode with no schema — see the type doc for why a schema is intentionally absent.
            static let jsonObject = ResponseFormat(type: "text", mime_type: "application/json")
        }
    }

    private struct ResponseBody: Decodable {
        let steps: [Step]?
        struct Step: Decodable {
            let type: String?
            let content: [Part]?
        }
        struct Part: Decodable {
            let text: String?
            let type: String?
        }
        /// Concatenated text from the final model output, skipping internal "thought" steps.
        var modelOutputText: String {
            (steps ?? [])
                .filter { $0.type == "model_output" }
                .flatMap { $0.content ?? [] }
                .compactMap(\.text)
                .joined()
        }
    }

    private struct ErrorEnvelope: Decodable {
        let error: Detail
        struct Detail: Decodable { let message: String }
    }
}

extension GeminiClassifier: Completer {
    /// Free-form completion (plain text) — used for natural-language memory queries.
    public func complete(system: String, user: String) async throws -> String {
        let text = try await generate(system: system, input: user, temperature: 0.3, json: false)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
