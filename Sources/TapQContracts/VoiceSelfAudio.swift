import Foundation

/// What TapQ's own voice is doing in the room, as the thing rendering it knows.
///
/// It exists because two components that never meet — the realtime adapter, which sees a
/// remote VAD say "speech started", and the microphone pump, which decides what audio leaves
/// this machine — both have to answer the same question: *was that TapQ?* On a run with no
/// AirPods every sentence TapQ says goes out of the Mac's speaker into the open microphone,
/// so "the wearer spoke" and "TapQ spoke and the microphone heard it" are the same event on
/// the wire, and nothing downstream of the microphone can tell them apart.
///
/// The value is a *span* rather than a bare `isPlaying` flag, and that is the whole of its
/// design. The events this is compared against arrive late — a semantic VAD reports where
/// speech began some hundreds of milliseconds after the audio was appended, and the report
/// still has to cross a socket — so by the time TapQ asks, the playback that caused them has
/// usually already drained. A flag sampled then says "silent" and the echo is taken for the
/// wearer, which is exactly the 2026-08-30 defect. Knowing when the sound started and
/// stopped lets a caller ask about the instant it cares about instead of about now.
public struct VoiceSelfAudioActivity: Equatable, Sendable {
    /// When the current — or most recent — stretch of TapQ's own audio began sounding, on
    /// the same monotonic clock the caller stamps its own events with. `nil` before TapQ has
    /// said anything at all.
    public let startedAt: TimeInterval?
    /// When that stretch stopped, or `nil` while it is still sounding.
    public let stoppedAt: TimeInterval?

    public init(startedAt: TimeInterval? = nil, stoppedAt: TimeInterval? = nil) {
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
    }

    /// A renderer that has never played anything, and the honest answer for a composition
    /// that wires no player at all: TapQ has no voice here, so nothing can be TapQ's echo.
    public static let silent = VoiceSelfAudioActivity()

    /// TapQ's audio is reaching the speaker right now.
    public var isSounding: Bool { startedAt != nil && stoppedAt == nil }

    /// Whether TapQ's own voice was in the room at `instant`.
    ///
    /// `hysteresis` extends the span *forward* only, and it covers two different lags with
    /// one number: the room (a speaker does not stop being audible the moment the last
    /// sample is handed to the hardware — output latency and reverb both outlive the buffer)
    /// and the report (a remote VAD's "speech started" for that tail arrives after it).
    /// Extending backwards would be wrong in a way the forward extension is not: speech
    /// detected *before* TapQ started speaking cannot be TapQ, and treating it as such would
    /// throw away the wearer's own opening words.
    ///
    /// Only the most recent span is knowable from one sample, which is why callers evaluate
    /// this at the moment an event arrives rather than saving instants up and asking later.
    public func wasAudible(at instant: TimeInterval, hysteresis: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        guard instant >= startedAt else { return false }
        guard let stoppedAt else { return true }
        return instant <= stoppedAt + max(0, hysteresis)
    }
}

/// How long after TapQ stops speaking the microphone is still assumed to be hearing TapQ.
public enum VoiceSelfAudioEcho {
    /// 600 ms, and the number is a sum rather than a guess: an `AVAudioPlayerNode` reports a
    /// buffer complete when it has been handed to the hardware rather than when it has been
    /// heard, a Mac speaker in a small room rings for a beat after that, and the service's
    /// own report of the speech it heard crosses a socket before TapQ can act on it. Short
    /// enough that a wearer answering promptly is still heard; long enough that TapQ
    /// answering itself is not.
    public static let defaultHysteresis: TimeInterval = 0.6

    /// The tuning seam, following the convention `TAPQ_TURN_EAGERNESS` set: an environment
    /// key rather than a flag, because this is a property of a room and a machine, not of a
    /// run an operator is composing.
    public static let hysteresisEnvironmentKey = "TAPQ_SELF_AUDIO_HYSTERESIS_MS"

    /// The largest value this knob will take. A hysteresis longer than a couple of seconds
    /// stops being echo suppression and becomes a microphone that ignores the wearer, so a
    /// mistyped value is clamped rather than obeyed.
    public static let maximumHysteresis: TimeInterval = 2.0

    /// The hysteresis this run uses: the environment override when it names a number TapQ
    /// can read, otherwise ``defaultHysteresis``.
    ///
    /// An unreadable value falls back rather than throwing, for the reason
    /// `RealtimeDefaults.resolvedTurnEagerness` does: a misspelled tuning knob must not be
    /// why a wearer's only channel refuses to start.
    public static func resolvedHysteresis(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        guard let raw = environment[hysteresisEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let milliseconds = Double(raw),
            milliseconds.isFinite else { return defaultHysteresis }
        return min(max(0, milliseconds / 1_000), maximumHysteresis)
    }
}
