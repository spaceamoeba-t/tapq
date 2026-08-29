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
    /// The backend can be given a set of tools and will call them by name, with structured
    /// arguments, when it understands the speaker to have asked for one.
    ///
    /// This is the one capability that changes where *intent* comes from. A backend that
    /// declares it resolves what the wearer meant itself and reports it as
    /// `VoiceBackendEvent.toolCall`; TapQ then executes the named action. A backend that does
    /// not declare it produces transcripts only, and the recognizer→intent step stays where
    /// it has always been — a deterministic keyword grammar on TapQ's side.
    ///
    /// It does not weaken non-negotiable 1 or 2. A tool call is a *report of meaning*, not a
    /// decision: it is refused outright when no window is open, it resolves nothing a
    /// gesture, a tap, or a timeout could not already resolve, and the one action it can
    /// never carry is ending TapQ's voice session — see `REALTIME_INTENT_PLAN.md`.
    public let supportsToolCalling: Bool

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
                duplex: Bool = false, supportsNativeTurnDetection: Bool = false,
                supportsToolCalling: Bool = false) {
        self.supportsBargeIn = supportsBargeIn
        self.producesAudio = producesAudio
        self.duplex = duplex
        self.supportsNativeTurnDetection = supportsNativeTurnDetection
        self.supportsToolCalling = supportsToolCalling
    }

    /// The shape of a recognition-only backend: transcripts in, nothing spoken back, one
    /// direction at a time. The default because it is the least a backend can be and the
    /// most TapQ requires.
    public static let transcriptOnly = VoiceBackendCapabilities()
}

/// One argument of a tool TapQ declares to a model-backed backend.
///
/// Two kinds and nothing else. A tool argument is either a piece of the wearer's own speech
/// (a dictated sentence, an agent's name, a status question's subject) or an ordinal from a
/// list TapQ just read out loud. Anything richer would be a place for a model to invent
/// structure TapQ never asked about, and every field here has to survive being wrong.
public struct VoiceToolParameter: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case string
        case integer
    }

    public let name: String
    public let kind: Kind
    /// What the argument means, in the words the model reads. Written for a model that has
    /// only the session's grounding to go on, so it names the *source* of the value ("the
    /// agent's name exactly as the wearer said it") rather than restating the tool.
    public let description: String
    /// Whether the tool may be called without it. An optional argument is one the wearer is
    /// allowed not to have said.
    public let required: Bool
    /// The closed set this argument's value must come from, or `nil` when it is free text.
    /// Rendered as a JSON Schema `enum`, so a value outside it is refused by the service
    /// before it ever reaches TapQ.
    public let allowedValues: [String]?

    public init(name: String, kind: Kind, description: String,
                required: Bool = true, allowedValues: [String]? = nil) {
        self.name = name
        self.kind = kind
        self.description = description
        self.required = required
        self.allowedValues = allowedValues
    }
}

/// One action TapQ is willing to have a model-backed backend call on the wearer's behalf.
///
/// Deliberately a value type with no behavior: what a tool *does* is TapQ's business and
/// lives on TapQ's side of this boundary. This is only the declaration a backend renders
/// onto its own wire.
public struct VoiceToolDeclaration: Sendable, Equatable {
    public let name: String
    /// When to call it. The single most load-bearing string in the tool path: it is what
    /// stands between "the wearer said the word no" and "the wearer refused this request",
    /// and it is where the instruction to do nothing on ambiguity lives.
    public let description: String
    public let parameters: [VoiceToolParameter]

