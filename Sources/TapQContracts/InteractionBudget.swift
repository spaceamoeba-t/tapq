import Foundation

/// Single source of truth for the hands-free timing chain:
///
///     interaction total (105s) < shim socket timeout (115s) < hook timeout (120s)
///
/// Claude Code's PreToolUse hook is configured with `hookTimeout`; the shim gives up on
/// the broker socket at `shimSocketTimeout` and fails open; therefore the entire spoken
/// interaction — queue wait, TTS, and every re-listen after `repeat`/`details` — must
/// resolve within `total`, or the user's answer lands in a socket nobody is reading.
public enum InteractionBudget {
    /// Wall-clock budget for one approval/selection, measured from the moment the
    /// request arrives at the broker (not from when it reaches the front of the queue).
    public static let total: TimeInterval = 105
    /// How long the hook shim waits on the broker socket before failing open.
    public static let shimSocketTimeout: TimeInterval = total + 10
    /// The per-hook timeout written into Claude Code's settings.json.
    public static let hookTimeout: TimeInterval = shimSocketTimeout + 5
    /// Don't START an interaction with less than this much budget left: enough to speak
    /// a typical prompt and still leave the user time to answer inside the shim window.
    /// A request that queued past this threshold defers silently — its asker is better
    /// served by the on-screen prompt than by a question it can't answer.
    public static let minViableRemaining: TimeInterval = 12
    /// Longest a single listen window may be, leaving TTS headroom inside `total`.
    public static let maxListenWindow: TimeInterval = total - 5
}

public extension ContinuousClock.Instant {
    /// Seconds from now until this instant. Negative when the instant has passed.
    var secondsFromNow: TimeInterval { seconds(after: .now) }

    /// Seconds from `reference` until this instant. Negative when this instant precedes
    /// it. The controllers pass their injectable `now` here so deadline tests can drive
    /// a virtual clock.
    func seconds(after reference: ContinuousClock.Instant) -> TimeInterval {
        let parts = reference.duration(to: self).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
