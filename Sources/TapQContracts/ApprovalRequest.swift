import Foundation

/// An agent action awaiting a hands-free allow/deny.
///
/// `summary` is a short spoken verb phrase ("run npm test"); `detail` is the fuller
/// text spoken only when the user asks for details. The agent-specific rendering of a
/// tool call into these strings lives in its adapter, keeping the runtime agnostic.
public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    /// What kind of yes/no the user is being asked for — it changes only the spoken
    /// phrasing, never the input mapping (nod/voice-yes → allow, shake/voice-no → deny).
    public enum Kind: String, Sendable, Equatable {
        /// A tool call awaiting permission: "The agent wants to …. Approve?"
        case toolApproval
        /// A yes/no question found in an agent's reply: "The agent asks: …. Yes or no?"
        case question
    }

    public let id: String
    public let sessionID: String
    public let agent: AgentIdentity
    public let toolName: String
    public let summary: String
    public let detail: String
    public let kind: Kind

    public init(id: String, sessionID: String, agent: AgentIdentity = .unknown,
                toolName: String, summary: String, detail: String,
                kind: Kind = .toolApproval) {
        self.id = id
        self.sessionID = sessionID
        self.agent = agent
        self.toolName = toolName
        self.summary = summary
        self.detail = detail
        self.kind = kind
    }
}
