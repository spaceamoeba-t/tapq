import Foundation

/// Platform-neutral configuration passed from CLI parsing to an injected runtime host.
/// The macOS executable supplies the AirPods/voice host; Linux can supply another host later.
public struct TapQRuntimeConfiguration: Sendable, Equatable {
    public let brokerDirectory: URL?
    public let gestureProfileURL: URL
    public let tapProfileURL: URL
    public let interactionTimeout: TimeInterval
    public let voiceEnabled: Bool
    public let announcementsEnabled: Bool
    public let steeringEnabled: Bool

    public init(
        brokerDirectory: URL? = nil,
        gestureProfileURL: URL,
        tapProfileURL: URL,
        interactionTimeout: TimeInterval = 100,
        voiceEnabled: Bool = true,
        announcementsEnabled: Bool = true,
        steeringEnabled: Bool = false
    ) {
        self.brokerDirectory = brokerDirectory
        self.gestureProfileURL = gestureProfileURL
        self.tapProfileURL = tapProfileURL
        self.interactionTimeout = interactionTimeout
        self.voiceEnabled = voiceEnabled
        self.announcementsEnabled = announcementsEnabled
        self.steeringEnabled = steeringEnabled
    }
}

public struct TapQRuntimeEndpoint: Sendable, Equatable {
    public let socketPath: String
    public let discoveryPath: String
    public let gestureProfileLoaded: Bool
    public let tapProfileLoaded: Bool
    public let motionAvailable: Bool
    public let voiceAvailable: Bool

    public init(
        socketPath: String,
        discoveryPath: String,
        gestureProfileLoaded: Bool,
        tapProfileLoaded: Bool,
        motionAvailable: Bool,
        voiceAvailable: Bool
    ) {
        self.socketPath = socketPath
        self.discoveryPath = discoveryPath
        self.gestureProfileLoaded = gestureProfileLoaded
        self.tapProfileLoaded = tapProfileLoaded
        self.motionAvailable = motionAvailable
        self.voiceAvailable = voiceAvailable
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

