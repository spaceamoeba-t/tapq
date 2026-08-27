import Foundation
import TapQContracts

/// Whether TapQ's own wearer turn signal — the in-ear IMU endpointing path — is something
/// this run can actually end turns with.
///
/// One question, asked at each window open, whose answer decides whether TapQ keeps turn
/// arbitration or hands end-of-speech detection to the backend (the carve-out documented on
/// `VoiceBackend`). It is deliberately not the same question `WearerSpeechSignaling`
/// answers, and the difference is the reason this type exists at all:
///
/// - `isSignalAvailable` describes **now**: is a fresh, per-axis motion sample in hand this
///   instant. Between windows the motion stream is stopped — every arbiter `finish()` stops
///   the detector — so it reads false during exactly the moment the decision has to be
///   made, on a run whose AirPods are working perfectly.
/// - `isLive` describes **this run**: is there reason to believe an IMU endpoint will fire
///   when the wearer stops talking. That is a claim about hardware, not about the last 200
///   milliseconds of it.
///
/// So the default is optimism, and it is retracted only by evidence. A run with
/// `--imu-turn-control` starts live: the flag says AirPods are expected, and starting
/// degraded would change the behavior of the working path — the case the carve-out is
/// explicitly not for. A confirmed motion loss retracts it, which is what catches the
/// availability lie macOS tells about AirPods that are paired but sitting in their case:
/// `isDeviceMotionAvailable` answers true, no sample ever arrives, and the detector reports
/// `neverStreamed` a bounded moment into the first window. From then on the run is degraded.
/// A sample arriving later — the wearer put the AirPods in mid-run — restores it, and the
/// next window switches back.
///
/// A run without the flag has no signal at all and is never live: there is no coordinator
/// listening, so nothing would ever commit the turn.
///
/// Nothing here polls, schedules, or holds a timer. It reads the signal when asked and
/// listens for the transitions it already broadcasts, so a run that never consults it pays
/// nothing for it.
@MainActor public final class WearerTurnSignalLiveness {
    private let signal: (any WearerSpeechSignaling)?

    /// Set when the motion channel has been *confirmed* absent — not merely quiet. Retracts
    /// the optimism above until a real sample proves the hardware is back.
    private var motionConfirmedAbsent = false

    /// - Parameter signal: a `WearerSpeechSignaling` child, or `nil` for a run with no IMU
    ///   turn control at all. A child rather than the source itself: this claims its own
    ///   `onWearerSpeakingChange`, and the coordinator claims a different child's.
    public init(signal: (any WearerSpeechSignaling)?) {
        self.signal = signal
        signal?.onWearerSpeakingChange = { [weak self] _ in
            self?.noteSignalObserved()
        }
    }

    /// Whether an IMU endpoint can be expected to end the wearer's turns.
    ///
    /// Reading it is also how a returning motion stream is noticed: a window that is open
    /// with samples flowing answers true and clears any earlier loss, so the *next* window
    /// switches back to manual turns without anything having to watch for a reconnect.
    public var isLive: Bool {
        guard let signal else { return false }
        if signal.isSignalAvailable {
            motionConfirmedAbsent = false
            return true
        }
        return !motionConfirmedAbsent
    }

    /// The motion channel is confirmed gone — no sample has ever arrived this run, or a
    /// stream that was delivering them stopped. Called from the host's `onMotionLost`
    /// handler, which is the one place that knows the difference between "quiet" and "not
    /// there".
    public func noteMotionUnavailable() {
        guard !motionConfirmedAbsent else { return }
        motionConfirmedAbsent = true
    }

    private func noteSignalObserved() {
        guard signal?.isSignalAvailable == true else { return }
        motionConfirmedAbsent = false
    }
}
