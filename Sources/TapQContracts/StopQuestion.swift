import Foundation

/// Claude's final text reply, forwarded by the Stop hook because it may contain an
/// unanswered question (the shim pre-filters for a "?" before sending).
public struct StopQuestion: Sendable, Equatable {
    public let sessionID: String
    public let agent: AgentIdentity
    public let text: String

    public init(sessionID: String, agent: AgentIdentity = .unknown, text: String) {
        self.sessionID = sessionID
        self.agent = agent
        self.text = text
    }
}
