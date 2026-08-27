import Foundation

/// The timing chain for a *held* turn boundary, kept apart from ``InteractionBudget``
/// because it measures something else entirely.
///
///     broker wait budget (600s) < shim socket timeout (615s) < Stop hook timeout (620s)
///
/// `InteractionBudget`'s numbers are sized for a question somebody is blocked on: a wearer
/// has to hear a prompt and answer it before the agent's hook gives up, so every number
/// there is as small as the interaction allows. Nothing is blocked here. A voice session's
/// Stop hook is *deliberately* idle — the model is not running, no tokens are being spent,
/// and the only cost of waiting is that the terminal shows a hook in flight — so the budget
/// is sized for how long a person plausibly steps away from a conversation instead.
///
/// The ordering is the same discipline and exists for the same reason: the broker must
/// answer before the shim's socket gives up, and the shim must give up before Claude Code
/// kills the hook, or the wearer's next instruction lands in a socket nobody is reading.
public enum VoiceSessionBudget {
    /// How long the broker holds a turn boundary open before answering "no instruction".
    ///
    /// One long-poll round, not a loop: at the end of it the Stop proceeds and the session
    /// idles normally, which is a clean exit from the mode rather than a failure. A wearer
    /// who wanted longer says the next instruction into the next session.
    public static let brokerWait: TimeInterval = 600
    /// How long the shim waits on the broker socket for that answer.
    public static let shimSocketTimeout: TimeInterval = brokerWait + 15
    /// The `timeout` written into the Stop hook's configuration. Without it, the agent's
    /// own default would kill a hook that is doing exactly what it was asked to do.
    public static let hookTimeout: TimeInterval = shimSocketTimeout + 5
}
