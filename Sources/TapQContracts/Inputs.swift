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

/// The resolved intent fed to the interaction state machine.
public enum InputIntent: Sendable {
    case allow
    case deny
    case repeatRequest
    case details
    case deferToPrompt
    case next
    case previous
    case select
    case selectByNumber(Int)
}

extension InputIntent: Equatable {
    public static func == (lhs: InputIntent, rhs: InputIntent) -> Bool {
        switch (lhs, rhs) {
        case (.allow, .allow), (.deny, .deny), (.repeatRequest, .repeatRequest),
             (.details, .details), (.deferToPrompt, .deferToPrompt), (.next, .next),
             (.previous, .previous), (.select, .select):
            return true
        case (.selectByNumber(let a), .selectByNumber(let b)):
            return a == b
        default:
            return false
        }
    }
}

public extension VoiceCommand {
    var intent: InputIntent {
        switch self {
        case .yes: return .allow
        case .no: return .deny
        case .repeatRequest: return .repeatRequest
        case .details: return .details
        case .skip: return .deferToPrompt
        case .next: return .next
        case .previous: return .previous
        case .select: return .select
        case .number(let n): return .selectByNumber(n)
        }
    }
}

public extension TapCommand {
    var intent: InputIntent {
        switch self {
        case .tap: return .allow
        }
    }
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
}

/// Emits an AirPod tap while listening. Implemented by `HeadGestureDetector`, which derives
/// it from the same motion stream it uses for nod/shake.
@MainActor public protocol TapCommandProviding: AnyObject {
    func start(onTap: @escaping @MainActor (TapCommand) -> Void)
    func stop()
}

/// Opens an input window across all channels and resolves the first confident intent.
/// Motion/tap channels are live for the whole window (barge-in). The voice channel is
/// expected to be `SpeechGatedVoice`-wrapped at composition time, so the microphone
/// stays closed whenever the speech engine is busy — the synthesizer must never hear
/// itself.
@MainActor public protocol InputArbitrating: AnyObject {
    func listen(timeout: TimeInterval) async -> InputIntent?
}

/// Speaks utterances with priority/preemption. Implemented by `SpeechEngine`.
@MainActor public protocol SpeechPresenting: AnyObject {
    func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?)
    func stopAll()
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

public enum TiltCommand: Sendable, Equatable {
    case tiltUp
    case tiltDown
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
