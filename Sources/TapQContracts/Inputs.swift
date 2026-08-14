import Foundation
import TapQGestureContracts

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
    /// A spoken free-text answer that matched no keyword. Only meaningful in
    /// selection flow; approval flow ignores it (keeps listening).
    case freeform(String)
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
        case (.freeform(let a), .freeform(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Which input channel produced an intent.
///
/// Provenance exists for one reason: `RequiredConfirmation.gestureAndVoice` is defined as
/// two *independent* channels agreeing, and an intent with no channel attached cannot
/// prove that. Nothing else branches on it — allow is allow and deny is deny, whichever
/// channel carried it.
public enum InputChannel: String, Sendable, Equatable {
    case gesture
    case voice
    case tap
    /// This arbiter does not report provenance. Treated as "not voice" everywhere it
    /// matters, so an arbiter that stays silent about channels can never satisfy a
    /// requirement that names one.
    case unspecified
}

/// An intent together with the channel that produced it.
public struct ResolvedInput: Sendable, Equatable {
    public let intent: InputIntent
    public let channel: InputChannel

    public init(intent: InputIntent, channel: InputChannel = .unspecified) {
        self.intent = intent
        self.channel = channel
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
        case .freeform(let text): return .freeform(text)
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

/// Opens an input window across all channels and resolves the first confident intent.
/// Motion/tap channels are live for the whole window (barge-in). The voice channel is
/// expected to be `SpeechGatedVoice`-wrapped at composition time, so the microphone
/// stays closed whenever the speech engine is busy — the synthesizer must never hear
/// itself.
@MainActor public protocol InputArbitrating: AnyObject {
    func listen(timeout: TimeInterval) async -> InputIntent?
    /// The same window, reporting which channel resolved it.
    ///
    /// A requirement, not a free function, so an arbiter that knows its channels
    /// (`InputArbiter`) is dispatched to rather than the default below. The default
    /// exists so every host and test double written against `listen(timeout:)` keeps
    /// working unchanged.
    func listenForInput(timeout: TimeInterval) async -> ResolvedInput?
}

public extension InputArbitrating {
    /// Provenance-free fallback for arbiters that only implement `listen(timeout:)`.
    ///
    /// Reporting `unspecified` rather than guessing is what keeps the fallback safe: a
    /// requirement that asks for a spoken confirmation is never satisfied by an input
    /// that cannot say where it came from, so the request runs out its window and
    /// resolves to `.ask` — the same thing an unanswered request does today.
    func listenForInput(timeout: TimeInterval) async -> ResolvedInput? {
        guard let intent = await listen(timeout: timeout) else { return nil }
        return ResolvedInput(intent: intent, channel: .unspecified)
    }
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
