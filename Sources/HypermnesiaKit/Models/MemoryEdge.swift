import Foundation

/// A typed relationship between two memories. Raw values are snake_case (matches the original
/// shipped wire format). Most edges are *inferred* on the client from shared files/sessions/type;
/// a few (supersedes, implements) are explicit. See `docs/design/05-graph-and-visualization.md`.
public enum MemoryEdgeType: String, Codable, CaseIterable, Sendable, Hashable {
    case implements = "implements"            // Decision → Intent
    case implementedBy = "implemented_by"     // Intent → CodeRef
    case supersedes = "supersedes"            // Decision → Decision (older)
    case creates = "creates"                  // Decision → Concern
    case affects = "affects"                  // Concern → CodeRef
    case affectsIntent = "affects_intent"     // Concern → Intent
    case learnedFrom = "learned_from"         // Convention → Conversation
    case mentionedIn = "mentioned_in"         // Node → Conversation
    case relatedTo = "related_to"             // Node ↔ Node (general)

    /// Dash pattern for the edge line (resolved to a stroke style in the app layer). `nil` = solid.
    public var lineDash: [Double]? {
        switch self {
        case .supersedes: [4, 4]
        case .relatedTo: [2, 2]
        case .learnedFrom, .mentionedIn: [6, 3]
        default: nil
        }
    }

    /// Whether the edge is directional (drawn with an arrowhead).
    public var hasArrow: Bool {
        switch self {
        case .relatedTo, .learnedFrom, .mentionedIn: false
        default: true
        }
    }
}

/// An edge between two memory nodes.
public struct MemoryEdge: Identifiable, Codable, Equatable, Sendable, Hashable {
    public var id: String { "\(source)-\(relationship.rawValue)-\(target)" }
    public var projectId: String
    public let source: String
    public let target: String
    public let relationship: MemoryEdgeType
    /// Inference metadata (e.g. how strong, what it was inferred from).
    public var properties: [String: String]?
    public let createdAt: Date

    public init(
        projectId: String,
        source: String,
        target: String,
        relationship: MemoryEdgeType,
        properties: [String: String]? = nil,
        createdAt: Date = Date()
    ) {
        self.projectId = projectId
        self.source = source
        self.target = target
        self.relationship = relationship
        self.properties = properties
        self.createdAt = createdAt
    }
}
