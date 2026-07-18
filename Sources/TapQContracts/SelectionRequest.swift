import Foundation

/// A single selection option presented to the user.
public struct SelectionOption: Sendable, Equatable {
    public let label: String
    public let description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

/// A hands-free selection prompt: agent asks the user to choose one or more options.
///
/// The agent provides a `question`, a list of `options`, and a `multiSelect` flag.
/// A TapQ host presents these to the user (via head gestures, voice, or UI) and returns
/// a `SelectionResult` with the chosen option indices.
public struct SelectionRequest: Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let agent: AgentIdentity
    public let question: String
    public let options: [SelectionOption]
    public let multiSelect: Bool

    public init(id: String, sessionID: String, agent: AgentIdentity = .unknown,
                question: String, options: [SelectionOption], multiSelect: Bool = false) {
        self.id = id
        self.sessionID = sessionID
        self.agent = agent
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }
}
