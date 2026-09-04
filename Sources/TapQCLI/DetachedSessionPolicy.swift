import Foundation
import TapQContracts

/// What a detached session's hooks get (`docs/SESSION_FOCUS_PLAN.md` §2).
///
/// A detached session is one that had TapQ's focus and lost it to a newer session. It is
/// still running, still sending hooks, and it must never again reach the wearer through
/// TapQ — nor wait on TapQ for anything. So every hook it sends is answered at once, in
/// silence, with the answer that leaves the session exactly as it would be with no TapQ at
/// all. These are those answers, in one place, so the runtime's five handlers read one rule
/// rather than five opinions.
///
/// Pure values. The handlers still record what the memory needs (a notification is written
/// to session memory so "what changed" stays complete) and log a diagnostic per answer.
public enum DetachedSessionPolicy {
    /// An approval from a detached session: to the screen at once, nothing spoken. The
    /// agent's own on-screen prompt decides, as it did before TapQ existed.
    ///
    /// A session TapQ started has no screen, so for it the answer is a denial — and a
    /// denial is what winds it down, one tool at a time, inside its detach grace.
    public static func approval(ownedByTapQ: Bool) -> Decision {
        ownedByTapQ ? .deny : .ask
    }

    /// A selection from a detached session: no choice, at once. The broker reports a
    /// timeout and the shim falls through to the agent's own picker.
    public static let selection = SelectionResult.noSelection

    /// A stop question from a detached session: no reply, so the Stop proceeds. Nothing is
    /// narrated and nothing is delivered — its queued instructions were dropped at the
    /// switch.
    public static let stopQuestionReply: String? = nil

    /// The diagnostic name every detached answer is logged under, with the hook as a field.
    public static let diagnosticName = "detached.answered"
}
