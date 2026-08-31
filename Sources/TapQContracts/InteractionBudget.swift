import Foundation

/// Single source of truth for the hands-free timing chain:
///
///     interaction total (245s) < shim socket timeout (255s) < hook timeout (260s)
///
/// Agent lifecycle hooks are configured with `hookTimeout`; each shim gives up on the
/// broker socket at `shimSocketTimeout` and fails open. Therefore the entire spoken
/// interaction — queue wait, TTS, and every re-listen after `repeat`/`details` — must
/// resolve within `total`, or the user's answer lands in a socket nobody is reading.
public enum InteractionBudget {
    /// Wall-clock budget for one approval/selection, measured from the moment the
    /// request arrives at the broker (not from when it reaches the front of the queue).
    public static let total: TimeInterval = 245
    /// How long the hook shim waits on the broker socket before failing open.
    public static let shimSocketTimeout: TimeInterval = total + 10
    /// The per-hook timeout written into each agent's hook configuration.
    public static let hookTimeout: TimeInterval = shimSocketTimeout + 5
    /// Longest a single listen window may be, leaving TTS headroom inside `total`.
    public static let maxListenWindow: TimeInterval = total - 5

    // The viability floor — "is there enough budget left to even ask?" — is deliberately
    // NOT here.
    //
    // It used to be, as a hand-picked twelve seconds, and being here is why it was wrong:
    // the answer is a number of characters divided by a speaking rate, and this module knows
    // nothing about either. It could not see that the presenters' own maximum prompts are
    // longer than twelve seconds of speech on the slower voice, so a maximum-length prompt
    // spent the entire margin before the question had finished being asked. The derivation
    // now lives with the pace model that can state it — `SpokenPace.viableSeconds` in
    // `TapQInteractionBaseline` — and each controller reads its own presenter's bound
    // through it. `SpokenPace.minimumListenSeconds` is the same arithmetic exported for the
    // command line's `--timeout` floor.
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
