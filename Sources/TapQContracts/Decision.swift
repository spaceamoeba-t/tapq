import Foundation

/// The outcome a TapQ runtime returns for an approval request.
/// `ask` means "no hands-free answer" — defer to the agent's normal on-screen prompt.
public enum Decision: String, Sendable, Equatable {
    case allow
    case deny
    case ask
}
