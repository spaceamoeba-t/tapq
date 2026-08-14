import Foundation
import TapQContextBaseline
import TapQContracts
import TapQDetectionBaseline
import TapQVoiceBackends

/// Builds the stage-2 reasoner a host should run, or throws when this build or this
/// device cannot supply one.
///
/// The seam mirrors `TapQCLIApplication.motionScorerLoader`: a model framework is
/// reachable only from the executable, so the real implementation lives there behind its
/// platform guards and this target stays portable and testable. A nil loader means the
/// same thing as a throwing one — no reasoner — and hosts degrade rather than abort.
public typealias TapQReasonerLoading = @Sendable (
    ReasonerConfig,
    any TapQDiagnosticSink
) async throws -> any ContextReasoning

/// Why a requested stage-2 reasoner could not be built.
///
/// Both cases are environment conditions, not command-line mistakes, which is why hosts
/// answer them by degrading to no reasoner instead of refusing to serve.
///
/// `errorDescription` is a short lowercase phrase rather than a sentence: it is never
/// surfaced on its own, only interpolated into the runtime's reasoner status line.
public enum TapQReasonerUnavailableError: Error, LocalizedError, Equatable {
    /// This build has no reasoner backend at all — the model framework is not part of
    /// the platform's package graph.
    case unsupportedPlatform
    /// A backend exists but the device cannot answer: ineligible hardware, on-device
    /// intelligence switched off, or model assets still downloading.
    case modelUnavailable

    /// Closed, context-free kind for diagnostics. Never carries a request payload.
    public var reasonKind: String {
        switch self {
        case .unsupportedPlatform: return "unsupported_platform"
        case .modelUnavailable: return "model_unavailable"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: return "platform unsupported"
        case .modelUnavailable: return "model unavailable"
        }
    }
}

/// Platform-neutral configuration passed from CLI parsing to an injected runtime host.
/// The macOS executable supplies the AirPods/voice host; Linux can supply another host later.
public struct TapQRuntimeConfiguration: Sendable, Equatable {
    public let brokerDirectory: URL?
    public let gestureProfileURL: URL
    public let tapProfileURL: URL
    public let interactionTimeout: TimeInterval
    public let voiceEnabled: Bool
    /// Synthesis voice for spoken output: a BCP-47 language tag or a platform voice
    /// identifier. Hosts must apply it — an unset voice follows the system language and
    /// mispronounces everything TapQ says on a non-English machine.
    public let speechVoice: String
    public let announcementsEnabled: Bool
    public let steeringEnabled: Bool
    public let questionClassifier: QuestionClassifierProvider
    /// Provider that condenses an agent's final reply into speech. Hosts must treat `off`
    /// as "compose no summarizer at all": every prompt, detail, and notification then says
    /// exactly what it said before spoken summaries existed.
    public let speechSummarizer: SpeechSummarizerProvider
    /// Speech pipe the host composes the voice channel from. `apple` — the default — must
    /// leave the shipped composition untouched; any other provider is composed with the
    /// Apple stack as its fallback, so a cloud outage costs latency, never the channel.
    public let voiceBackend: VoiceBackendProvider
    /// TapQ-1 encoder model to load, if any. A load failure must degrade to the
    /// heuristic backend, never abort serving.
    public let encoderModelURL: URL?
    public let encoderMode: EncoderMode
    /// Stage-2 reasoner backend to build, if any. An unavailable backend must degrade to
    /// no reasoner — which can only mean "no escalation" — never abort serving.
    public let reasonerProvider: ReasonerProvider
    /// How much authority the built reasoner has. Hosts treat `off` as "do not build
    /// one" even when a provider is named.
    public let reasonerMode: ReasonerMode
    /// Thresholds the reasoner is built with. Defaulted rather than flag-driven: these
    /// are policy knobs, and no CLI flag exposes them yet.
    public let reasonerConfig: ReasonerConfig
    /// Whether the IMU-based wearer-speech attribution gate is active. Default off.
    /// When on, TapQ rejects voice commands that cannot be attributed to the wearer's
    /// own jaw vibration, unless the signal is unavailable (fail-open).
    public let wearerGateEnabled: Bool
    /// Whether IMU-based turn control is active. Default off.
    /// Endpointing: wearer speech-end commits the user turn.
    /// Barge-in: wearer speech-onset during response playback interrupts audio.
    /// Implies a wearer-speech signal source (shared with `wearerGateEnabled`).
    public let imuTurnControlEnabled: Bool
    /// Whether free-form voice answers are enabled for selection/multi-option stop
    /// questions. Default off. When on, an unmatched final transcript is offered as a
    /// free-text reply with mandatory read-back confirmation.
    public let voiceFreeformEnabled: Bool

