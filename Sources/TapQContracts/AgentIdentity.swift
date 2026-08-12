import Foundation

/// Identifies the agent adapter that originated a normalized broker request.
///
/// The runtime uses this only for presentation and diagnostics. Agent-specific event
/// parsing and tool rendering stay in adapter modules such as `TapQClaudeAdapter` and
/// `TapQCodexAdapter`.
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

    /// Identity emitted by the bundled Codex adapter.
    public static let codex = AgentIdentity(id: "codex", displayName: "Codex")

    /// Identity emitted by the bundled Cursor adapter.
    public static let cursor = AgentIdentity(id: "cursor", displayName: "Cursor")

    /// Identity emitted by the bundled OpenCode adapter.
    public static let openCode = AgentIdentity(id: "opencode", displayName: "OpenCode")

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}
