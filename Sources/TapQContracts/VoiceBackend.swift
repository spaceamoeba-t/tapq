import Foundation

/// PCM description for audio crossing the `VoiceBackend` boundary.
///
/// Deliberately tiny: TapQ ships one encoding (16-bit signed little-endian PCM), and a
/// format type that can describe encodings no adapter implements would only invite
/// negotiation logic into a contract that has no business negotiating.
public struct VoiceAudioFormat: Sendable, Equatable {
    public let sampleRate: Double
    public let channels: Int
    /// True when the payload bytes are 16-bit signed little-endian samples. The only
    /// value any shipped adapter sets; the flag exists so a future encoding is a data
    /// change at the boundary rather than a silent reinterpretation of old bytes.
    public let pcm16: Bool

    public init(sampleRate: Double, channels: Int = 1, pcm16: Bool = true) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.pcm16 = pcm16
    }

    /// Mono 24 kHz PCM16 — the format the OpenAI Realtime slice speaks.
    public static let pcm16Mono24k = VoiceAudioFormat(sampleRate: 24_000, channels: 1)
    /// Mono 16 kHz PCM16 — the common on-device speech-recognition rate.
    public static let pcm16Mono16k = VoiceAudioFormat(sampleRate: 16_000, channels: 1)
}

/// One block of audio moving in either direction: microphone audio TapQ pushes into a
/// backend, or synthesized response audio a duplex backend pushes back.
public struct VoiceAudioChunk: Sendable, Equatable {
    public let data: Data
    public let format: VoiceAudioFormat
    /// Seconds on the sender's monotonic clock, for ordering and latency accounting only.
    /// Nothing in the contract interprets it as a shared wall clock.
    public let timestamp: TimeInterval

    public init(data: Data, format: VoiceAudioFormat, timestamp: TimeInterval) {
        self.data = data
        self.format = format
        self.timestamp = timestamp
    }

    /// Wall time this chunk represents, or nil when the bytes are not PCM16 (the only
    /// encoding whose length maps to a duration without decoding it).
    ///
    /// Callers use this to keep chunks small — a `sendAudio` that carries a second of
    /// audio blocks the main actor for as long as it takes to frame and write a second
    /// of audio.
    public var durationSeconds: TimeInterval? {
        guard pcm16 else { return nil }
        let bytesPerFrame = 2 * channels
        guard bytesPerFrame > 0, sampleRate > 0 else { return nil }
        return Double(data.count / bytesPerFrame) / sampleRate
    }

    private var pcm16: Bool { format.pcm16 }
    private var channels: Int { format.channels }
    private var sampleRate: Double { format.sampleRate }
}

/// What a backend can actually do, declared once at composition time.
///
/// Capabilities describe the *pipe*, never the policy. A backend that reports
/// `duplex: true` is saying it can carry audio both ways at once, not that TapQ will let
/// it: TapQ runs half-duplex regardless, because a window that is both listening and
/// speaking hears its own synthesizer.
public struct VoiceBackendCapabilities: Sendable, Equatable {
    /// The backend can abandon an in-flight response on `cancelResponse()`. When false,
    /// calling `cancelResponse()` is a contract violation rather than a no-op — silently
    /// swallowing it would let a caller believe barge-in works when it does not.
    public let supportsBargeIn: Bool
    /// The backend emits `.audio` events (it synthesizes speech itself). When false, the
    /// spoken side of the interaction stays with TapQ's own `SpeechPresenting`.
    public let producesAudio: Bool
    /// The transport can carry input and output audio simultaneously.
    public let duplex: Bool

    public init(supportsBargeIn: Bool = false, producesAudio: Bool = false,
                duplex: Bool = false) {
        self.supportsBargeIn = supportsBargeIn
        self.producesAudio = producesAudio
        self.duplex = duplex
    }

    /// The shape of a recognition-only backend: transcripts in, nothing spoken back, one
    /// direction at a time. The default because it is the least a backend can be and the
    /// most TapQ requires.
    public static let transcriptOnly = VoiceBackendCapabilities()
}

/// Why a session ended, or could not start.
///
/// Equatable and case-typed so a caller can branch (fail through to another backend on
/// `.network`, abort startup on `.authorization`) without string matching. The associated
/// text is for humans and diagnostics; it never carries credentials.
public enum VoiceBackendFailure: Error, LocalizedError, Equatable, Sendable {
    /// Transport-level: connect failed, socket dropped, request timed out.
    case network(String)
    /// The peer spoke something this adapter cannot make sense of, or violated the
    /// manual-turn contract (e.g. produced a response nobody asked for).
    case protocolViolation(String)
    /// Missing, rejected, or expired credentials — retrying will not help.
    case authorization(String)
    /// The session is closed: the peer hung up, or an operation arrived after teardown.
    case closed(String)