    public init(
        brokerDirectory: URL? = nil,
        gestureProfileURL: URL,
        tapProfileURL: URL,
        interactionTimeout: TimeInterval = 240,
        voiceEnabled: Bool = true,
        speechVoice: String = SpeechVoiceSelection.defaultSelection,
        announcementsEnabled: Bool = true,
        steeringEnabled: Bool = false,
        questionClassifier: QuestionClassifierProvider = .auto,
        speechSummarizer: SpeechSummarizerProvider = .auto,
        voiceBackend: VoiceBackendProvider = .apple,
        encoderModelURL: URL? = nil,
        encoderMode: EncoderMode = .off,
        reasonerProvider: ReasonerProvider = .off,
        reasonerMode: ReasonerMode = .shadow,
        reasonerConfig: ReasonerConfig = ReasonerConfig(),
        wearerGateEnabled: Bool = false,
        imuTurnControlEnabled: Bool = false,
        voiceFreeformEnabled: Bool = false
    ) {
        self.brokerDirectory = brokerDirectory
        self.gestureProfileURL = gestureProfileURL
        self.tapProfileURL = tapProfileURL
        self.interactionTimeout = interactionTimeout
        self.voiceEnabled = voiceEnabled
        self.speechVoice = speechVoice
        self.announcementsEnabled = announcementsEnabled
        self.steeringEnabled = steeringEnabled
        self.questionClassifier = questionClassifier
        self.speechSummarizer = speechSummarizer
        self.voiceBackend = voiceBackend
        self.encoderModelURL = encoderModelURL
        self.encoderMode = encoderMode
        self.reasonerProvider = reasonerProvider
        self.reasonerMode = reasonerMode
        self.reasonerConfig = reasonerConfig
        self.wearerGateEnabled = wearerGateEnabled
        self.imuTurnControlEnabled = imuTurnControlEnabled
        self.voiceFreeformEnabled = voiceFreeformEnabled
    }
}

public struct TapQRuntimeEndpoint: Sendable, Equatable {
    public let socketPath: String
    public let discoveryPath: String
    public let gestureProfileLoaded: Bool
    public let tapProfileLoaded: Bool
    public let motionAvailable: Bool
    public let voiceAvailable: Bool
    /// Human-readable voice-backend state; nil for the default Apple path, whose behavior
    /// is what every operator already expects and so is worth no line at all.
    public let voiceBackendStatus: String?
    /// Human-readable TapQ-1 encoder state; nil when no encoder was requested.
    public let encoderStatus: String?
    /// Human-readable stage-2 reasoner state; nil when no reasoner was requested.
    public let reasonerStatus: String?
    /// Human-readable wearer-speech gate state; nil when the gate was not requested.
    public let wearerSpeechStatus: String?

    public init(
        socketPath: String,
        discoveryPath: String,
        gestureProfileLoaded: Bool,
        tapProfileLoaded: Bool,
        motionAvailable: Bool,
        voiceAvailable: Bool,
        voiceBackendStatus: String? = nil,
        encoderStatus: String? = nil,
        reasonerStatus: String? = nil,
        wearerSpeechStatus: String? = nil
    ) {
        self.socketPath = socketPath
        self.discoveryPath = discoveryPath
        self.gestureProfileLoaded = gestureProfileLoaded
        self.tapProfileLoaded = tapProfileLoaded
        self.motionAvailable = motionAvailable
        self.voiceAvailable = voiceAvailable
        self.voiceBackendStatus = voiceBackendStatus
        self.encoderStatus = encoderStatus
        self.reasonerStatus = reasonerStatus
        self.wearerSpeechStatus = wearerSpeechStatus
    }
}

@MainActor public protocol TapQRuntimeServing: AnyObject {
    /// Starts the broker and blocks until shutdown. `onReady` fires only after the socket
    /// is listening and discovery has been published.
    ///
    /// `reasonerLoader` is separate from `configuration` because it is a closure and the
    /// configuration is portable data. A nil loader is not an error: the host reports an
    /// unavailable reasoner and serves without one.
    func serve(
        configuration: TapQRuntimeConfiguration,
        reasonerLoader: TapQReasonerLoading?,
        onReady: @escaping @MainActor (TapQRuntimeEndpoint) -> Void
    ) async throws
}

public struct TapQRuntimeUnavailableError: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? {
        "The live TapQ runtime is unavailable on this platform. The open runtime currently requires macOS for AirPods motion, speech recognition, and speech synthesis."
    }
}
