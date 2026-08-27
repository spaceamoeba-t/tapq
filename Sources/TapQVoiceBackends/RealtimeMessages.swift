import Foundation

/// Defaults for the OpenAI Realtime slice TapQ speaks.
///
/// Statics rather than literals sprinkled through the adapter, matching
/// `OpenAILunaQuestionClassifier.defaultModel` / `.defaultEndpoint` / `.defaultTimeout`.
public enum RealtimeDefaults {
    public static let model = "gpt-realtime"
    public static let endpoint = URL(string: "wss://api.openai.com/v1/realtime")!
    /// Whisper-class transcription of the *wearer's* audio. Without this the session
    /// returns only the model's own words, and TapQ's grammar has nothing to match.
    public static let inputTranscriptionModel = "gpt-4o-transcribe"
    /// The only encoding this adapter frames, matching `VoiceAudioFormat.pcm16Mono24k`.
    public static let audioFormat = "pcm16"
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

/// Server-side voice activity detection: off by default, and never given more than one job
/// when it is on.
///
/// Modelled as a value rather than hardcoded so both settings are visible on the wire and
/// assertable in a test. `.disabled` is what every session starts with and what an
/// IMU-armed run stays on. `.serverVAD` is the carve-out documented on `VoiceBackend`: with
/// no wearer turn signal, the service is allowed to say where the sentence ended, and
/// nothing else.
public struct RealtimeTurnDetection: Codable, Equatable, Sendable {
    public let type: String
    /// Whether the service may start a response of its own when its VAD ends a turn.
    /// TapQ sends `false` and only `false`: end-of-speech detection is delegated, speaking
    /// never is — TapQ authors every sentence its voice says. Omitted from the frame when
    /// nil, which is how `.disabled` keeps encoding to exactly `{"type":"none"}`.
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

    /// Manual-turn mode: the server never commits a buffer or starts a response on its
    /// own. The value every session is established with.
    public static let disabled = RealtimeTurnDetection(type: "none")

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

/// The `session` payload of a `session.update`.
///
/// Only the fields this slice needs. Everything absent is left at the service default on
/// purpose: an adapter that pins settings it does not care about turns every upstream
/// default change into a TapQ behavior change.
public struct RealtimeSessionConfiguration: Codable, Equatable, Sendable {
    public var model: String
    public var modalities: [String]
    public var inputAudioFormat: String
    public var outputAudioFormat: String
    public var inputAudioTranscription: RealtimeInputTranscription?
    /// `.disabled` on every handshake. The adapter overwrites whatever a caller passes, and
    /// moves the live session to `.serverVAD` only through `setNativeTurnDetection(true)`.
    public var turnDetection: RealtimeTurnDetection
    public var instructions: String?
    public var voice: String?

    public init(model: String = RealtimeDefaults.model,
                modalities: [String] = ["audio", "text"],
                inputAudioFormat: String = RealtimeDefaults.audioFormat,
                outputAudioFormat: String = RealtimeDefaults.audioFormat,
                inputAudioTranscription: RealtimeInputTranscription? = RealtimeInputTranscription(),
                turnDetection: RealtimeTurnDetection = .disabled,
                instructions: String? = nil,
                voice: String? = nil) {
        self.model = model
        self.modalities = modalities
        self.inputAudioFormat = inputAudioFormat
        self.outputAudioFormat = outputAudioFormat
        self.inputAudioTranscription = inputAudioTranscription
        self.turnDetection = turnDetection
        self.instructions = instructions
        self.voice = voice
    }

    enum CodingKeys: String, CodingKey {
        case model
        case modalities
        case instructions
        case voice
        case inputAudioFormat = "input_audio_format"
        case outputAudioFormat = "output_audio_format"
        case inputAudioTranscription = "input_audio_transcription"
        case turnDetection = "turn_detection"
    }
}

/// Everything TapQ ever says to the realtime service.
///
/// Pinned to the OpenAI Realtime protocol as observed 2026-05 (`gpt-realtime` family).
/// The set is small by design — this is a speech pipe, and every client event beyond
/// these six would be policy leaking across the `VoiceBackend` boundary.
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
        case "response.output_audio.delta", "response.audio.delta":
            guard let encoded = envelope.delta else {
                throw RealtimeMessageError.malformedFrame("\(envelope.type) carried no audio")
            }
            guard let audio = Data(base64Encoded: encoded) else {
                throw RealtimeMessageError.malformedFrame(
                    "\(envelope.type) carried audio that is not base64")
            }
            return .audioDelta(audio)
        case "response.done", "response.completed":
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
