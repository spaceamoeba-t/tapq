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
    /// The backend can run end-of-speech detection of its own over the audio TapQ feeds
    /// it, and commit that audio for transcription when it decides the speaker stopped.
    ///
    /// Declaring it does **not** turn it on. It is off on every fresh session and stays off
    /// until TapQ calls `setNativeTurnDetection(true)`, which TapQ does only in the one
    /// situation the carve-out on this protocol describes: no wearer turn signal exists, so
    /// nothing on TapQ's side can tell when the utterance ended. When false,
    /// `setNativeTurnDetection(true)` is a request the backend cannot honour and TapQ must
    /// never make — the caller checks this flag first.
    public let supportsNativeTurnDetection: Bool

    public init(supportsBargeIn: Bool = false, producesAudio: Bool = false,
                duplex: Bool = false, supportsNativeTurnDetection: Bool = false) {
        self.supportsBargeIn = supportsBargeIn
        self.producesAudio = producesAudio
        self.duplex = duplex
        self.supportsNativeTurnDetection = supportsNativeTurnDetection
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
/// Note what is still absent: there is no "user started speaking", no "user stopped
/// speaking", and above all no "window resolved". Those are decisions, and decisions live
/// on TapQ's side of this boundary. The single report a backend may make about the shape of
/// a turn is `userAudioCommittedByBackend`, and it exists only because TapQ explicitly
/// asked the backend to do the endpointing — see the carve-out on `VoiceBackend`.
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
    /// The backend's own end-of-speech detection decided the speaker stopped and committed
    /// the audio buffered so far for transcription. Emitted **only** while TapQ has turned
    /// native turn detection on with `setNativeTurnDetection(true)`; a backend that sends
    /// it otherwise has broken the contract and the adapter fails the session.
    ///
    /// What it does *not* mean: the user turn is over. TapQ's turn is still open, `sendAudio`
    /// is still accepted, and the microphone stays live — the wearer may keep talking, and a
    /// second segment will be committed the same way. All this event reports is that a
    /// transcript for the audio so far is on its way, which is what lets the window resolve
    /// through the ordinary match-on-transcript path instead of waiting out its timeout.
    /// It never carries a response with it: `create_response` stays off.
    case userAudioCommittedByBackend
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
///
///    **The carve-out, and exactly how far it goes.** The rule above assumes TapQ *has* a
///    turn signal. It has one only from the in-ear IMU: `WearerTurnCoordinator` watches
///    bone-conducted speech and commits the turn when the wearer stops. With no AirPods
///    streaming — or without `--imu-turn-control` — nothing on TapQ's side knows the
///    utterance ended, and against a backend that only produces transcripts on commit the
///    wearer's answer sits unheard in a buffer until the window times out. A voice channel
///    that is silently unusable is worse than one that admits a remote endpoint decided
///    where the sentence stopped. So when, and only when, TapQ has no wearer turn signal,
///    it may call `setNativeTurnDetection(true)` on a backend that declares
///    `supportsNativeTurnDetection`, and that backend's own VAD may then end the *user
///    turn* — meaning: commit buffered audio for transcription, and report it as
///    `userAudioCommittedByBackend`.
///
///    Everything else about non-negotiable 1 survives intact, and each clause is load-bearing:
///    the backend still must never create a response of its own (`create_response: false`);
///    it still must never resolve anything — match-on-transcript, gestures, taps, and the
///    window timeout remain the only ways a window ends, and every one of them runs on
///    TapQ's side of this boundary; and it is still TapQ that decides the mode, per window,
///    from the liveness of its own signal, so an IMU-armed run behaves exactly as it did
///    before this carve-out existed. What the wearer trades for a usable voice channel is
///    narrow and worth naming: the remote endpoint learns where their sentences end. It
///    learns that only from audio it was already being sent, only while a window is open.
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

    /// Commits the user turn. The backend may now finalize its transcript and, if
    /// `expectingResponse` is true, produce a spoken response.
    ///
    /// - Parameter expectingResponse: When `true`, the backend should create a response
    ///   (e.g. OpenAI's `response.create` after `input_audio_buffer.commit`). When `false`,
    ///   the backend commits the audio for transcription only — no response is created.
    ///   Match-resolved windows, gesture/timeout stops, and activity-driven pauses all pass
    ///   `false`; only an explicit coordinator endpoint (wearer finished speaking, TapQ wants
    ///   the model to reply) passes `true`.
    /// - Returns: `true` when the backend actually created a response from this turn end.
    ///   `false` when `expectingResponse` was `false`, when the turn carried no audio (the
    ///   empty-turn guard), or for transcript-only backends that never create responses.
    ///   The caller derives its response-pending tracking exclusively from this report —
    ///   no proxy flags.
    ///
    /// Only TapQ calls this — a backend must never end a turn from its own VAD, silence
    /// timer, or heuristic. See non-negotiable 1 on the protocol.
    @discardableResult
    func endUserTurn(expectingResponse: Bool) -> Bool

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

    /// Switches the backend's own end-of-speech detection on or off for this session.
    ///
    /// This is the carve-out on non-negotiable 1, expressed as one call. `true` asks the
    /// backend to commit buffered audio for transcription when its VAD hears the speaker
    /// stop, and to report each such commit as `userAudioCommittedByBackend`; it never
    /// authorizes creating a response, ending TapQ's window, or resolving anything.
    /// `false` — the state every fresh session starts in — puts commits back under
    /// `endUserTurn(expectingResponse:)` alone, and a commit the backend makes anyway is a
    /// protocol violation that kills the session.
    ///
    /// Every backend implements this rather than inheriting a default no-op: a protocol
    /// extension would let a backend that cannot do it look, from the call site, exactly
    /// like one that can, which is the failure mode the whole capability exists to prevent.
    /// A backend whose `capabilities.supportsNativeTurnDetection` is false implements it as
    /// a documented no-op, and TapQ checks the flag before ever asking.
    ///
    /// Callable before `open` (the mode is applied to the session when it is established)
    /// and on a live session (the mode changes from the next segment on). Idempotent.
    func setNativeTurnDetection(_ enabled: Bool)
}
