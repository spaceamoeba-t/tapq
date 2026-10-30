import Foundation

/// Defaults for the OpenAI Realtime wire.
public enum RealtimeDefaults {
    /// The GA endpoint. The Beta API that used to answer here was retired on 2026-08-27,
    /// and a session that reaches for it now is refused before the first frame.
    public static let endpoint = URL(string: "wss://api.openai.com/v1/realtime")!
    /// The transcriber. Deprecated, shut down 2027-02-26 (research T3); the model name is
    /// configuration, so the migration is a probe and a default, not code.
    public static let inputTranscriptionModel = "gpt-4o-transcribe"
    /// The only encoding TapQ frames, matching `VoiceAudioFormat.pcm16Mono24k`.
    public static let audioFormat = RealtimeAudioFormat.pcm24k
    /// The most a session may hold queued for the socket (07-10, 03-8). Two megabytes is
    /// about fifteen seconds of base64 microphone audio: past it the connection is not
    /// draining, and audio that old is no longer worth sending.
    public static let outboundQueueLimit = 2 * 1024 * 1024
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

/// How an audio stream is encoded: a MIME type and a sample rate, as GA requires.
public struct RealtimeAudioFormat: Codable, Equatable, Sendable {
    public let type: String
    public let rate: Int?

    public init(type: String, rate: Int? = nil) {
        self.type = type
        self.rate = rate
    }

    /// 24 kHz is the only rate GA accepts for `audio/pcm`.
    public static let pcm24k = RealtimeAudioFormat(type: "audio/pcm", rate: 24_000)
}

/// Server-side voice activity detection for a transcription session: where one segment
/// ends and the next begins.
public struct RealtimeTurnDetection: Codable, Equatable, Sendable {
    public let type: String
    /// How loud the room has to get before `server_vad` calls it speech. `nil` leaves the
    /// service's own 0.5.
    public let threshold: Double?
    /// How much audio from *before* the detector fired is kept, and counted into
    /// `audio_start_ms`. `nil` leaves the service's own 300 ms.
    public let prefixPaddingMs: Int?
    /// How long the room stays quiet before the segment is finished. `nil` leaves the
    /// service's own 200 ms, which ends a segment at the first breath.
    public let silenceDurationMs: Int?

    public init(type: String, threshold: Double? = nil, prefixPaddingMs: Int? = nil,
                silenceDurationMs: Int? = nil) {
        self.type = type
        self.threshold = threshold
        self.prefixPaddingMs = prefixPaddingMs
        self.silenceDurationMs = silenceDurationMs
    }

    /// Plain silence-timer endpointing with the service's own numbers.
    public static let serverVAD = RealtimeTurnDetection(type: "server_vad")

    /// The same mode with its numbers stated. Every parameter defaults to `nil`, so
    /// `serverVAD()` and the ``serverVAD`` constant produce byte-identical frames.
    public static func serverVAD(threshold: Double? = nil,
                                 prefixPaddingMs: Int? = nil,
                                 silenceDurationMs: Int? = nil) -> RealtimeTurnDetection {
        RealtimeTurnDetection(type: "server_vad",
                              threshold: threshold,
                              prefixPaddingMs: prefixPaddingMs,
                              silenceDurationMs: silenceDurationMs)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case threshold
        case prefixPaddingMs = "prefix_padding_ms"
        case silenceDurationMs = "silence_duration_ms"
    }
}

/// Transcription settings for the input audio.
public struct RealtimeInputTranscription: Codable, Equatable, Sendable {
    public let model: String
    /// Free-text guidance for the transcriber; omitted from the frame when `nil`.
    public let prompt: String?
    /// The ISO-639-1 code the transcriber is told to expect, or `nil` to let it guess.
    /// Omitted from the frame when `nil`.
    public let language: String?

    public init(model: String = RealtimeDefaults.inputTranscriptionModel,
                prompt: String? = nil,
                language: String? = nil) {
        self.model = model
        self.prompt = prompt
        self.language = language
    }
}

/// What the service does to the audio before it transcribes it. Off is the absence of a
/// value (the service default), not a case.
public struct RealtimeNoiseReduction: Codable, Equatable, Sendable {
    public let type: String

    public init(type: String) {
        self.type = type
    }

