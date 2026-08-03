import Foundation

/// Read-only "is the person wearing the earbuds the one talking right now?" signal,
/// derived from the in-ear motion stream rather than from audio.
///
/// The microphone cannot answer this question: a nearby colleague, a meeting on the
/// laptop speakers, or a podcast all reach it exactly like the wearer does. Bone-conducted
/// vibration only reaches the earbud IMU when the wearer's own jaw is moving, which is why
/// attribution lives on the motion side. Implemented over `WearerSpeechDetector`; consumed
/// by `WearerGatedVoice`.
///
/// Every consumer must treat this as advisory. `isSignalAvailable` is the honest admission
/// that the signal is often absent — no motion stream, AirPods asleep, magnitude-only
/// samples, or a stream that has gone stale — and when it is false, callers must behave
/// exactly as they did before attribution existed (fail open).
@MainActor public protocol WearerSpeechSignaling: AnyObject {
    /// True while the detector currently believes the wearer is speaking. Meaningless
    /// unless `isSignalAvailable` is true.
    var isWearerSpeaking: Bool { get }

    /// False when the signal cannot be trusted at all: no motion stream is running, the
    /// samples carry no usable data, or the last sample is too old to describe *now*.
    /// A false value is a directive to fail open, not a "wearer is silent" answer.
    var isSignalAvailable: Bool { get }

    /// Single observer, fired after each quiet↔speaking transition (never per sample).
    /// `WearerGatedVoice` claims this at composition time — assigning it elsewhere would
    /// silently disable voice attribution. Add a multicast on the implementation if a
    /// second consumer (e.g. a UI indicator) ever needs the signal, exactly as
    /// `SpeechActivitySignaling.onSpeakingChange` documents.
    var onWearerSpeakingChange: (@MainActor (Bool) -> Void)? { get set }
}