    public init(name: String, description: String, parameters: [VoiceToolParameter] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A backend reporting that the speaker asked for one of TapQ's declared tools.
///
/// The arguments arrive as the raw JSON text the model produced rather than as a decoded
/// dictionary, for the same reason audio arrives as bytes: the adapter's job is to carry
/// what the peer said, and deciding whether it is well-formed enough to act on is a policy
/// question that belongs where the action does. Unparseable arguments are a pipeline
/// failure, never a best-effort guess.
public struct VoiceToolCall: Sendable, Equatable {
    /// The peer's handle for this call. Every call is owed exactly one result carrying this
    /// id back, or the model is left waiting on a tool that never answered.
    public let callID: String
    public let name: String
    /// The model's arguments, as a JSON object text. Empty for a tool that takes none.
    public let argumentsJSON: String

    public init(callID: String, name: String, argumentsJSON: String) {
        self.callID = callID
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
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
    /// The backend called one of the tools TapQ declared to it.
    ///
    /// Read the qualifications on `VoiceBackendCapabilities.supportsToolCalling`: this is a
    /// report of what the backend understood, and it is TapQ that decides whether anything
    /// happens as a result. A tool call arriving with no window open is refused, not acted
    /// on, and no tool exists that could end a voice session — the only two properties that
    /// keep "the model resolves intent" from meaning "the model resolves windows".
    ///
    /// Every call is owed exactly one `sendToolResult`, including a refused one.
    case toolCall(VoiceToolCall)
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

    /// The peer's own name for the response being produced right now, or `nil` when there
    /// is none in flight and for a peer that names none.
    ///
    /// Read-only and advisory: nothing about the turn protocol depends on it. It exists so a
    /// caller that has decided to *abandon* a particular response can say which one it meant.
    /// A mark that means "cancel whatever arrives next" is a mark that will eventually fire
    /// on the wrong response — on hardware (2026-08-28) it fired on TapQ's own spoken
    /// refusal, and the wearer heard nothing at all. See
    /// `VoiceBackendCommandProvider.endWindowKeepSession`.
    ///
    /// `nil` — the default, every transcript-only pipe, and every moment between responses —
    /// is a legal answer, never an error: the caller falls back to its own bookkeeping. **A
    /// wrapper must still forward it**, for the reason `requestScriptedSpeech` gives: taking
    /// the default would report "this peer names nothing" for a peer that names everything,
    /// and quietly cost the composition above its one cross-check.
    var activeResponseIdentity: String? { get }

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

    /// Speaks one sentence TapQ wrote, word for word.
    ///
    /// The separation from `requestResponse(text:)` is the whole point. That call hands a
    /// model a job — "answer this from the context I gave you" — and a model doing a job is
    /// entitled to choose its own words. This one hands over a *finished* sentence: a
    /// prompt, a read-back, "Listening.", "Queued for Codex.", a notice. TapQ already
    /// decided what those say, and an adapter that lets them be paraphrased has changed
    /// what the wearer was told — at approval priority, what they were told they are
    /// authorizing.
    ///
    /// So an adapter with a verbatim channel must use it here (the realtime adapter asks
    /// for an out-of-band response whose only instruction is to repeat the sentence, which
    /// also keeps scripted lines out of the conversation state grounded answers read).
    /// The default below is right for every backend that has no such channel — the Apple
    /// adapter simply speaks the text — and it is the reason this is not a bare
    /// requirement. **A wrapper must still forward it explicitly**: inheriting the default
    /// would quietly route the inner adapter's verbatim channel back through
    /// `requestResponse`, which is exactly the paraphrase this exists to prevent.
    ///
    /// Legality is `requestResponse`'s, unchanged: never while a user turn is open, never
    /// while another response is in flight.
    func requestScriptedSpeech(text: String)

    /// Abandons an in-flight response (barge-in). Only meaningful when
    /// `capabilities.supportsBargeIn` is true.
    ///
    /// Idempotent on a backend that supports it: a cancel with no response in flight is a
    /// recorded no-op, never a session-ending violation. A caller learns that a response
    /// ended from the audio it stops receiving, which is late and lossy news, and more than
    /// one path — a match resolving a window, a coordinator's barge-in, the next listening
    /// window opening — can reach for the same ending. Making the second one fatal turned a
    /// duplicate into a dead microphone for the rest of the run.
    ///
    /// What stays fatal is asking a backend that cannot do this at all: with
    /// `capabilities.supportsBargeIn` false the call is a violation however the session is
    /// arranged, so no composition can believe a response was abandoned when it was not.
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

    /// Declares the actions this session's model may call, replacing any previous set.
    ///
    /// Meaningful only where `capabilities.supportsToolCalling` is true; the default below
    /// records nothing and does nothing, which is the honest behavior for a pipe with no
    /// model in it. Callable before `open` — the declaration is applied when the session is
    /// established — and on a live session.
    func declareTools(_ tools: [VoiceToolDeclaration])

    /// Replaces the standing instructions the session runs under.
    ///
    /// This is how per-window grounding reaches a model-backed backend: what is being
    /// approved, what the read-back list holds, which agents are live, whether anything is
    /// listening at all. It carries only sentences TapQ has already spoken out loud plus
    /// facts TapQ chose to state — never a request's raw fields.
    ///
    /// A no-op by default, and by design: a transcript-only backend has nothing to instruct,
    /// and pretending otherwise would let a composition believe a grammar-driven pipe had
    /// been grounded.
    func updateInstructions(_ instructions: String)

    /// Asks the model to take a turn over audio the backend has already committed itself.
    ///
    /// One caller and one situation: TapQ has handed end-of-speech detection to the backend
    /// (the carve-out on this protocol), so `endUserTurn` is not what ends an utterance any
    /// more — the backend's own VAD is, and it commits with `create_response: false`. On a
    /// session where intent comes from tool calls that would be a wearer talking into a pipe
    /// that never answers: a tool call is an item inside a response, and nothing had asked for
    /// one. This is the ask.
    ///
    /// It creates no audio of its own and carries no text. What comes back is whatever the
    /// session's standing instructions allow — a tool call, silence, or one clarifying
    /// question — never a paraphrase of anything TapQ wrote, because TapQ's sentences go out
    /// on `requestScriptedSpeech` and never through here.
    ///
    /// Legality is `requestResponse`'s: the caller must have ended its own turn first, and no
    /// other response may be in flight. Half-duplex is unchanged, and so is "only TapQ starts
    /// a response" — this *is* TapQ starting one.
    ///
    /// - Returns: `true` when a response was created. `false` — the default, and every
    ///   backend with no model in it — means nothing is coming and the caller should not wait
    ///   for it.
    @discardableResult
    func requestModelTurn() -> Bool

    /// Answers one `VoiceBackendEvent.toolCall`.
    ///
    /// - Parameters:
    ///   - callID: the id the call arrived with. A result under any other id is a result for
    ///     a call the model is not waiting on.
    ///   - output: what the tool produced, as text the model may read. Refusals are results
    ///     too — a tool that could not run has still answered.
    ///
    /// It closes the call and nothing more: no speech follows from it. Anything the wearer
    /// is owed about a tool goes out through `requestScriptedSpeech`, in the words TapQ
    /// wrote, on the one channel every other TapQ sentence already uses. Letting the model
    /// narrate its own tool results instead would put a paraphrase of "instruction
    /// discarded" in the wearer's ear, and would announce twice everything TapQ already
    /// says once.
    ///
    /// Every call must be answered exactly once. A backend that never hears back leaves a
    /// model parked on a tool, which is a hung voice channel rather than a quiet one.
    func sendToolResult(callID: String, output: String)
}

public extension VoiceBackend {
    /// The honest default for a pipe whose peer names nothing: there is no id to give.
    ///
    /// Safe to take for any backend that cannot name a response. A caller that reads this
    /// must already work without it — see the requirement above.
    var activeResponseIdentity: String? { nil }

    /// The honest default for a backend with no verbatim channel of its own: ask for the
    /// sentence as an ordinary response. See the requirement above for why a *wrapper* must
    /// never take this default.
    func requestScriptedSpeech(text: String) {
        requestResponse(text: text)
    }

    /// The honest default for a pipe with no model in it: there is nothing to declare to.
    ///
    /// **A wrapper must still forward it explicitly**, for the reason `requestScriptedSpeech`
    /// gives — inheriting this default would leave the inner adapter's tools undeclared while
    /// the composition above believed intent was being resolved by tool calling, which is a
    /// voice channel that hears the wearer and does nothing.
    func declareTools(_ tools: [VoiceToolDeclaration]) {}

    /// The honest default for the same reason, and a wrapper must forward it for the same
    /// reason: an ungrounded model chooses tools from an empty room.
    func updateInstructions(_ instructions: String) {}

    /// The honest default for a pipe with no model in it: nothing was asked, so nothing is
    /// coming. A wrapper over a backend that *has* one must forward it, or a session in
    /// native-turn mode would hear every word the wearer says and act on none of them.
    @discardableResult
    func requestModelTurn() -> Bool { false }

    /// The honest default for a backend that can never produce a tool call: there is no call
    /// outstanding, so there is nothing to answer. A wrapper over a backend that *can* must
    /// forward it, or every call it relayed upward would go unanswered.
    func sendToolResult(callID: String, output: String) {}
}
