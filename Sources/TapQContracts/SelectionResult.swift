import Foundation

/// The outcome of a hands-free selection request.
///
/// Contains a list of user choices (each with an index into the original options
/// and its label). If the selection timed out (no response within the timeout window),
/// `timedOut` is `true` and `choices` will be empty.
public struct SelectionResult: Sendable, Equatable {
    /// A single user choice: the index and label of a selected option.
    public struct Choice: Sendable, Equatable {
        public let index: Int
        public let label: String

        public init(index: Int, label: String) {
            self.index = index
            self.label = label
        }
    }

    public let choices: [Choice]
    public let timedOut: Bool

    public init(choices: [Choice], timedOut: Bool = false) {
        self.choices = choices
        self.timedOut = timedOut
    }

    /// A sentinel value for "no selection" (empty choices, timed out).
    public static let noSelection = SelectionResult(choices: [], timedOut: true)
}