    /// A microphone at the speaker's mouth: a headset, a handheld.
    public static let nearField = RealtimeNoiseReduction(type: "near_field")
    /// A microphone across the room from whoever is talking.
    public static let farField = RealtimeNoiseReduction(type: "far_field")
}

/// Everything TapQ says to the realtime service apart from the opening `session.update`,
/// which each session encodes from its own configuration type.
public enum RealtimeClientEvent: Equatable, Sendable {
    /// PCM16 audio for the input buffer. Base64 is the protocol's framing.
    case appendInputAudio(Data)
    /// Commits the input buffer: the trailing utterance at a recording's stop.
    case commitInputAudio
    /// One out-of-band spoken response: in no conversation, audio only, its one input item
    /// the user message `text`, read as `instructions` ask (research §4.3). Live, the text
    /// put in `instructions` with an empty input was sometimes answered as a chat ("Hey
    /// there! What can I help you with?"): 4 live readings in 50, 2 probe readings in 80.
    /// As an input item: 0 in 21 live, 0 in 80 probe.
    case createOutOfBandResponse(instructions: String, text: String)
    /// Cancels the named response (03-9): an unnamed cancel can cut whatever the service
    /// is producing by the time the frame lands.
    case cancelResponse(id: String)

    /// The JSON text frame for this event. Keys are sorted, so a frame is byte-stable.
    public func encodedFrame() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            switch self {
            case .appendInputAudio(let audio):
                data = try encoder.encode(AppendFrame(audio: audio.base64EncodedString()))
            case .commitInputAudio:
                data = try encoder.encode(CommitFrame())
            case .createOutOfBandResponse(let instructions, let text):
                data = try encoder.encode(OutOfBandResponseFrame(
                    response: .init(input: [.init(text: text)], instructions: instructions)))
            case .cancelResponse(let id):
                data = try encoder.encode(CancelFrame(responseID: id))
            }
        } catch {
            throw RealtimeMessageError.encodingFailed(String(describing: error))
        }
        return String(decoding: data, as: UTF8.self)
    }

    private struct AppendFrame: Encodable {
        let type = "input_audio_buffer.append"
        let audio: String
    }

    private struct CommitFrame: Encodable {
        let type = "input_audio_buffer.commit"
    }

    private struct OutOfBandResponseFrame: Encodable {
        /// An inline user message: present, `input` replaces the conversation as context.
        struct Message: Encodable {
            struct Content: Encodable {
                let type = "input_text"
                let text: String
            }

            let type = "message"
            let role = "user"
            let content: [Content]

            init(text: String) { content = [Content(text: text)] }
        }

        struct Response: Encodable {
            let conversation = "none"
            let input: [Message]
            let instructions: String
            let outputModalities = ["audio"]

            enum CodingKeys: String, CodingKey {
                case conversation, input, instructions
                case outputModalities = "output_modalities"
            }
        }

        let type = "response.create"
        let response: Response
    }

    private struct CancelFrame: Encodable {
        let type = "response.cancel"
        let responseID: String

        enum CodingKeys: String, CodingKey {
            case type
            case responseID = "response_id"
        }
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

    /// The service's planned end of a session at its 60-minute cap. Not in the service's
    /// docs; measured live.
    public var isSessionExpired: Bool { code == "session_expired" }

    /// A client's `input_audio_buffer.commit` that found nothing to commit (§8.4): the
    /// service's VAD had committed the buffer already, or less than 100 ms was in it. An
    /// answer to the client's own question, not the session failing; only a client commit
    /// draws it.
    public var isCommitEmpty: Bool { code == "input_audio_buffer_commit_empty" }

    /// True when retrying will not help because the credentials are the problem. Matched
    /// on substrings: the service has renamed these codes before.
    public var isAuthorization: Bool {
        let haystack = [type, code, message].compactMap { $0 }.joined(separator: " ").lowercased()
        return ["api_key", "api key", "unauthorized", "authentication", "invalid_request_error.auth"]
            .contains { haystack.contains($0) }
    }
}

