import Foundation
import TapQContracts

/// A `VoiceBackend` over the OpenAI Realtime API in **manual-turn mode**.
///
/// The entire adapter exists to make a duplex, VAD-happy cloud service behave like the
/// dumb speech pipe `VoiceBackend` describes:
///
/// - The first frame on every connection is a `session.update` carrying
///   `turn_detection: none`, and the handshake is not considered complete until the
///   service acknowledges it with `session.updated`. Until that ack lands, the service
///   would be running its own voice-activity detection, and a server-side commit would
///   resolve an approval window TapQ never authorized.
/// - Audio only ever leaves during an open user turn, the buffer is committed only from
///   `endUserTurn()`, and a response is only ever created by TapQ — on commit, or on an
///   explicit `requestResponse(text:)`.
/// - `capabilities` reports what the *transport* can do (barge-in, audio, duplex). TapQ
///   still runs half-duplex; that policy is enforced by `VoiceTurnStateMachine`, which
///   every inbound call and every server event routes through, so a protocol mistake
///   surfaces as `sessionFailed(.protocolViolation)` rather than as scrambled turns.
///
/// Nothing here can hang: the handshake is bounded by `timeout`, outbound frames drain
/// through one ordered pump whose failures end the session, and a dropped connection
/// arrives as `sessionFailed`. The API key lives in the transport's headers and appears in
/// no diagnostic, no failure description, and no frame this file builds.
@MainActor public final class OpenAIRealtimeVoiceBackend: VoiceBackend {
    // `nonisolated` because these are default arguments on this class's own initializers,
    // which are evaluated in the caller's isolation domain.
    public nonisolated static let defaultModel = RealtimeDefaults.model
    public nonisolated static let defaultEndpoint = RealtimeDefaults.endpoint
    public nonisolated static let defaultTimeout: TimeInterval = 5
    /// Audio is framed into blocks no longer than this before it is base64-encoded and
    /// sent. A caller handing over a second of audio would otherwise base64 a second of
    /// audio in one main-actor turn.
    public nonisolated static let maxChunkSeconds: TimeInterval = 0.1

    /// The wire format both directions of this session use.
    public nonisolated static let audioFormat = VoiceAudioFormat.pcm16Mono24k

    public let capabilities = VoiceBackendCapabilities(supportsBargeIn: true,
                                                       producesAudio: true,
                                                       duplex: true)

    private let transport: any RealtimeTransporting
    private let configuration: RealtimeSessionConfiguration
    private let timeout: TimeInterval
    private let monotonicNow: @Sendable () -> TimeInterval
    private let diagnostics: TapQDiagnosticEmitter

    private var turns: VoiceTurnStateMachine
    private var onEvent: (@MainActor (VoiceBackendEvent) -> Void)?
    /// Invalidates late transport frames, drain loops, and timeout tasks belonging to a
    /// session that has already been torn down. Bumped on every open and every teardown.
    private var sessionGeneration: UInt64 = 0

    private var handshakeContinuation: CheckedContinuation<Void, any Error>?
    private var handshakeGeneration: UInt64?
    /// Set when the handshake settles before anyone is waiting on it — the ack can land in
    /// the same main-actor turn the frame was sent in.
    private var handshakeOutcome: (generation: UInt64, result: Result<Void, VoiceBackendFailure>)?

    /// Ordered outbound queue. `sendAudio` is synchronous by contract and the transport's
    /// send is not, so frames queue here and one pump drains them; two concurrent tasks
    /// would interleave appends into scrambled audio.
    private var outbound: [String] = []
    private var pumpRunning = false

    /// Cumulative transcript for the current turn — the whole utterance so far, which is
    /// the shape `VoiceCommandMatcher` expects. The service sends deltas.
    private var transcript = ""

    /// Bytes of audio appended in the current turn. An `endUserTurn` with zero appended
    /// audio sends neither `commit` nor `response.create` — the OpenAI service rejects an
    /// empty commit, and a silent teardown turn must not create spurious responses.
    private var turnAudioByteCount = 0

