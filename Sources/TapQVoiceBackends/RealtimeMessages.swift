import Foundation

/// Defaults for the OpenAI Realtime slice TapQ speaks.
///
/// Statics rather than literals sprinkled through the adapter, matching
/// `OpenAILunaQuestionClassifier.defaultModel` / `.defaultEndpoint` / `.defaultTimeout`.
public enum RealtimeDefaults {
    public static let model = "gpt-realtime"
    /// The GA endpoint. The Beta API that used to answer here was retired on 2026-08-27,
    /// and a session that reaches for it now is refused before the first frame.
    public static let endpoint = URL(string: "wss://api.openai.com/v1/realtime")!
    /// What kind of session this is. GA requires it on every `session.update`; the Beta
    /// session object had no discriminator at all.
    public static let sessionType = "realtime"
    /// Whisper-class transcription of the *wearer's* audio. Without this the session
    /// returns only the model's own words, and TapQ's grammar has nothing to match.
    public static let inputTranscriptionModel = "gpt-4o-transcribe"
    /// The only encoding this adapter frames, matching `VoiceAudioFormat.pcm16Mono24k`.
    public static let audioFormat = RealtimeAudioFormat.pcm24k
    /// GA takes one output modality, not the Beta pair. `audio` is the one TapQ needs, and
    /// asking for it does not cost the transcript — an audio response carries its own.
    public static let outputModalities = ["audio"]
    /// What the session is for, sent once with the first `session.update`.
    ///
    /// TapQ asks this model to do exactly two things: read sentences TapQ wrote, and
    /// answer a wearer's question from context TapQ supplied. Both jobs arrive as
    /// per-response instructions; this is the standing rule that keeps a model which
    /// receives one of them from improvising the other. It says nothing about approvals
    /// because no approval sentence is ever routed here — that split is enforced by
    /// `BackendPreferredSpeech`, and a system prompt is the wrong place to guard it.
    public static let baseInstructions = """
        You are the voice of TapQ, a hands-free assistant. Speak text you are given \
        verbatim, without preface or commentary. Answer a wearer's question briefly, \
        using only the context provided with it. Never invent what an agent is doing.
        """
}

/// A frame that could not be built or understood.
public enum RealtimeMessageError: Error, LocalizedError, Equatable, Sendable {
    case encodingFailed(String)
    case malformedFrame(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed(let detail):
            return "The realtime client event could not be encoded: \(detail)."
        case .malformedFrame(let detail):
            return "The realtime server frame could not be read: \(detail)."
        }
    }
}

/// How an audio stream is encoded.
///
/// Beta named an encoding with a bare string (`"pcm16"`). GA takes an object with a MIME
/// type and a sample rate, and rejects the string outright, so the shape has to be modelled
/// even though TapQ only ever sends one value.
public struct RealtimeAudioFormat: Codable, Equatable, Sendable {
    public let type: String
    public let rate: Int?

    public init(type: String, rate: Int? = nil) {
        self.type = type
        self.rate = rate
    }

    /// The one format this adapter frames, matching `VoiceAudioFormat.pcm16Mono24k`. 24 kHz
    /// is the only rate GA accepts for `audio/pcm`, which is why the mic pump and the
    /// playback path never had to change across this migration.
    public static let pcm24k = RealtimeAudioFormat(type: "audio/pcm", rate: 24_000)
}

/// Server-side voice activity detection, never given more than one job when it is on.
///
/// Modelled as a value rather than hardcoded so the setting is visible on the wire and
/// assertable in a test. Turn detection being *off* is not a value in GA — it is the
/// absence of one, a literal `null` under `audio.input.turn_detection` — so manual-turn
/// mode is `nil` here rather than a `.disabled` case. `.serverVAD` is the carve-out
/// documented on `VoiceBackend`: with no wearer turn signal, the service is allowed to say
/// where the sentence ended, and nothing else.
public struct RealtimeTurnDetection: Codable, Equatable, Sendable {
    public let type: String
    /// Whether the service may start a response of its own when its VAD ends a turn.
    /// TapQ sends `false` and only `false`: end-of-speech detection is delegated, speaking
    /// never is — TapQ authors every sentence its voice says.
    public let createResponse: Bool?
    /// Whether the service may cut its own playback short when it hears speech. TapQ sends
    /// `false`: barge-in belongs to `WearerTurnCoordinator`, which knows whether the voice
    /// it heard was the wearer's, and a service that truncates on a colleague's cough would
    /// be resolving a policy question from the wrong side of the boundary.
    public let interruptResponse: Bool?

