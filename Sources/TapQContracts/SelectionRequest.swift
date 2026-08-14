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
    /// One spoken sentence of context, said once before the first option and never
    /// again — not on navigation, not on an explicit repeat.
    ///
    /// Presentation only, and in-process only: no wire message carries it, so a request
    /// that arrived from an agent adapter always has `nil` here. The stop-question path
    /// sets it from a spoken summary of the agent's final reply, and only when a
    /// summarizer is configured — `nil` restores the pre-summary prompt word for word.
    public let spokenPreamble: String?

    public init(id: String, sessionID: String, agent: AgentIdentity = .unknown,
                question: String, options: [SelectionOption], multiSelect: Bool = false,
                spokenPreamble: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.agent = agent
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.spokenPreamble = spokenPreamble
    }
}
