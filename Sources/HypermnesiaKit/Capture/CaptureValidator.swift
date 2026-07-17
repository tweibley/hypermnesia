import Foundation

/// A deterministic, LLM-free quality gate that runs after the classifier and before
/// memories are persisted. It catches two failure modes found in production:
///   1. Degenerate output — empty/whitespace/meaningless summaries that add no value.
///   2. Incomplete captures — memories that gesture at a contract or prohibition without
///      actually recording the literal shape or the "never do X" clause.
///
/// Rules are intentionally conservative: a false-positive (suppressing a good memory) is
/// worse than a false-negative (letting a weak one through). Only flag clear cases.
public enum CaptureValidator {

    // MARK: - Public API

    public enum Verdict: Equatable, Sendable {
        /// Memory looks complete — persist as-is.
        case ok
        /// Memory is incomplete or vague — keep it, but cap confidence so reviewers know it's
        /// worth a second look. The `reason` describes the specific gap found.
        case weak(reason: String)
        /// Memory is degenerate (no real content) — drop it entirely.
        case reject(reason: String)
    }

    /// Confidence ceiling applied to a `.weak` verdict when rewriting `ClassifiedMemory.confidence`.
    public static let weakConfidenceCeiling: Double = 0.55

    /// Assess one classifier output. Pure function — no side effects, no I/O.
    ///
    /// Operate on `m.summary` (and `m.title` for the degenerate check). Types that are not
    /// susceptible to a given rule simply don't trigger it; all other types are assessed for the
    /// degeneracy rules only.
    public static func assess(_ m: ClassifiedMemory) -> Verdict {
        let title   = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = m.summary.trimmingCharacters(in: .whitespacesAndNewlines)

        // ── Type classification ────────────────────────────────────────────────────────────────
        // Behavioural types (convention, decision, intent, concern) carry contracts and rules that
        // need a meaningful summary. Data types (fact, backlog, codeRef) can be legitimately terse
        // (a fact might just be "SQLite 3.45" — a key-value recording).
        let isBehaviouralType = m.type == .convention || m.type == .decision
                             || m.type == .intent     || m.type == .concern
        let isContractType    = m.type == .convention || m.type == .decision
        let isDetailableType  = isContractType || m.type == .concern

        // ── 1. Degenerate: empty — applies to all types ───────────────────────────────────────
        guard !title.isEmpty, !summary.isEmpty else {
            return .reject(reason: "title or summary is empty")
        }

        // ── 2. Degenerate: too short — applies only to behavioural types ──────────────────────
        // Data types (fact, backlog, codeRef) may legitimately be very short ("v2.3", "SQLite").
        if isBehaviouralType, summary.count < 12 {
            return .reject(reason: "summary is too short (\(summary.count) chars) to contain useful information")
        }

        // ── 3. Degenerate: summary is just the title restated ─────────────────────────────────
        // e.g. title "Use async/await", summary "Use async/await." — no added content.
        if isMereParaphrase(of: title, in: summary) {
            return .reject(reason: "summary adds no content beyond the title")
        }

        if isContractType {
            // ── 4. Contract referenced but no literal shape captured ──────────────────────────
            if mentionsContractConcept(summary) && !hasLiteralShapeEvidence(summary) {
                return .weak(reason: "contract referenced but no literal shape captured")
            }

            // ── 5. Replacement implied but no explicit prohibition captured ───────────────────
            if impliesReplacement(summary) && !hasExplicitProhibition(summary) {
                return .weak(reason: "replacement implied but no explicit prohibition captured")
            }
        }

        if isDetailableType {
            // ── 6. Too vague / low-detail ─────────────────────────────────────────────────────
            if isLowDetail(summary) {
                return .weak(reason: "summary is too vague or short to be actionable")
            }
        }

        return .ok
    }

    // MARK: - Private helpers

