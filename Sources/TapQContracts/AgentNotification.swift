import Foundation

/// A non-blocking spoken update about the agent's state.
public struct AgentNotification: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case waitingForInput
        case permissionWaiting
        case finished
    }

    public let sessionID: String
    public let agent: AgentIdentity
    public let kind: Kind
    public let summary: String?

    public init(sessionID: String, agent: AgentIdentity = .unknown,
                kind: Kind, summary: String? = nil) {
        self.sessionID = sessionID
        self.agent = agent
        self.kind = kind
        self.summary = summary
    }
}
