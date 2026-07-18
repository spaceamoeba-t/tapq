import Foundation

/// Identifies the agent adapter that originated a normalized broker request.
///
/// The runtime uses this only for presentation and diagnostics. Agent-specific event
/// parsing and tool rendering stay in adapter modules such as `TapQClaudeAdapter`.
public struct AgentIdentity: Sendable, Codable, Equatable, Hashable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    /// Used for legacy clients that predate agent identity on the wire.
    public static let unknown = AgentIdentity(id: "unknown", displayName: "The agent")

    /// Identity emitted by the bundled Claude Code adapter.
    public static let claudeCode = AgentIdentity(id: "claude-code", displayName: "Claude Code")

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}
