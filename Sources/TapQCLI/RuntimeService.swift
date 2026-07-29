import Foundation
import TapQContextBaseline
import TapQDetectionBaseline

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
    /// TapQ-1 encoder model to load, if any. A load failure must degrade to the
    /// heuristic backend, never abort serving.
    public let encoderModelURL: URL?
    public let encoderMode: EncoderMode

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
        encoderModelURL: URL? = nil,
        encoderMode: EncoderMode = .off
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
        self.encoderModelURL = encoderModelURL
        self.encoderMode = encoderMode
    }
}

public struct TapQRuntimeEndpoint: Sendable, Equatable {
    public let socketPath: String
    public let discoveryPath: String
    public let gestureProfileLoaded: Bool
    public let tapProfileLoaded: Bool
    public let motionAvailable: Bool
    public let voiceAvailable: Bool
    /// Human-readable TapQ-1 encoder state; nil when no encoder was requested.
    public let encoderStatus: String?

    public init(
        socketPath: String,
        discoveryPath: String,
        gestureProfileLoaded: Bool,
        tapProfileLoaded: Bool,
        motionAvailable: Bool,
        voiceAvailable: Bool,
        encoderStatus: String? = nil
    ) {
        self.socketPath = socketPath
        self.discoveryPath = discoveryPath
        self.gestureProfileLoaded = gestureProfileLoaded
        self.tapProfileLoaded = tapProfileLoaded
        self.motionAvailable = motionAvailable
        self.voiceAvailable = voiceAvailable
        self.encoderStatus = encoderStatus
    }
}

@MainActor public protocol TapQRuntimeServing: AnyObject {
    /// Starts the broker and blocks until shutdown. `onReady` fires only after the socket
    /// is listening and discovery has been published.
    func serve(
        configuration: TapQRuntimeConfiguration,
        onReady: @escaping @MainActor (TapQRuntimeEndpoint) -> Void
    ) async throws
}

public struct TapQRuntimeUnavailableError: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? {
        "The live TapQ runtime is unavailable on this platform. The open runtime currently requires macOS for AirPods motion, speech recognition, and speech synthesis."
    }
}
