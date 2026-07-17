import Foundation
import NaturalLanguage

/// Produces a vector embedding for text, for semantic similarity.
public protocol Embedder: Sendable {
    /// Stable identifier (model + dimensions); stored alongside vectors so they can be re-indexed
    /// when the embedder changes.
    var identifier: String { get }
    func embed(_ text: String) -> [Float]?
}

/// On-device sentence embeddings via Apple's NaturalLanguage framework — free, offline, no API key.
///
/// Concurrency: `NLEmbedding.vector(for:)` is NOT safe to call concurrently on a shared instance —
/// CoreNLP corrupts its internal fill buffers (observed SIGTRAP in `fillWordVectors` when a single
/// model was shared across parallel tests). Each `AppleEmbedder` therefore owns a private model
/// instance, and `embed` is additionally serialized with a lock so a single value captured by
/// multiple threads stays safe — which is what makes the `@unchecked Sendable` claim true.
public final class AppleEmbedder: Embedder, @unchecked Sendable {
    public let identifier: String
    private let embedding: NLEmbedding?
    private let lock = NSLock()

    /// One-time availability probe with a deadline. `NLEmbedding.sentenceEmbedding` can block
    /// indefinitely when the on-device model asset is missing and the asset daemon stalls (fresh
    /// CI runners; some managed Macs). If the probe doesn't finish in time, semantic search is
    /// treated as unavailable everywhere — the documented degrade path (FTS keyword fallback) —
    /// and NLEmbedding is never called again this process. The probe thread is abandoned at worst
    /// once; after a successful probe, per-instance loads hit the framework's warm cache.
    private static let probeSucceeded: Bool = {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var ok = false
            func set(_ v: Bool) { lock.lock(); ok = v; lock.unlock() }
            var value: Bool { lock.lock(); defer { lock.unlock() }; return ok }
        }
        let flag = Flag()
        let loaded = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            flag.set(NLEmbedding.sentenceEmbedding(for: .english) != nil)
            loaded.signal()
        }
        _ = loaded.wait(timeout: .now() + 10)
        return flag.value
    }()

    public init() {
        let emb = Self.probeSucceeded ? NLEmbedding.sentenceEmbedding(for: .english) : nil
        embedding = emb
        // Include the dimension so an OS update that changes the sentence model's vector size mints a
        // NEW identifier — old, incompatible vectors are then re-indexed instead of silently scoring
        // 0 against every query (cosine() returns 0 on a length mismatch), which would disable recall.
        identifier = "apple-nl-sentence-en-d\(emb?.dimension ?? 0)"
    }

    public var isAvailable: Bool { embedding != nil }

    public func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let vector = embedding?.vector(for: trimmed) else { return nil }
        return vector.map { Float($0) }
    }
}