    /// Returns true when `summary` is essentially just `title` with minor punctuation/casing
    /// differences (e.g. the classifier echoed the title back as the summary).
    private static func isMereParaphrase(of title: String, in summary: String) -> Bool {
        let normalised = { (s: String) -> String in
            s.lowercased()
             .trimmingCharacters(in: .whitespacesAndNewlines)
             .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?"))
        }
        let t = normalised(title)
        let s = normalised(summary)
        guard !t.isEmpty else { return false }
        // Exact match or summary is just the title with a trailing period / trivial suffix.
        return s == t || (s.hasPrefix(t) && s.dropFirst(t.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Keywords that imply a contract/shape is being described but must be accompanied by
    /// literal evidence to be actionable.
    private static let contractKeywords: [String] = [
        "format", "shape", "schema", "envelope", "response",
        "error body", "status code", "signature", "fields", "payload", "json",
    ]

    private static func mentionsContractConcept(_ text: String) -> Bool {
        let lower = text.lowercased()
        return contractKeywords.contains { lower.contains($0) }
    }

    /// "Literal shape evidence" means the summary contains at least one concrete structural
    /// token: a JSON-ish fragment `{...}`, a call-signature `(...)`, a key:value pair, or a
    /// backtick-quoted code token.
    private static func hasLiteralShapeEvidence(_ text: String) -> Bool {
        // JSON-ish fragment: at least an opening brace followed eventually by a closing brace.
        if let lb = text.firstIndex(of: "{"), let rb = text.lastIndex(of: "}"), lb < rb {
            return true
        }
        // Call-signature: something(…) — at least one open + close paren pair.
        if let lp = text.firstIndex(of: "("), let rp = text.lastIndex(of: ")"), lp < rp {
            return true
        }
        // Key:value pair — a word immediately followed by `:` and a non-whitespace character.
        // e.g. `"error": "…"` or `code: 404`.
        let kvPattern = #"\w+\s*:\s*\S"#
        if text.range(of: kvPattern, options: .regularExpression) != nil {
            return true
        }
        // Backtick-quoted code token: `someIdentifier`.
        if text.contains("`") && text.filter({ $0 == "`" }).count >= 2 {
            return true
        }
        return false
    }

    /// Keywords that indicate the memory describes a "we moved from X to Y" situation —
    /// which must also state the prohibition to be complete.
    private static let replacementKeywords: [String] = [
        "instead of", "replace", "rather than", "use \u{2026} not",
        "fixed", "switched to", "migrated from",
        // Also common fragments the classifier produces:
        "moved from", "changed from", "changed to", "transition",
    ]

    private static func impliesReplacement(_ text: String) -> Bool {
        let lower = text.lowercased()
        // "use ... not" is a phrase — handle by checking for "use" and "not" in proximity.
        // For the rest, a simple substring check is sufficient.
        let simpleMatches = ["instead of", "replace", "rather than", "fixed", "switched to",
                             "migrated from", "moved from", "changed from", "changed to", "transition"]
        if simpleMatches.contains(where: { lower.contains($0) }) {
            return true
        }
        // "use X not Y" — "use" appears before "not" within 60 chars
        if let useRange = lower.range(of: "use ") {
            let after = String(lower[useRange.upperBound...])
            if after.prefix(60).contains(" not ") {
                return true
            }
        }
        return false
    }

    /// Explicit prohibition markers — the memory says "never do X" or equivalent.
    private static let prohibitionKeywords: [String] = [
        "never", "not ", "don't", "do not", "avoid", "must not",
        // Also accept "no longer", "stop", "prohibited", "disallowed" for completeness.
        "no longer", "stop using", "prohibited", "disallowed",
    ]

    private static func hasExplicitProhibition(_ text: String) -> Bool {
        let lower = text.lowercased()
        return prohibitionKeywords.contains { lower.contains($0) }
    }

    /// Vague / low-detail heuristics.
    private static let vagueTemplates: [String] = [
        "use the helper",
        "follow the convention",
        "be consistent",
        "use the pattern",
        "follow the pattern",
        "use the existing",
        "follow the existing",
    ]

    private static func isLowDetail(_ summary: String) -> Bool {
        // Very short summary (< ~25 chars) — not enough room for specifics.
        guard summary.count >= 25 else { return true }
        // Matches a known vague template with no additional specifics.
        let lower = summary.lowercased()
        return vagueTemplates.contains { lower.hasPrefix($0) && summary.count < ($0.count + 10) }
    }
}