    public init(type: String, createResponse: Bool? = nil, interruptResponse: Bool? = nil) {
        self.type = type
        self.createResponse = createResponse
        self.interruptResponse = interruptResponse
    }

    /// Degraded-turn mode: the server's own VAD commits the input buffer at speech-end so a
    /// transcript exists, and does nothing else — no response, no interruption.
    public static let serverVAD = RealtimeTurnDetection(type: "server_vad",
                                                        createResponse: false,
                                                        interruptResponse: false)

    enum CodingKeys: String, CodingKey {
        case type
        case createResponse = "create_response"
        case interruptResponse = "interrupt_response"
    }
}

/// Transcription settings for the wearer's own audio.
public struct RealtimeInputTranscription: Codable, Equatable, Sendable {
    public let model: String

    public init(model: String = RealtimeDefaults.inputTranscriptionModel) {
        self.model = model
    }
}

/// Everything GA groups under `session.audio.input` — the wearer's side of the session.
public struct RealtimeInputAudioConfiguration: Codable, Equatable, Sendable {
    public var format: RealtimeAudioFormat
    public var transcription: RealtimeInputTranscription?
    /// `nil` on every handshake, and `nil` again whenever native detection is turned back
    /// off. The adapter overwrites whatever a caller passes and moves the live session to
    /// `.serverVAD` only through `setNativeTurnDetection(true)`.
    public var turnDetection: RealtimeTurnDetection?

    public init(format: RealtimeAudioFormat = RealtimeDefaults.audioFormat,
                transcription: RealtimeInputTranscription? = RealtimeInputTranscription(),
                turnDetection: RealtimeTurnDetection? = nil) {
        self.format = format
        self.transcription = transcription
        self.turnDetection = turnDetection
    }

    enum CodingKeys: String, CodingKey {
        case format
        case transcription
        case turnDetection = "turn_detection"
    }

    /// Hand-written for one reason: `turn_detection` must be an explicit `null` when it is
    /// off, never an absent key. GA's `session.update` is a merge — an omitted field keeps
    /// whatever the session already had — so the synthesized encoding, which drops nil
    /// keys, would make the native-back-to-manual transition a no-op and leave the service's
    /// VAD running against TapQ's own turn arbitration.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encodeIfPresent(transcription, forKey: .transcription)
        if let turnDetection {
            try container.encode(turnDetection, forKey: .turnDetection)
        } else {
            try container.encodeNil(forKey: .turnDetection)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(RealtimeAudioFormat.self, forKey: .format)
        transcription = try container.decodeIfPresent(RealtimeInputTranscription.self,
                                                      forKey: .transcription)
        turnDetection = try container.decodeIfPresent(RealtimeTurnDetection.self,
                                                      forKey: .turnDetection)
    }
}

/// Everything GA groups under `session.audio.output` — the voice TapQ speaks with.
public struct RealtimeOutputAudioConfiguration: Codable, Equatable, Sendable {
    public var format: RealtimeAudioFormat
    /// Beta carried this at the top of the session object; GA moved it here.
    public var voice: String?

    public init(format: RealtimeAudioFormat = RealtimeDefaults.audioFormat,
                voice: String? = nil) {
        self.format = format
        self.voice = voice
    }
}

/// The `audio` object GA introduced. Beta spelled these four settings as four flat keys.
public struct RealtimeAudioConfiguration: Codable, Equatable, Sendable {
    public var input: RealtimeInputAudioConfiguration
    public var output: RealtimeOutputAudioConfiguration

    public init(input: RealtimeInputAudioConfiguration = RealtimeInputAudioConfiguration(),
                output: RealtimeOutputAudioConfiguration = RealtimeOutputAudioConfiguration()) {
        self.input = input
        self.output = output
    }
}

/// The `session` payload of a `session.update`, in GA shape.
///
/// Only the fields this slice needs. Everything absent is left at the service default on
/// purpose: an adapter that pins settings it does not care about turns every upstream
/// default change into a TapQ behavior change. The one exception is `turn_detection`, which
/// is pinned precisely because the service default — `server_vad` with `create_response`
/// on — is the thing TapQ exists to not have.
public struct RealtimeSessionConfiguration: Codable, Equatable, Sendable {
    public var type: String
    public var model: String
    public var outputModalities: [String]
    public var audio: RealtimeAudioConfiguration
    public var instructions: String?

