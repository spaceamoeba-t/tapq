import Foundation
import TapQContracts

/// The speech pipe requested for a runtime instance.
///
/// Two values, because there are exactly two things a wearer can mean: the on-device stack
/// TapQ has always shipped, or the cloud one *with* the on-device stack underneath it.
/// There is no "OpenAI only" — a voice channel that can go dead when the wifi does is not a
/// channel TapQ is willing to compose, so the realtime path is always the primary of a
/// `FailThroughVoiceBackend` whose fallback is the Apple backend.
public enum VoiceBackendProvider: String, CaseIterable, Equatable, Sendable {
    /// Apple's on-device recognizer. The default, and byte for byte today's composition.
    case apple
    /// OpenAI Realtime in manual-turn mode, backed by the Apple stack.
    case openaiRealtime = "openai-realtime"

    /// How the runtime reports the choice on its ready line, or nil when there is nothing
    /// worth reporting.
    ///
    /// The default is deliberately silent: a status line that always prints "apple" would
    /// add a line to every operator's console to tell them nothing changed.
    public var statusDescription: String? {
        switch self {
        case .apple:
            return nil
        case .openaiRealtime:
            return "openai-realtime (fail-through: apple)"
        }
    }
}

/// A startup configuration error for an explicitly requested voice backend.
///
/// Both cases are command-line mistakes rather than environment conditions, so — unlike the
/// stage-2 reasoner, which degrades — they abort serving, exactly as a misconfigured
/// question classifier does. Silently serving on the Apple stack after the operator asked
/// for a cloud one would hide the misconfiguration behind working voice.
public enum VoiceBackendConfigurationError: Error, LocalizedError, Equatable {
    case missingOpenAIAPIKey
    case realtimeUnsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .missingOpenAIAPIKey:
            return "OpenAI Realtime voice requires OPENAI_API_KEY "
                + "in the TapQ process environment."
        case .realtimeUnsupportedPlatform:
            return "OpenAI Realtime voice was requested, but this build has no realtime "
                + "transport. Select apple instead."
        }
    }
}

/// A composed backend together with the provider it was built for.
///
/// Mirrors `QuestionClassifierSelection`: the caller gets the thing it asked for plus enough
/// to describe what it got, and never has to ask the composition what it is.
public struct VoiceBackendSelection {
    public let backend: any VoiceBackend
    public let provider: VoiceBackendProvider

    public init(backend: any VoiceBackend, provider: VoiceBackendProvider) {
        self.backend = backend
        self.provider = provider
    }

    /// Ready-line text for this selection; nil for the default path.
    public var statusDescription: String? { provider.statusDescription }
}

/// Resolves runtime provider policy into a composed `VoiceBackend`.
///
/// The Apple backend arrives as a closure rather than a value for two reasons: this target
/// is portable and must never import AVFoundation or Speech, and the fallback should only be
/// constructed by the path that actually composes one. Nothing here opens a microphone, a
/// socket, or a recognizer — construction is inert until somebody calls `open`.
public enum VoiceBackendFactory {
    /// Optional decorator applied to the realtime primary before it is wrapped in
    /// `FailThroughVoiceBackend`. The executable passes a microphone-pump constructor here
    /// so the portable factory never imports AVFoundation, mirroring the existing
    /// `makeAppleBackend` closure pattern.
    public typealias RealtimePrimaryDecorator = @MainActor (any VoiceBackend) -> any VoiceBackend

    /// Resolves an explicit runtime policy into a backend. Configuration mistakes throw at
    /// startup; runtime failures are the composition's business — the realtime path fails
    /// through to Apple rather than surfacing anything to the caller.
    ///
    /// - Parameter decorateRealtimePrimary: when non-nil, wraps the realtime primary (e.g.
    ///   with a microphone pump) before it enters the fail-through composition. The Apple
    ///   provider path never invokes it.
    /// - Parameter failThroughStickiness: stickiness policy for the `FailThroughVoiceBackend`.
    ///   `.retryEachOpen` (default) retries the primary on every `open`; `.stickyAfterFailure`
    ///   keeps the fallback until `resetStickiness()` is called (conversation mode).
    @MainActor
    public static func select(
        provider: VoiceBackendProvider,
        openAIAPIKey: String? = nil,
        decorateRealtimePrimary: RealtimePrimaryDecorator? = nil,
        failThroughStickiness: FailThroughStickiness = .retryEachOpen,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
        makeAppleBackend: @MainActor () -> any VoiceBackend
    ) throws -> VoiceBackendSelection {
        try select(
            provider: provider,
            openAIAPIKey: openAIAPIKey,
            decorateRealtimePrimary: decorateRealtimePrimary,
            failThroughStickiness: failThroughStickiness,
            diagnosticSink: diagnosticSink,
            makeAppleBackend: makeAppleBackend,
            makeRealtimeBackend: liveRealtimeBackend
        )
    }

    /// Test seam: the realtime primary is injectable so composition can be proven without
    /// building a live WebSocket transport.
    @MainActor
    static func select(
        provider: VoiceBackendProvider,
        openAIAPIKey: String?,
        decorateRealtimePrimary: RealtimePrimaryDecorator? = nil,
        failThroughStickiness: FailThroughStickiness = .retryEachOpen,
        diagnosticSink: any TapQDiagnosticSink,
        makeAppleBackend: @MainActor () -> any VoiceBackend,
        makeRealtimeBackend: @MainActor (String, any TapQDiagnosticSink) throws -> any VoiceBackend
    ) throws -> VoiceBackendSelection {
        switch provider {
        case .apple:
            // No wrapper at all: the default path is the closure's product, unmediated.
            return VoiceBackendSelection(backend: makeAppleBackend(), provider: .apple)

        case .openaiRealtime:
            guard let apiKey = openAIAPIKey?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !apiKey.isEmpty else {
                throw VoiceBackendConfigurationError.missingOpenAIAPIKey
            }
            let rawPrimary = try makeRealtimeBackend(apiKey, diagnosticSink)
            let primary = decorateRealtimePrimary?(rawPrimary) ?? rawPrimary
            return VoiceBackendSelection(
                backend: FailThroughVoiceBackend(
                    primary: primary,
                    fallback: makeAppleBackend(),
                    stickiness: failThroughStickiness,
                    diagnosticSink: diagnosticSink
                ),
                provider: .openaiRealtime
            )
        }
    }

    @MainActor
    private static func liveRealtimeBackend(
        apiKey: String,
        diagnosticSink: any TapQDiagnosticSink
    ) throws -> any VoiceBackend {
        #if canImport(Darwin)
        return OpenAIRealtimeVoiceBackend(apiKey: apiKey, diagnosticSink: diagnosticSink)
        #else
        // The live transport is compiled out where `URLSessionWebSocketTask` cannot be
        // trusted, so there is nothing to hand back and refusing is the honest answer.
        throw VoiceBackendConfigurationError.realtimeUnsupportedPlatform
        #endif
    }
}