    /// - Parameters:
    ///   - transport: the frame pipe. Injected so tests drive a scripted server and never a
    ///     socket, and so Linux never links a `URLSessionWebSocketTask`.
    ///   - monotonicNow: clock for stamping inbound audio chunks, injectable for tests.
    public init(transport: any RealtimeTransporting,
                configuration: RealtimeSessionConfiguration = RealtimeSessionConfiguration(),
                timeout: TimeInterval = OpenAIRealtimeVoiceBackend.defaultTimeout,
                monotonicNow: @escaping @Sendable () -> TimeInterval = {
                    ProcessInfo.processInfo.systemUptime
                },
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.transport = transport
        // The one setting the adapter refuses to take on faith: whatever a caller passes,
        // this session runs without server-side turn detection.
        var manualTurns = configuration
        manualTurns.turnDetection = .disabled
        self.configuration = manualTurns
        self.timeout = timeout
        self.monotonicNow = monotonicNow
        self.diagnostics = TapQDiagnosticEmitter(category: "OpenAIRealtime", sink: diagnosticSink)
        self.turns = VoiceTurnStateMachine(
            capabilities: VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                   duplex: true))
    }

    #if canImport(Darwin)
    /// Composition-time convenience: the live WebSocket transport, built from an API key.
    ///
    /// Apple-only for the same reason `URLSessionWebSocketRealtimeTransport` is.
    public convenience init(apiKey: String,
                            model: String = OpenAIRealtimeVoiceBackend.defaultModel,
                            endpoint: URL = OpenAIRealtimeVoiceBackend.defaultEndpoint,
                            timeout: TimeInterval = OpenAIRealtimeVoiceBackend.defaultTimeout,
                            diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "model", value: model)]
        let url = components?.url ?? endpoint
        self.init(transport: URLSessionWebSocketRealtimeTransport(url: url, apiKey: apiKey),
                  configuration: RealtimeSessionConfiguration(model: model),
                  timeout: timeout,
                  diagnosticSink: diagnosticSink)
    }
    #endif

    var turnStateForTesting: VoiceTurnStateMachine.State { turns.state }

    // MARK: - Session lifecycle

    public func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
        do {
            try turns.open()
        } catch {
            throw VoiceBackendFailure.protocolViolation(Self.describe(error))
        }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        self.onEvent = onEvent
        transcript = ""

        do {
            try await transport.connect()
        } catch {
            guard sessionGeneration == generation else {
                throw VoiceBackendFailure.closed("the session was torn down while connecting")
            }
            let failure = Self.failure(from: error)
            diagnostics.record("connect.failed", level: .warning,
                               fields: ["detail": failure.localizedDescription])
            turns.sessionFailed()
            teardown(expectedGeneration: generation)
            throw failure
        }
        guard sessionGeneration == generation else {
            // `close()` landed while the connection was still being established. Nobody
            // else owns this transport, so it is ours to shut.
            transport.close()
            throw VoiceBackendFailure.closed("the session was torn down while connecting")
        }

        startReceiveLoop(generation: generation)
        handshakeGeneration = generation
        // Manual-turn mode before anything else, including before any audio can exist.
        enqueue(.sessionUpdate(configuration), generation: generation)
        try await awaitHandshake(generation: generation)
        diagnostics.record("session.opened", fields: ["model": configuration.model])
    }

    public func close() {
        let wasOpen = turns.isOpen || onEvent != nil
        teardown()
        if wasOpen { diagnostics.record("session.closed") }
    }

    // MARK: - Turns

    public func beginUserTurn() {
        do {
            try turns.beginUserTurn()
        } catch {
            return violated(error)
        }
        transcript = ""
        turnAudioByteCount = 0
        diagnostics.record("turn.began")
    }

    public func sendAudio(_ chunk: VoiceAudioChunk) {
        do {
            try turns.sendAudio()
        } catch {
            return violated(error)
        }
        guard chunk.format == Self.audioFormat else {
            // A caller feeding the wrong encoding produces audio the service will happily
            // transcribe as noise. Loud beats a session that silently mishears everything.
            return violated(VoiceBackendFailure.protocolViolation(
                "the session speaks \(Int(Self.audioFormat.sampleRate)) Hz PCM16 mono; "
                    + "a chunk arrived as \(Int(chunk.format.sampleRate)) Hz "
                    + "\(chunk.format.channels)-channel"))
        }
        guard !chunk.data.isEmpty else { return }
        turnAudioByteCount += chunk.data.count
        let generation = sessionGeneration
        for block in Self.split(chunk, maxSeconds: Self.maxChunkSeconds) {
            enqueue(.appendInputAudio(block), generation: generation)
        }
    }

    @discardableResult
    public func endUserTurn(expectingResponse: Bool) -> Bool {
        do {
            try turns.endUserTurn()
        } catch {
            violated(error)
            return false
        }
        // Empty-turn guard: if no audio was appended during this turn, skip the commit
        // and response.create entirely. The OpenAI service rejects an empty commit, and a
        // silent teardown turn must not create spurious responses.
        guard turnAudioByteCount > 0 else {
            diagnostics.record("turn.empty_skipped")
            return false
        }
        let generation = sessionGeneration
        enqueue(.commitInputAudio, generation: generation)
        // When TapQ does not want a spoken reply (match-resolved, gesture stop,
        // activity pause), commit for transcription only — no response.create.
        // Input transcription rides the commit, not the response, so match-by-transcript
        // still works on the committed audio.
        guard expectingResponse else {
            diagnostics.record("turn.committed_no_response")
            return false
        }
        // Manual-turn mode is commit-then-create: the service produces nothing until asked,
        // so the commit that ends the wearer's turn is immediately followed by the request
        // that starts the model's.
        do {
            try turns.requestResponse()
        } catch {
            violated(error)
            return false
        }
        enqueue(.createResponse(instructions: nil), generation: generation)
        diagnostics.record("turn.committed")
        return true
    }

    public func requestResponse(text: String) {
        do {
            try turns.requestResponse()
        } catch {
            return violated(error)
        }
        diagnostics.record("response.requested", fields: ["length": "\(text.count)"])
        enqueue(.createResponse(instructions: text), generation: sessionGeneration)
    }

    public func cancelResponse() {
        do {
            try turns.cancelResponse()
        } catch {
            return violated(error)
        }
        diagnostics.record("response.cancelled")
        enqueue(.cancelResponse, generation: sessionGeneration)
    }

    // MARK: - Inbound

    private func startReceiveLoop(generation: UInt64) {
        let frames = transport.receiveFrames()
        Task { @MainActor [weak self] in
            do {
                for try await frame in frames {
                    guard let self, self.sessionGeneration == generation else { return }
                    self.handle(frame: frame, generation: generation)
                }
            } catch {
                guard let self, self.sessionGeneration == generation else { return }
                return self.failSession(Self.failure(from: error), generation: generation)
            }
            guard let self, self.sessionGeneration == generation else { return }
            self.failSession(.closed("the realtime peer closed the connection"),
                             generation: generation)
        }
    }

    private func handle(frame: String, generation: UInt64) {
        let event: RealtimeServerEvent
        do {
            event = try RealtimeServerEvent.decode(frame)
        } catch {
            return failSession(.protocolViolation(Self.describe(error)), generation: generation)
        }

        switch event {
        case .sessionCreated:
            // Not the ack: the service has a session, but it is still the service's own
            // VAD running it until `session.updated` confirms otherwise.
            diagnostics.record("session.created")
        case .sessionUpdated:
            settleHandshake(.success(()), generation: generation)
        case .transcriptDelta(let delta):
            guard !delta.isEmpty else { return }
            transcript += delta
            emit(.transcriptPartial(transcript))
        case .transcriptCompleted(let settled):
            if !settled.isEmpty { transcript = settled }
            emit(.transcriptFinal(transcript))
        case .audioDelta(let audio):
            emit(.audio(VoiceAudioChunk(data: audio, format: Self.audioFormat,
                                        timestamp: monotonicNow())))
        case .responseCompleted:
            do {
                try turns.responseCompleted()
            } catch {
                // Nothing was in flight: the service produced a response nobody asked for,
                // which is the manual-turn contract being broken from the far side.
                return failSession(
                    .protocolViolation("the realtime peer completed a response TapQ never requested"),
                    generation: generation)
            }
            emit(.responseCompleted)
        case .failure(let failure):
            let mapped: VoiceBackendFailure = failure.isAuthorization
                ? .authorization(failure.message)
                : .protocolViolation(failure.message)
            failSession(mapped, generation: generation)
        case .unsupported(let type):
            diagnostics.record("event.ignored", fields: ["type": type])
        }
    }

    // MARK: - Outbound pump

    private func enqueue(_ event: RealtimeClientEvent, generation: UInt64) {
        guard sessionGeneration == generation else { return }
        let frame: String
        do {
            frame = try event.encodedFrame()
        } catch {
            return failSession(.protocolViolation(Self.describe(error)), generation: generation)
        }
        outbound.append(frame)
        guard !pumpRunning else { return }
        pumpRunning = true
        Task { @MainActor [weak self] in
            await self?.drainOutbound(generation: generation)
        }
    }

    private func drainOutbound(generation: UInt64) async {
        while true {
            // A stale pump touches nothing: the live session owns `pumpRunning` now.
            guard sessionGeneration == generation else { return }
            guard !outbound.isEmpty else {
                pumpRunning = false
                return
            }
            let frame = outbound.removeFirst()
            do {
                try await transport.send(frame)
            } catch {
                guard sessionGeneration == generation else { return }
                pumpRunning = false
                return failSession(Self.failure(from: error), generation: generation)
            }
        }
    }

    // MARK: - Handshake

    private func awaitHandshake(generation: UInt64) async throws {
        if let outcome = handshakeOutcome, outcome.generation == generation {
            handshakeOutcome = nil
            return try outcome.result.get()
        }
        guard handshakeGeneration == generation else {
            throw VoiceBackendFailure.closed("the session was torn down during the handshake")
        }

        let bound = timeout
        let deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(bound))
            guard !Task.isCancelled else { return }
            self?.failSession(
                .network("the realtime session handshake timed out after \(Self.format(bound))s"),
                generation: generation)
        }
        defer { deadline.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            handshakeContinuation = continuation
        }
    }

    private func settleHandshake(_ result: Result<Void, VoiceBackendFailure>, generation: UInt64) {
        guard handshakeGeneration == generation else { return }
        handshakeGeneration = nil
        guard let continuation = handshakeContinuation else {
            handshakeOutcome = (generation, result)
            return
        }
        handshakeContinuation = nil
        continuation.resume(with: result.mapError { $0 as any Error })
    }

    // MARK: - Failure and teardown

    private func violated(_ error: any Error) {
        let failure = (error as? VoiceBackendFailure) ?? .protocolViolation(Self.describe(error))
        failSession(failure, generation: sessionGeneration)
    }

    /// Ends the session and reports it exactly once.
    ///
    /// While the handshake is still outstanding the failure is delivered by throwing out of
    /// `open`, not as an event — a caller whose `open` threw never installed a window and
    /// must not also be told the window died.
    private func failSession(_ failure: VoiceBackendFailure, generation: UInt64) {
        guard sessionGeneration == generation else { return }
        diagnostics.record("session.failed", level: .warning,
                           fields: ["detail": failure.localizedDescription])
        let callback = onEvent
        let handshaking = handshakeGeneration == generation
        turns.sessionFailed()
        if handshaking {
            settleHandshake(.failure(failure), generation: generation)
            teardown(expectedGeneration: generation)
            return
        }
        teardown(expectedGeneration: generation)
        callback?(.sessionFailed(failure))
    }

    private func teardown(expectedGeneration: UInt64? = nil) {
        if let expectedGeneration, expectedGeneration != sessionGeneration { return }
        let generation = sessionGeneration
        sessionGeneration &+= 1
        onEvent = nil
        outbound.removeAll()
        pumpRunning = false
        transcript = ""
        turns.close()
        transport.close()
        // A continuation that is never resumed is a task leaked forever, so teardown from
        // any path settles an outstanding handshake before it forgets about it.
        if handshakeGeneration == generation {
            settleHandshake(
                .failure(.closed("the session was torn down during the handshake")),
                generation: generation)
        }
    }

    private func emit(_ event: VoiceBackendEvent) {
        onEvent?(event)
    }

    // MARK: - Pure helpers

    /// Splits a chunk into blocks of at most `maxSeconds` of PCM16 audio, preserving order
    /// and never splitting a sample frame in half.
    static func split(_ chunk: VoiceAudioChunk, maxSeconds: TimeInterval) -> [Data] {
        let bytesPerFrame = max(1, 2 * chunk.format.channels)
        let framesPerBlock = max(1, Int(maxSeconds * chunk.format.sampleRate))
        let blockSize = framesPerBlock * bytesPerFrame
        guard chunk.data.count > blockSize else { return chunk.data.isEmpty ? [] : [chunk.data] }

        var blocks: [Data] = []
        var index = chunk.data.startIndex
        while index < chunk.data.endIndex {
            let end = chunk.data.index(index, offsetBy: blockSize, limitedBy: chunk.data.endIndex)
                ?? chunk.data.endIndex
            blocks.append(Data(chunk.data[index..<end]))
            index = end
        }
        return blocks
    }

    private static func failure(from error: any Error) -> VoiceBackendFailure {
        switch error {
        case let failure as VoiceBackendFailure:
            return failure
        case let failure as RealtimeTransportFailure:
            switch failure {
            case .connectFailed(let detail):
                return .network("connect failed: \(detail)")
            case .sendFailed(let detail):
                return .network("send failed: \(detail)")
            case .receiveFailed(let detail):
                return .network("receive failed: \(detail)")
            case .closed(let detail):
                return .closed(detail)
            }
        default:
            return .network(String(describing: error))
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let violation = error as? VoiceTurnViolation { return violation.localizedDescription }
        if let failure = error as? VoiceBackendFailure { return failure.localizedDescription }
        if let message = error as? RealtimeMessageError { return message.localizedDescription }
        return String(describing: error)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%g", seconds)
    }
}