    public init(model: String = RealtimeDefaults.model,
                type: String = RealtimeDefaults.sessionType,
                outputModalities: [String] = RealtimeDefaults.outputModalities,
                audio: RealtimeAudioConfiguration = RealtimeAudioConfiguration(),
                turnDetection: RealtimeTurnDetection? = nil,
                instructions: String? = nil,
                voice: String? = nil) {
        self.type = type
        self.model = model
        self.outputModalities = outputModalities
        self.audio = audio
        self.instructions = instructions
        if turnDetection != nil { self.audio.input.turnDetection = turnDetection }
        if let voice { self.audio.output.voice = voice }
    }

    /// Where turn detection lives in GA, reached from where every caller already looked for
    /// it. The adapter flips this on an otherwise-untouched copy of the configuration, which
    /// is the whole of what a mode change is on the wire.
    public var turnDetection: RealtimeTurnDetection? {
        get { audio.input.turnDetection }
        set { audio.input.turnDetection = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case model
        case audio
        case instructions
        case outputModalities = "output_modalities"
    }
}

/// Everything TapQ ever says to the realtime service.
///
/// Pinned to the GA OpenAI Realtime protocol as verified against the live service
/// 2026-08-27 (`gpt-realtime` family). The client event *names* survived the Beta
/// retirement unchanged; only the `session.update` payload was reshaped. The set is small
/// by design — this is a speech pipe, and every client event beyond these six would be
/// policy leaking across the `VoiceBackend` boundary.
public enum RealtimeClientEvent: Equatable, Sendable {
    /// Configures the session. Always the first frame on a connection: until it lands, the
    /// service is running its own VAD.
    case sessionUpdate(RealtimeSessionConfiguration)
    /// Appends PCM16 audio to the input buffer. Base64 is the protocol's framing, not a
    /// choice this adapter makes.
    case appendInputAudio(Data)
    /// Commits the input buffer. In manual-turn mode this is the *only* thing that ends a
    /// user turn, and only TapQ sends it.
    case commitInputAudio
    /// Discards whatever is in the input buffer without transcribing it.
    ///
    /// Sent at one moment only: a window ending while the server's own VAD owns commits.
    /// Whatever the wearer said since the last VAD commit is a fragment nobody is listening
    /// for any more, and the buffer outlives the window — left there, it would be prepended
    /// to the next window's utterance and transcribed as part of a sentence spoken minutes
    /// later. Committing it instead is not an option: the service rejects a commit holding
    /// less than 100 ms of audio, and a rejected commit is an `error` frame that ends the
    /// session.
    case clearInputAudio
    /// Asks the model to respond. `instructions` carries TapQ's own text when the caller
    /// wants something specific spoken.
    case createResponse(instructions: String?)
    /// Barge-in: abandon the in-flight response.
    case cancelResponse

    /// The JSON text frame for this event.
    ///
    /// Keys are sorted so a frame is byte-stable across runs — worth it for readable test
    /// failures and for log lines that diff cleanly.
    public func encodedFrame() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            switch self {
            case .sessionUpdate(let configuration):
                data = try encoder.encode(SessionUpdateFrame(session: configuration))
            case .appendInputAudio(let audio):
                data = try encoder.encode(AppendFrame(audio: audio.base64EncodedString()))
            case .commitInputAudio:
                data = try encoder.encode(CommitFrame())
            case .clearInputAudio:
                data = try encoder.encode(ClearFrame())
            case .createResponse(let instructions):
                let response = instructions.map { ResponseCreateFrame.Response(instructions: $0) }
                data = try encoder.encode(ResponseCreateFrame(response: response))
            case .cancelResponse:
                data = try encoder.encode(ResponseCancelFrame())
            }
        } catch {
            throw RealtimeMessageError.encodingFailed(String(describing: error))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The `type` this event carries on the wire, for assertions and diagnostics.
    public var wireType: String {
        switch self {
        case .sessionUpdate: return "session.update"
        case .appendInputAudio: return "input_audio_buffer.append"
        case .commitInputAudio: return "input_audio_buffer.commit"
        case .clearInputAudio: return "input_audio_buffer.clear"
        case .createResponse: return "response.create"
        case .cancelResponse: return "response.cancel"
        }
    }

    private struct SessionUpdateFrame: Encodable {
        let type = "session.update"
        let session: RealtimeSessionConfiguration
    }

    private struct AppendFrame: Encodable {
        let type = "input_audio_buffer.append"
        let audio: String
    }

    private struct CommitFrame: Encodable {
        let type = "input_audio_buffer.commit"
    }

    private struct ClearFrame: Encodable {
        let type = "input_audio_buffer.clear"
    }

    private struct ResponseCreateFrame: Encodable {
        struct Response: Encodable {
            let instructions: String
        }

        let type = "response.create"
        let response: Response?
    }

    private struct ResponseCancelFrame: Encodable {
        let type = "response.cancel"
    }
}

/// An `error` event from the service.
public struct RealtimeServerFailure: Equatable, Sendable {
    public let type: String?
    public let code: String?
    public let message: String

