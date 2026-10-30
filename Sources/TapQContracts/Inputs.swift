import Foundation

/// A detected head motion.
public enum HeadGesture: Sendable, Equatable {
    case nod
    case shake
}

/// A detected tap on the AirPod. Approve-only today; the enum leaves room for a future
/// double-tap without reshaping the channel.
public enum TapCommand: Sendable, Equatable {
    case tap
}

/// Emits a head gesture (nod/shake) while listening. Implemented by `HeadGestureDetector`.
@MainActor public protocol HeadGestureProviding: AnyObject {
    func start(onGesture: @escaping @MainActor (HeadGesture) -> Void)
    func stop()
}

/// Emits an AirPod tap while listening. Implemented by `HeadGestureDetector`, which derives
/// it from the same motion stream it uses for nod/shake.
@MainActor public protocol TapCommandProviding: AnyObject {
    func start(onTap: @escaping @MainActor (TapCommand) -> Void)
    func stop()
}

/// Read-only synthesizer activity: true while ANY utterance is being spoken or queued,
/// regardless of priority or which component enqueued it. The voice channel must stay
/// closed while this is true — the synthesizer must never hear itself. Implemented by
/// `SpeechEngine`; consumed by `SpeechGatedVoice`.
@MainActor public protocol SpeechActivitySignaling: AnyObject {
    var isSpeaking: Bool { get }
    /// Single observer, fired after each busy↔idle transition (never per-utterance).
    /// `SpeechGatedVoice` claims this at composition time — assigning it elsewhere
    /// would silently disable the self-hearing guard. Add a multicast on the engine
    /// if another consumer (e.g. a UI status pill) ever needs the signal.
    var onSpeakingChange: (@MainActor (Bool) -> Void)? { get set }
}

/// A doubled lateral head tilt (ear toward shoulder, roll axis). Replaces the retired
/// pitch-based tilt: a single pitch excursion is indistinguishable from glancing at the
/// keyboard and shares its axis with nod pairing, whereas a repeated roll excursion is
/// rare in natural desk motion and orthogonal to both nod (pitch) and shake (yaw).
public enum TiltCommand: Sendable, Equatable {
    case tiltLeft
    case tiltRight
}

/// A sustained finger drag on the earbud or ear detected from motion alone.
/// Experimental: disabled by default until capture-study validation confirms direction
/// separability at the ~25 Hz headphone motion rate.
public enum MotionSwipeCommand: Sendable, Equatable {
    case swipeUp
    case swipeDown
}

public enum VolumeSwipeCommand: Sendable, Equatable {
    case swipeUp
    case swipeDown
}

@MainActor public protocol TiltCommandProviding: AnyObject {
    func start(onTilt: @escaping @MainActor (TiltCommand) -> Void)
    func stop()
}

@MainActor public protocol VolumeSwipeProviding: AnyObject {
    func start(onSwipe: @escaping @MainActor (VolumeSwipeCommand) -> Void)
    func stop()
}
