import Foundation

/// The timing chain for a *held* turn boundary, kept apart from ``InteractionBudget``
/// because it measures something else entirely.
///
///     broker poll (60s) < shim socket timeout (75s) ≪ Stop hook timeout (~24.9 days)
///
/// `InteractionBudget`'s numbers are sized for a question somebody is blocked on: a wearer
/// has to hear a prompt and answer it before the agent's hook gives up, so every number
/// there is as small as the interaction allows. Nothing is blocked here. A voice session's
/// Stop hook is *deliberately* idle — the model is not running, no tokens are being spent,
/// and the only cost of waiting is that the terminal shows a hook in flight.
///
/// **A voice session is not ended by time** (ratified 2026-08-28). It ends when the wearer
/// ends it with a gesture or a tap, when the voice pipeline breaks, or when the runtime
/// goes away. The numbers below are therefore not a budget for the session: they are the
/// lease renewal interval of a boundary that is held for as long as those three things
/// have not happened.
///
/// The shape is a **renewable lease**. The shim parks for one `brokerPoll`, the broker
/// answers `renew` when that poll's bound elapses with nothing to deliver, and the shim
/// re-parks — indefinitely many times inside a single hook invocation. The broker keeps the
/// boundary registered across the microseconds between polls (see `leaseGrace`), so the
/// wearer never hears the listening loop stop and start. Nothing about a renewal reaches
/// the agent: from Claude Code's side one Stop hook is running, exactly as before.
///
/// Why poll at all rather than park once forever: a bounded poll is how a *dead* peer is
/// noticed. Each poll is a fresh connection, so a runtime that has exited or wedged fails
/// the next one and the hook returns within `brokerPoll` instead of hanging on a socket
/// nobody will ever answer — and on the broker's side a hook that was killed stops renewing
/// and its lease expires, rather than parking a connection thread for the life of the run.
///
/// The ordering discipline is the one it always was: the broker must answer before the
/// shim's socket gives up, and the shim must give up before the agent kills the hook, or
/// the wearer's next instruction lands in a socket nobody is reading.
public enum VoiceSessionBudget {
    /// How long the broker holds a turn boundary open before answering `renew` — one round
    /// of a renewable lease, not the life of the session.
    ///
    /// A minute is chosen for what it costs when things go wrong rather than for what it
    /// buys when they go right: it is how long a killed hook's connection thread stays
    /// parked, and how long a wedged runtime can keep a boundary from being released.
    /// Nothing the wearer experiences is on this clock — a renewal is invisible.
    public static let brokerPoll: TimeInterval = 60

    /// How long a lease survives with no poll in flight before the broker lets it go.
    ///
    /// The gap between one poll returning and the next arriving is microseconds, so this is
    /// not sized for the gap: it is the window in which a hook that was *killed* stops
    /// being a held boundary. Long enough that a slow re-poll is never mistaken for a dead
    /// hook, short enough that TapQ stops listening for a hook that is gone within
    /// `brokerPoll + leaseGrace` of it dying.
    public static let leaseGrace: TimeInterval = 30

    /// The one-shot budget, kept for a shim that presents no lease.
    ///
    /// An installed shim is a binary on someone's disk. One from before renewable leases
    /// sends a single `instruction.wait` with no `lease_id` and expects one answer, so the
    /// broker gives that request exactly the budget it was built against and the older
    /// pairing behaves precisely as it shipped: ten minutes, then the Stop proceeds.
    public static let brokerWait: TimeInterval = 600

    /// How long the shim waits on the broker socket for one poll's answer.
    public static let shimSocketTimeout: TimeInterval = brokerPoll + 15

    /// The `timeout` written into the Stop hook's configuration: the largest value the
    /// agent will honor, because the decision is that time never ends a voice session and
    /// this is the only place time still can.
    ///
    /// Claude Code's hook `timeout` is a positive number of seconds with no maximum in its
    /// settings schema, and it reaches the runtime as `setTimeout(…, timeout * 1000)` with
    /// no clamp. The ceiling is therefore the JavaScript timer's, not the schema's: a delay
    /// above `Int32.max` milliseconds is rejected as an overflow and re-set to 1 ms, which
    /// would kill the hook *immediately* — the opposite of what is wanted. So the value is
    /// `Int32.max` milliseconds expressed in whole seconds, 2 147 483 s ≈ 24.9 days.
    /// (Verified 2026-08-28 against the installed Claude Code build: the command-hook
    /// schema is `timeout: number().positive().optional()`; the per-hook branch is
    /// `hook.timeout ? hook.timeout * 1000 : default`; and the overflow behavior was
    /// reproduced directly — `TimeoutOverflowWarning … duration was set to 1`.)
    ///
    /// This is the one residual way a voice session can end on a clock, and it is the
    /// agent's clock rather than TapQ's. Nothing in this process is waiting for it.
    public static let hookTimeout: TimeInterval = 2_147_483
}
