import Foundation

/// A detected head motion.
public enum HeadGesture: Sendable, Equatable {
    case nod
    case shake
}

/// A recognized short voice command.
public enum VoiceCommand: Sendable {
    case yes
    case no
    case repeatRequest
    case details
    case skip
    case next
    case previous
    case select
    case number(Int)
    /// A spoken free-text answer that matched no keyword. Only produced when
    /// `freeformEnabled` is true on the `VoiceBackendCommandProvider`.
    case freeform(String)
}

extension VoiceCommand: Equatable {
    public static func == (lhs: VoiceCommand, rhs: VoiceCommand) -> Bool {
        switch (lhs, rhs) {
        case (.yes, .yes), (.no, .no), (.repeatRequest, .repeatRequest),
             (.details, .details), (.skip, .skip), (.next, .next),
             (.previous, .previous), (.select, .select):
            return true
        case (.number(let a), .number(let b)):
            return a == b
        case (.freeform(let a), .freeform(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// A detected tap on the AirPod. Approve-only today; the enum leaves room for a future
/// double-tap without reshaping the channel.
public enum TapCommand: Sendable, Equatable {
    case tap
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

/// Emits a head gesture (nod/shake) while listening. Implemented by `HeadGestureDetector`.
@MainActor public protocol HeadGestureProviding: AnyObject {
    func start(onGesture: @escaping @MainActor (HeadGesture) -> Void)
    func stop()
}

/// Emits a recognized voice command while listening. Implemented by `VoiceListener`.
@MainActor public protocol VoiceCommandProviding: AnyObject {
    func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void)
    func stop()

    /// Suspends command delivery without tearing down backend state.
    ///
    /// Called by `SpeechGatedVoice` when the activity signal rises (TTS or backend audio
    /// starts playing). Unlike `stop()`, which is an arbiter-driven window end, this is an
    /// activity-driven mic close: the window is still conceptually open, and a conversation-
    /// mode backend must not flush response audio or cancel in-flight responses.
    ///
    /// The default implementation calls `stop()`, which is correct for providers that carry
    /// no persistent session state across start/stop cycles (e.g. `VoiceListener`).
    func pauseListening()
}

public extension VoiceCommandProviding {
    func pauseListening() { stop() }
}

/// Emits an AirPod tap while listening. Implemented by `HeadGestureDetector`, which derives
/// it from the same motion stream it uses for nod/shake.
@MainActor public protocol TapCommandProviding: AnyObject {
    func start(onTap: @escaping @MainActor (TapCommand) -> Void)
    func stop()
}

@MainActor public protocol TiltCommandProviding: AnyObject {
    func start(onTilt: @escaping @MainActor (TiltCommand) -> Void)
    func stop()
}

@MainActor public protocol VolumeSwipeProviding: AnyObject {
    func start(onSwipe: @escaping @MainActor (VolumeSwipeCommand) -> Void)
    func stop()
}