    public init(type: String?, code: String?, message: String) {
        self.type = type
        self.code = code
        self.message = message
    }

    /// True when retrying will not help because the credentials are the problem.
    ///
    /// Matched on substrings rather than an exact code list: the service has renamed these
    /// codes before, and mistaking an auth failure for a transport blip means a fail-through
    /// wrapper reconnecting forever against a key that will never work.
    public var isAuthorization: Bool {
        let haystack = [type, code, message].compactMap { $0 }.joined(separator: " ").lowercased()
        return ["api_key", "api key", "unauthorized", "authentication", "invalid_request_error.auth"]
            .contains { haystack.contains($0) }
    }
}

/// Everything TapQ understands the service to say.
///
/// Unknown `type`s decode to `.unsupported` rather than throwing: the realtime protocol
/// gains events regularly, and a session that dies because the service mentioned a new
/// one would be a voice channel that breaks on somebody else's release schedule.
public enum RealtimeServerEvent: Equatable, Sendable {
    case sessionCreated
    /// The configuration TapQ sent has been applied. This — not `session.created` — is the
    /// handshake ack, because before it lands the service is still running its own VAD.
    case sessionUpdated
    /// The service's own VAD heard speech begin in the input buffer. Diagnostic only, and
    /// only ever seen while native turn detection is on.
    case speechStarted
    /// The service's own VAD heard speech end. Diagnostic only: the commit that follows is
    /// what actually matters, and acting on this instead would double-count a segment.
    case speechStopped
    /// The input buffer was committed and a conversation item created. Sent for TapQ's own
    /// `input_audio_buffer.commit` *and* for a commit the service's VAD made on its own —
    /// the adapter tells them apart by counting the commits it issued.
    case inputAudioCommitted
    /// Incremental transcript of the *wearer's* audio.
    case transcriptDelta(String)
    /// Settled transcript of the wearer's audio for the committed turn.
    case transcriptCompleted(String)
    /// Response audio, already base64-decoded to PCM16 bytes.
    case audioDelta(Data)
    /// The response finished.
    case responseCompleted
    case failure(RealtimeServerFailure)
    /// A event type this adapter does not model, kept for diagnostics.
    case unsupported(String)

    public static func decode(_ frame: String) throws -> RealtimeServerEvent {
        guard let data = frame.data(using: .utf8) else {
            throw RealtimeMessageError.malformedFrame("the frame is not UTF-8")
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw RealtimeMessageError.malformedFrame("no readable `type` field")
        }

        switch envelope.type {
        case "session.created":
            return .sessionCreated
        case "session.updated":
            return .sessionUpdated
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "input_audio_buffer.speech_stopped":
            return .speechStopped
        case "input_audio_buffer.committed":
            return .inputAudioCommitted
        case "conversation.item.input_audio_transcription.delta":
            return .transcriptDelta(envelope.delta ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .transcriptCompleted(envelope.transcript ?? envelope.text ?? "")
        // GA renamed this from Beta's `response.audio.delta`. The old name is not accepted
        // here any more: the API that sent it no longer exists, and a dead alias in a
        // decode switch reads like a live compatibility promise.
        case "response.output_audio.delta":
            guard let encoded = envelope.delta else {
                throw RealtimeMessageError.malformedFrame("\(envelope.type) carried no audio")
            }
            guard let audio = Data(base64Encoded: encoded) else {
                throw RealtimeMessageError.malformedFrame(
                    "\(envelope.type) carried audio that is not base64")
            }
            return .audioDelta(audio)
        case "response.done":
            return .responseCompleted
        case "error":
            guard let error = envelope.error else {
                throw RealtimeMessageError.malformedFrame("an error event carried no error")
            }
            return .failure(RealtimeServerFailure(type: error.type, code: error.code,
                                                  message: error.message ?? "unspecified"))
        default:
            return .unsupported(envelope.type)
        }
    }

    /// Tolerant by construction: unknown keys are ignored by `Decodable`, and every field
    /// past `type` is optional, so a frame that renames a payload field degrades to an
    /// empty transcript rather than a dead session.
    private struct Envelope: Decodable {
        struct ErrorBody: Decodable {
            let type: String?
            let code: String?
            let message: String?
        }

        let type: String
        let delta: String?
        let transcript: String?
        let text: String?
        let error: ErrorBody?
    }
}
