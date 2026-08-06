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
    /// Free-text answer from the wearer, when the selection was resolved by a spoken
    /// free-form reply rather than choosing a listed option. A result with `freeText != nil`
    /// and empty `choices` is a resolution, not a timeout.
    public let freeText: String?

    public init(choices: [Choice], timedOut: Bool = false, freeText: String? = nil) {
        self.choices = choices
        self.timedOut = timedOut
        self.freeText = freeText
    }

    /// A sentinel value for "no selection" (empty choices, timed out).
    public static let noSelection = SelectionResult(choices: [], timedOut: true)
}
