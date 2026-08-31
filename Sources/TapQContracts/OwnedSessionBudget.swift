import Foundation

/// The timing chain for a session TapQ *started*, kept apart from ``VoiceSessionBudget`` for
/// the same reason that one is kept apart from ``InteractionBudget``: it measures something
/// else.
///
///     sweep interval (15s) ≪ contact timeout (120s) ≪ a session's life (unbounded)
///
/// ``VoiceSessionBudget`` bounds a boundary that is deliberately held open for as long as the
/// wearer wants. Nothing here bounds a session either — an owned session ends when its work
/// ends, when the wearer ends it, or when TapQ goes away. What these numbers bound is the
/// *startup*: the window in which a spawn either becomes a session TapQ can see or is
/// admitted to have failed.
///
/// That window exists because a spawned `claude` announces nothing. It reports in the only
/// way TapQ can observe — its hooks reach the broker — and until they do, "starting" and
/// "started and invisible" look identical from here. The second is the dangerous one: the
/// wearer's goal is being worked on somewhere they cannot instruct, cannot interrupt, and
/// cannot approve for. So the startup window is the one place a clock still ends an owned
/// session.
public enum OwnedSessionBudget {
    /// How long a spawned session has to reach the broker before TapQ concludes it never
    /// will, kills the child, and says so.
    ///
    /// Two minutes is sized against the *slowest honest* first contact rather than against
    /// startup. The shim reaches the broker on the first tool approval, the first
    /// notification, or the turn's Stop — whichever comes first — so a session that does any
    /// work at all reports in within seconds. The long tail is a prompt answered in prose
    /// with no tool call, where first contact is the Stop at the end of the turn; two minutes
    /// covers a long one of those with room to spare.
    ///
    /// It is generous because it is not the main detector. A spawn that fails for the usual
    /// reasons — a flag the installed build rejects, an unauthenticated CLI — exits, and an
    /// exit is noticed within one ``sweepInterval`` regardless of this number. This covers
    /// only the case where the process lives and its hooks do not arrive, which the
    /// hooks-installed precondition already makes rare.
    public static let contactTimeout: TimeInterval = 120

    /// How often the composition asks the launcher to look at its children.
    ///
    /// Fifteen seconds is chosen for the failure it shortens: an exited child that never
    /// reported in is the common spawn failure, and the wearer hears about it within a sweep.
    /// It is not a poll of anything expensive — the sweep reads a small dictionary and asks
    /// the runner whether each pid is still alive — and it has nothing to do while no session
    /// is owned.
    public static let sweepInterval: TimeInterval = 15

    /// How long a terminated child is given to exit on `SIGTERM` before it is killed.
    ///
    /// The same half-second the Codex probe's runner allows, doubled: this child is an agent
    /// mid-turn rather than a diagnostic command, and it deserves the chance to close its
    /// transcript.
    public static let terminationGrace: TimeInterval = 1

    /// The longest goal that is passed to the agent as a prompt argument.
    ///
    /// A bound on an argument vector, not on what a wearer may ask for: spoken goals are
    /// sentences, and 4 096 characters is far past any of them while staying far below the
    /// system's argument limit. A transcript that ran away — a recognizer that never
    /// endpointed — is truncated rather than allowed to fail the spawn.
    public static let maximumGoalCharacters = 4_096
}