    public var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "Voice backend transport failed: \(detail)."
        case .protocolViolation(let detail):
            return "Voice backend protocol error: \(detail)."
        case .authorization(let detail):
            return "Voice backend rejected the credentials: \(detail)."
        case .closed(let detail):
            return "Voice backend session is closed: \(detail)."
        }
    }
}

/// Everything a backend is allowed to tell TapQ.
///
/// Note what is absent: there is no "user started speaking", "user stopped speaking", or
/// "turn ended" event. Those are decisions, and decisions live on TapQ's side of this
/// boundary. A backend that believes it detected end-of-speech has nothing in this enum
/// to say so with, which is the point.
public enum VoiceBackendEvent: Sendable, Equatable {
    /// Best-guess transcript so far. Cumulative for the current turn, matching the
    /// semantics `VoiceListener` already relies on: matchers see the whole utterance
    /// each time, not a delta.
    case transcriptPartial(String)
    /// Settled transcript for the current turn.
    case transcriptFinal(String)
    /// Response audio from a backend whose `capabilities.producesAudio` is true.
    case audio(VoiceAudioChunk)
    /// The backend finished whatever the current turn asked of it. For a transcript-only
    /// backend that is the end of recognition; for a speaking backend it is the end of
    /// its response audio.
    case responseCompleted
    /// The session is over and no further events will arrive. The caller must treat the
    /// backend as closed and, if it still needs voice, open a new one.
    case sessionFailed(VoiceBackendFailure)
}

/// A dumb speech pipe.
///
/// Two non-negotiables, both load-bearing enough to be restated on the individual
/// requirements below:
///
/// 1. **Turn arbitration lives on TapQ's side.** Only TapQ decides when a user turn
///    begins and ends, via `beginUserTurn()` / `endUserTurn()`. A backend's own
///    voice-activity detection must never end a turn, never commit a buffer, and never
///    start a response on its own initiative. Backends that ship a VAD must be
///    configured with it off (the OpenAI Realtime adapter sends `turn_detection: none`
///    before anything else). This is not a preference: TapQ's windows are arbitrated
///    against head gestures, taps, and timeouts, and a backend that ends turns behind
///    TapQ's back resolves approvals the interaction controller never authorized.
/// 2. **Wearer attribution lives on TapQ's side.** The microphone hears the whole room;
///    only the in-ear IMU knows whose jaw moved. No backend is ever asked, or trusted,
///    to say who spoke — see `WearerSpeechSignaling` and `WearerGatedVoice`.
///
/// Half-duplex is TapQ policy, not a transport limitation: even against a backend
/// reporting `duplex: true`, TapQ never requests a response while a user turn is open.
/// `VoiceTurnStateMachine` enforces that mechanically so each adapter does not have to
/// re-derive it.
///
/// `@MainActor` with closure events rather than `AsyncSequence`, matching
/// `VoiceCommandProviding` and the rest of the input surface.
@MainActor public protocol VoiceBackend: AnyObject {
    /// Static for the lifetime of the instance; safe to read before `open`.
    var capabilities: VoiceBackendCapabilities { get }

    /// Establishes the session and installs the single event observer.
    ///
    /// Throws `VoiceBackendFailure` when the session cannot be established. Calling
    /// `open` on an already-open backend is a programming error.
    func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws

    /// Tears the session down. Idempotent, non-throwing, and safe from any state — a
    /// teardown path that can fail is a teardown path that leaks microphones.
    func close()

    /// Opens a user turn: from here until `endUserTurn()`, `sendAudio` is accepted.
    ///
    /// Only TapQ calls this. See non-negotiable 1 on the protocol.
    func beginUserTurn()

    /// Commits the user turn. The backend may now finalize its transcript and, if asked,
    /// produce a response.
    ///
    /// Only TapQ calls this — a backend must never end a turn from its own VAD, silence
    /// timer, or heuristic. See non-negotiable 1 on the protocol.
    func endUserTurn()

    /// Feeds one block of microphone audio into the open user turn. Keep chunks short
    /// (~100 ms); see `VoiceAudioChunk.durationSeconds`.
    func sendAudio(_ chunk: VoiceAudioChunk)

    /// Asks the backend to produce a spoken/agent response for `text`. Meaningful for
    /// backends that produce audio; transcript-only backends route it to TapQ's shared
    /// `SpeechPresenting` rather than opening a second synthesizer.
    ///
    /// Never called while a user turn is open — that is the half-duplex policy.
    func requestResponse(text: String)

    /// Abandons an in-flight response (barge-in). Only meaningful when
    /// `capabilities.supportsBargeIn` is true.
    func cancelResponse()
}
