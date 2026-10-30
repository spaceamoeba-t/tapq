import Foundation
import TapQContracts

/// `audio.input` of a transcription session. `turn_detection` is always sent: with
/// detection off the session would never emit a segment.
public struct RealtimeTranscriptionInputAudio: Encodable, Equatable, Sendable {
    public var format: RealtimeAudioFormat
    public var transcription: RealtimeInputTranscription
    /// `nil` is omitted from the frame: the service's default of no filter.
    public var noiseReduction: RealtimeNoiseReduction?
    public var turnDetection: RealtimeTurnDetection

    public init(format: RealtimeAudioFormat = RealtimeDefaults.audioFormat,
                transcription: RealtimeInputTranscription,
                noiseReduction: RealtimeNoiseReduction? = nil,
                turnDetection: RealtimeTurnDetection = .serverVAD) {
        self.format = format
        self.transcription = transcription
        self.noiseReduction = noiseReduction
        self.turnDetection = turnDetection
    }

    enum CodingKeys: String, CodingKey {
        case format
        case transcription
        case noiseReduction = "noise_reduction"
        case turnDetection = "turn_detection"
    }
}

/// The `audio` object of a transcription session: an input side and no output.
public struct RealtimeTranscriptionAudio: Encodable, Equatable, Sendable {
    public var input: RealtimeTranscriptionInputAudio

    public init(input: RealtimeTranscriptionInputAudio) {
        self.input = input
    }
}

/// The `session` of the one `session.update` a transcription session sends: `type` and
/// `audio`, and no `model`, `output_modalities`, `instructions` or `tools` (the service
/// refuses a transcription session that carries a `model`).
public struct RealtimeTranscriptionConfiguration: Encodable, Equatable, Sendable {
    public let type = "transcription"
    public var audio: RealtimeTranscriptionAudio

    /// - Parameters:
    ///   - prompt: guidance for the transcriber, or `nil` for none.
    ///   - language: the ISO-639-1 code to expect, or `nil` to let the transcriber guess.
    ///   - noiseReduction: what the service does to the audio first, or `nil` for nothing.
    public init(model: String = RealtimeDefaults.inputTranscriptionModel,
                prompt: String? = nil,
                language: String? = nil,
                noiseReduction: RealtimeNoiseReduction? = nil,
                turnDetection: RealtimeTurnDetection = .serverVAD) {
        self.audio = RealtimeTranscriptionAudio(
            input: RealtimeTranscriptionInputAudio(
                transcription: RealtimeInputTranscription(model: model,
                                                          prompt: prompt,
                                                          language: language),
                noiseReduction: noiseReduction,
                turnDetection: turnDetection))
    }
}

/// Everything a transcription session tells its caller.
public enum RealtimeTranscriptionEvent: Sendable, Equatable {
    /// The peer's VAD heard speech begin, `audioStartMs` into the fed audio (prefix padding
    /// included). `nil` for a peer that omits them.
    case speechStarted(itemID: String?, audioStartMs: Int?)
    /// The peer's VAD heard speech end, `audioEndMs` into the fed audio.
    case speechStopped(itemID: String?, audioEndMs: Int?)
    /// The peer took the buffer and created an item for it.
    case committed(itemID: String?)
    /// A fragment of one segment's transcript, not the segment so far; the caller
    /// accumulates by id. Never empty.
    case delta(itemID: String?, text: String)
    /// The settled transcript of one segment, which replaces what was accumulated for that
    /// id. Reported even when empty.
    case completed(itemID: String?, transcript: String)
    /// The transcriber failed on one segment; the session goes on.
    case transcriptionFailed(itemID: String?, reason: String)
    /// A `commit()` of the caller's found nothing to commit (§8.4,
    /// `input_audio_buffer_commit_empty`): the VAD had committed the buffer already. The
    /// session goes on (2026-10-19); only a caller's commit draws it.
    case commitEmpty
    /// The service ended the session at its duration cap (`session_expired`, D4). Terminal.
    case expired
    /// Terminal: every error frame but `session_expired`, `server_error` and an empty commit,
    /// an undecodable frame, a connection the peer refused (an HTTP 401 at the upgrade, a
    /// close that names a refusal), or audio sent before `open()`; for the loop, also every
    /// `dropped`.
    case failed(reason: String)
    /// The network ended the session (2026-10-19): a transport error, the peer hanging up, a
    /// stalled queue, the service's `server_error`. A new session may outlive it; the loop
    /// treats it as `failed`, always-on transcription opens another.
    case dropped(reason: String)
}