/// Everything TapQ understands the service to say.
///
/// Unknown `type`s decode to `.unsupported` rather than throwing: the protocol gains events
/// regularly, and a session must not die on somebody else's release schedule.
public enum RealtimeServerEvent: Equatable, Sendable {
    case sessionCreated
    /// The configuration TapQ sent has been applied: the handshake ack.
    case sessionUpdated
    /// The VAD heard speech begin. `itemID` names the item the speech will become;
    /// `audioStartMs` is where, in milliseconds of audio the session has been fed, it began
    /// (prefix padding included). Both are `nil` for a peer that omits them.
    case speechStarted(itemID: String?, audioStartMs: Int?)
    /// The VAD heard that speech end, `audioEndMs` into the fed audio.
    case speechStopped(itemID: String?, audioEndMs: Int?)
    /// The input buffer was committed as the named item.
    case inputAudioCommitted(itemID: String?)
    /// A fragment of one item's transcript.
    case transcriptDelta(itemID: String?, delta: String)
    /// The settled transcript of one item.
    case transcriptCompleted(itemID: String?, transcript: String)
    /// The transcriber failed on one item; `reason` is the service's code, else its message.
    case transcriptFailed(itemID: String?, reason: String)
    /// The service started a response and named it.
    case responseCreated(id: String?)
    /// Response audio, base64-decoded to PCM16 bytes.
    case audioDelta(Data)
    /// The settled transcript of the audio the service just spoke.
    case spokenTranscript(String)
    /// The response ended. `status` is `completed`, `cancelled`, `failed` or `incomplete`
    /// (03-4); `reason` is the status details' error code or message, or their reason.
    case responseDone(id: String?, status: String?, reason: String?)
    case failure(RealtimeServerFailure)
    /// An event type this codec does not model, kept for diagnostics.
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
            return .speechStarted(itemID: envelope.itemID, audioStartMs: envelope.audioStartMs)
        case "input_audio_buffer.speech_stopped":
            return .speechStopped(itemID: envelope.itemID, audioEndMs: envelope.audioEndMs)
        case "input_audio_buffer.committed":
            return .inputAudioCommitted(itemID: envelope.itemID)
        case "conversation.item.input_audio_transcription.delta":
            return .transcriptDelta(itemID: envelope.itemID, delta: envelope.delta ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .transcriptCompleted(itemID: envelope.itemID,
                                        transcript: envelope.transcript ?? envelope.text ?? "")
        case "conversation.item.input_audio_transcription.failed":
            return .transcriptFailed(itemID: envelope.itemID,
                                     reason: envelope.error?.code ?? envelope.error?.message
                                         ?? "unspecified")
        case "response.created":
            return .responseCreated(id: envelope.response?.id)
        case "response.output_audio.delta":
            guard let encoded = envelope.delta else {
                throw RealtimeMessageError.malformedFrame("\(envelope.type) carried no audio")
            }
            guard let audio = Data(base64Encoded: encoded) else {
                throw RealtimeMessageError.malformedFrame(
                    "\(envelope.type) carried audio that is not base64")
            }
            return .audioDelta(audio)
        case "response.output_audio_transcript.done":
            return .spokenTranscript(envelope.transcript ?? envelope.text ?? "")
        case "response.done":
            let details = envelope.response?.statusDetails
            return .responseDone(id: envelope.response?.id,
                                 status: envelope.response?.status,
                                 reason: details?.error?.code ?? details?.error?.message
                                     ?? details?.reason)
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

    /// Tolerant by construction: unknown keys are ignored, and every field past `type` is
    /// optional, so a renamed payload field degrades to an empty value, not a dead session.
    private struct Envelope: Decodable {
        struct ErrorBody: Decodable {
            let type: String?
            let code: String?
            let message: String?
        }

        struct ResponseBody: Decodable {
            struct StatusDetails: Decodable {
                let reason: String?
                let error: ErrorBody?
            }

            let id: String?
            let status: String?
            let statusDetails: StatusDetails?

            enum CodingKeys: String, CodingKey {
                case id, status
                case statusDetails = "status_details"
            }
        }

        let type: String
        let delta: String?
        let transcript: String?
        let text: String?
        let error: ErrorBody?
        let response: ResponseBody?
        let itemID: String?
        let audioStartMs: Int?
        let audioEndMs: Int?

        enum CodingKeys: String, CodingKey {
            case type, delta, transcript, text, error, response
            case itemID = "item_id"
            case audioStartMs = "audio_start_ms"
            case audioEndMs = "audio_end_ms"
        }
    }
}