/// An OpenAI Realtime **transcription-only** session: PCM in, transcript segments out. No
/// turns, responses, tools or playback. Transcription mode and the loop's speech input read it.
///
/// Fail out loud: every ending but `close()` is the last event on the stream, and nothing
/// here retries or reconnects. The handshake is bounded by `timeout`. Transcript text never
/// reaches the diagnostics; the API key lives only in the transport's header.
@MainActor public final class RealtimeTranscriptionSession {
    /// The realtime URL plus `?intent=transcription`: the plain URL is refused before the
    /// first client frame (close 4000, `invalid_request_error.missing_model`).
    public nonisolated static let defaultEndpoint: URL = {
        var components = URLComponents(url: RealtimeDefaults.endpoint,
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        return components.url!
    }()
    public nonisolated static let defaultTimeout: TimeInterval = 10
    /// The one encoding `sendAudio` accepts.
    public nonisolated static let audioFormat = VoiceAudioFormat.pcm16Mono24k
    /// The longest single `input_audio_buffer.append`.
    nonisolated static let maxChunkSeconds: TimeInterval = 0.1

    private let connection: RealtimeConnection
    private let configuration: RealtimeTranscriptionConfiguration
    private let eventStream: AsyncStream<RealtimeTranscriptionEvent>
    private let eventContinuation: AsyncStream<RealtimeTranscriptionEvent>.Continuation

    /// The handshake has landed and the session has not ended.
    public var isOpen: Bool { connection.phase == .open }
    /// Audio and frames handed to the wire and not yet sent.
    public var outboundBytes: Int { connection.outboundBytes }
    /// Every byte handed to the wire so far, and every byte it has sent: a caller that marks
    /// where its audio stood in the first count knows, from the second, how much of it has
    /// left the process, and whether the wire is sending at all.
    public var handedBytes: Int { connection.handedBytes }
    public var sentBytes: Int { connection.sentBytes }
    /// Fired each time the wire has sent everything it was handed.
    public var onOutboundDrained: (@MainActor () -> Void)? {
        get { connection.onDrained }
        set { connection.onDrained = newValue }
    }

    /// - Parameters:
    ///   - timeout: how long the handshake may take.
    ///   - sendTimeout: how long one send may go without returning before the socket is
    ///     taken for one that stopped draining, ended as a drop. `nil` (the loop's): no bound
    ///     but the queue's cap.
    ///   - sleep: how the handshake bound and the send bound are waited out.
    ///   - diagnosticSink: never handed audio or transcript text.
    public init(transport: any RealtimeTransporting,
                configuration: RealtimeTranscriptionConfiguration,
                timeout: TimeInterval = RealtimeTranscriptionSession.defaultTimeout,
                sendTimeout: TimeInterval? = nil,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(for: .seconds(seconds))
                },
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.configuration = configuration
        connection = RealtimeConnection(
            transport: transport, name: "transcription", timeout: timeout,
            sendTimeout: sendTimeout, sleep: sleep,
            diagnostics: TapQDiagnosticEmitter(category: "transcription", sink: diagnosticSink))
        (eventStream, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        connection.onEvent = { [weak self] in self?.handle($0) }
        connection.onEnd = { [weak self] in self?.ended($0) }
    }

    #if canImport(Darwin)
    /// The live WebSocket transport. `endpoint` is a parameter so a test harness can point
    /// a session at its own peer.
    public convenience init(apiKey: String,
                            configuration: RealtimeTranscriptionConfiguration
                                = RealtimeTranscriptionConfiguration(),
                            endpoint: URL = RealtimeTranscriptionSession.defaultEndpoint,
                            timeout: TimeInterval = RealtimeTranscriptionSession.defaultTimeout,
                            sendTimeout: TimeInterval? = nil,
                            diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.init(transport: URLSessionWebSocketRealtimeTransport(url: endpoint, apiKey: apiKey),
                  configuration: configuration,
                  timeout: timeout,
                  sendTimeout: sendTimeout,
                  diagnosticSink: diagnosticSink)
    }
    #endif

    /// One stream for one consumer, in the order the peer reported. It finishes at
    /// `close()` and right after a terminal event.
    public var events: AsyncStream<RealtimeTranscriptionEvent> { eventStream }

    // MARK: - Lifecycle

    /// Connects, states the session, and waits for the ack: until it lands the service
    /// transcribes with settings nobody chose.
    ///
    /// - Throws: `VoiceBackendFailure`: `.network` for a failed connect, a dropped socket or
    ///   a handshake that timed out, `.authorization` for an error frame that blames the
    ///   credentials, `.protocolViolation` for any other error frame or an undecodable one,
    ///   `.closed` for a peer that hung up or a `close()` that raced the handshake. A throw
    ///   is the only report of a failed open.
    public func open() async throws {
        try await connection.open(configuration)
        let input = configuration.audio.input
        connection.diagnostics.record("session.opened", fields: [
            "model": input.transcription.model,
            "turn_detection": input.turnDetection.type,
            "rate": input.format.rate.map { "\($0)" } ?? "unstated",
            "language": input.transcription.language ?? "none",
            "noise_reduction": input.noiseReduction?.type ?? "none",
            "silence_ms": input.turnDetection.silenceDurationMs.map { "\($0)" } ?? "default",
        ])
    }

    /// Streams microphone audio in appends of at most ``maxChunkSeconds``. Legal from the
    /// moment `open()` has sent the `session.update`, behind which it queues. Before `open()`
    /// it ends the session out loud; audio in another encoding ends it too.
    public func sendAudio(_ chunk: VoiceAudioChunk) {
        guard requireLiveSession(for: "input_audio_buffer.append") else { return }
        guard chunk.format == Self.audioFormat else {
            return connection.fail(
                "the session speaks \(Int(Self.audioFormat.sampleRate)) Hz PCM16 mono; "
                    + "a chunk arrived as \(Int(chunk.format.sampleRate)) Hz "
                    + "\(chunk.format.channels)-channel")
        }
        for block in Self.split(chunk, maxSeconds: Self.maxChunkSeconds) {
            connection.send(.appendInputAudio(block))
        }
    }

    /// Asks the peer for what is still in the buffer: the trailing utterance at a stop.
    /// Same precondition as `sendAudio`.
    public func commit() {
        guard requireLiveSession(for: "input_audio_buffer.commit") else { return }
        connection.send(.commitInputAudio)
    }

    /// Ends the session. Idempotent; finishes `events` without a terminal event.
    public func close() {
        connection.close()
    }

    // MARK: - Events

    private func handle(_ event: RealtimeServerEvent) {
        let diagnostics = connection.diagnostics
        switch event {
        case .speechStarted(let itemID, let audioStartMs):
            diagnostics.record("vad.speech_started", level: .debug, fields: [
                "audio_start_ms": audioStartMs.map { "\($0)" } ?? "unstated",
            ])
            eventContinuation.yield(.speechStarted(itemID: itemID, audioStartMs: audioStartMs))
        case .speechStopped(let itemID, let audioEndMs):
            diagnostics.record("vad.speech_stopped", level: .debug, fields: [
                "audio_end_ms": audioEndMs.map { "\($0)" } ?? "unstated",
            ])
            eventContinuation.yield(.speechStopped(itemID: itemID, audioEndMs: audioEndMs))
        case .inputAudioCommitted(let itemID):
            diagnostics.record("vad.committed", level: .debug,
                               fields: ["item_id": itemID ?? "unnamed"])
            eventContinuation.yield(.committed(itemID: itemID))
        case .transcriptDelta(let itemID, let delta):
            guard !delta.isEmpty else { return }
            eventContinuation.yield(.delta(itemID: itemID, text: delta))
        case .transcriptCompleted(let itemID, let transcript):
            // The length, never a word of it.
            diagnostics.record("transcript.completed", level: .debug, fields: [
                "item_id": itemID ?? "unnamed",
                "chars": "\(transcript.count)",
            ])
            eventContinuation.yield(.completed(itemID: itemID, transcript: transcript))
        case .transcriptFailed(let itemID, let reason):
            diagnostics.record("transcript.failed", level: .warning, fields: [
                "item_id": itemID ?? "unnamed",
                "reason": reason,
            ])
            eventContinuation.yield(.transcriptionFailed(itemID: itemID, reason: reason))
        case .failure(let failure) where failure.isCommitEmpty:
            // The one error frame the connection hands on (2026-10-19).
            diagnostics.record("vad.commit_empty", level: .debug)
            eventContinuation.yield(.commitEmpty)
        default:
            // A new event type is a fact about the service, not an error.
            diagnostics.record("event.ignored", level: .debug,
                               fields: ["type": Self.ignoredType(of: event)])
        }
    }

    private func ended(_ ending: RealtimeConnection.Ending?) {
        switch ending {
        case .expired: eventContinuation.yield(.expired)
        case .failed(let reason, let retryable):
            eventContinuation.yield(retryable ? .dropped(reason: reason) : .failed(reason: reason))
        case nil: break
        }
        eventContinuation.finish()
    }

    /// Before `open()` a send fails the session out loud; after its end it is recorded
    /// only, since the stream has already finished.
    private func requireLiveSession(for frame: String) -> Bool {
        switch connection.phase {
        case .open, .handshaking:
            return true
        case .idle:
            connection.fail("\(frame) arrived before the session was opened")
            return false
        case .ended:
            connection.diagnostics.record("frame.afterEnd", level: .warning,
                                          fields: ["type": frame])
            return false
        }
    }

    /// Blocks of at most `maxSeconds` of PCM16, in order, never splitting a sample frame.
    private static func split(_ chunk: VoiceAudioChunk, maxSeconds: TimeInterval) -> [Data] {
        let bytesPerFrame = max(1, 2 * chunk.format.channels)
        let blockSize = max(1, Int(maxSeconds * chunk.format.sampleRate)) * bytesPerFrame
        return stride(from: 0, to: chunk.data.count, by: blockSize).map { offset in
            let start = chunk.data.startIndex + offset
            return Data(chunk.data[start..<min(start + blockSize, chunk.data.endIndex)])
        }
    }

    private static func ignoredType(of event: RealtimeServerEvent) -> String {
        switch event {
        case .sessionCreated: return "session.created"
        case .unsupported(let type): return type
        default: return "\(event)".prefix(while: { $0 != "(" }).description
        }
    }
}
