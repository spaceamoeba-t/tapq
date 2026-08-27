import Foundation
import TapQContracts

/// A `VoiceBackend` over the OpenAI Realtime API in **manual-turn mode**.
///
/// The entire adapter exists to make a duplex, VAD-happy cloud service behave like the
/// dumb speech pipe `VoiceBackend` describes:
///
/// - The first frame on every connection is a `session.update` carrying
///   `audio.input.turn_detection: null`, and the handshake is not considered complete until the
///   service acknowledges it with `session.updated`. Until that ack lands, the service
///   would be running its own voice-activity detection on settings TapQ never chose, and a
///   server-side commit would resolve an approval window TapQ never authorized.
/// - Audio only ever leaves during an open user turn, the buffer is committed only from
///   `endUserTurn()`, and a response is only ever created by TapQ — on commit, or on an
///   explicit `requestResponse(text:)`.
/// - `setNativeTurnDetection(true)` is the one documented exception, and it is a second
///   `session.update` on an already-established session, never a shortcut through the
///   handshake above. It moves `turn_detection` to `server_vad` with `create_response:
///   false` and `interrupt_response: false`, so the service may say where a sentence ended
///   and may not do anything else. The empty-turn guard, the "a response happens only when
///   TapQ asks" rule, and the half-duplex policy are all untouched by it. See the carve-out
///   on `VoiceBackend` for why TapQ ever asks.
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
                                                       duplex: true,
                                                       supportsNativeTurnDetection: true)

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

    /// Set by `cancelResponse()`, cleared by `beginUserTurn`/teardown. When the next
    /// `response.done` arrives, the adapter treats it as the documented cancel ack rather
    /// than as an unrequested completion (which would throw `.noResponseInFlight` from
    /// `.open` and kill the session). A cancel racing a just-completed response produces an
    /// `error` event instead; that is also absorbed when this flag is set.
    private var expectCancelAck = false

    /// Cumulative transcript for the current turn — the whole utterance so far, which is
    /// the shape `VoiceCommandMatcher` expects. The service sends deltas.
    private var transcript = ""

    /// Bytes of audio appended since the last commit. An `endUserTurn` with zero appended
    /// audio sends neither `commit` nor `response.create` — the OpenAI service rejects an
    /// empty commit, and a silent teardown turn must not create spurious responses. Reset
    /// on `beginUserTurn` and on every commit, including the service's own: what it counts
    /// is what is sitting in the input buffer right now.
    private var turnAudioByteCount = 0

    /// The mode TapQ has asked for, which outlives any one session: a caller sets it once
    /// per window and a reconnect must come back up in it rather than silently reverting to
    /// manual. Applied to a session only through `applyTurnDetection`.
    private var nativeTurnDetectionRequested = false
    /// The mode this session is actually in. Separate from the request so `applyTurnDetection`
    /// can be called freely — from `open`, from a caller, from a caller before `open` — and
    /// send a frame only when something really changed.
    private var nativeTurnDetectionApplied = false
    /// Commits this adapter issued that the service has not yet echoed back as
    /// `input_audio_buffer.committed`.
    ///
    /// The service sends that event for TapQ's own commits *and* for the ones its VAD makes,
    /// with nothing in the payload that distinguishes them. Counting is the distinction:
    /// an echo that matches an outstanding commit is an ack, and one that does not is the
    /// service ending an utterance on its own — legal only in native mode, fatal otherwise.
    private var pendingOwnCommits = 0

    /// - Parameters:
    ///   - transport: the frame pipe. Injected so tests drive a scripted server and never a
    ///     socket, and so Linux never links a `URLSessionWebSocketTask`.
    ///   - monotonicNow: clock for stamping inbound audio chunks, injectable for tests.
    public init(transport: any RealtimeTransporting,
                configuration: RealtimeSessionConfiguration = RealtimeSessionConfiguration(
                    instructions: RealtimeDefaults.baseInstructions
                ),
                timeout: TimeInterval = OpenAIRealtimeVoiceBackend.defaultTimeout,
                monotonicNow: @escaping @Sendable () -> TimeInterval = {
                    ProcessInfo.processInfo.systemUptime
                },
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.transport = transport
        // The one setting the adapter refuses to take on faith: whatever a caller passes,
        // this session runs without server-side turn detection.
        var manualTurns = configuration
        manualTurns.turnDetection = nil
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
                  // Set here as well as in the designated initializer's default: this path
                  // passes a configuration of its own, so a session opened from an API key
                  // would otherwise be the one session that ran with no standing rules.
                  configuration: RealtimeSessionConfiguration(
                      model: model,
                      instructions: RealtimeDefaults.baseInstructions
                  ),
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
        // A new session starts in manual-turn mode no matter what the last one was doing.
        // `nativeTurnDetectionRequested` survives, and is re-applied once the handshake
        // lands — a reconnect must come back up in the mode the caller asked for.
        nativeTurnDetectionApplied = false
        pendingOwnCommits = 0

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
        // Only now, on an established session whose settings the service has acknowledged,
        // is the degraded mode allowed to be asked for. Folding `server_vad` into the
        // handshake frame would save one round trip and give away the property the handshake
        // exists for: that there is no instant in a session's life where the service is
        // running turn detection TapQ did not deliberately turn on.
        applyTurnDetection(generation: generation)
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
        expectCancelAck = false
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
        // In native mode the service owns commits, and whatever is in the buffer at window
        // teardown is the tail end of an utterance its VAD has not called finished. TapQ
        // must not commit it: the fragment is usually shorter than the 100 ms the service
        // accepts, and a rejected commit arrives as an `error` frame that ends the session.
        // Dropping it is the right answer anyway — nobody is listening for it any more, and
        // the buffer outlives this window.
        guard !nativeTurnDetectionApplied else {
            turnAudioByteCount = 0
            enqueue(.clearInputAudio, generation: generation)
            diagnostics.record("turn.ended_native")
            return false
        }
        pendingOwnCommits += 1
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
        expectCancelAck = true
        diagnostics.record("response.cancelled")
        enqueue(.cancelResponse, generation: sessionGeneration)
    }

    // MARK: - Turn detection mode

    public func setNativeTurnDetection(_ enabled: Bool) {
        nativeTurnDetectionRequested = enabled
        // Before a session exists, or while its handshake is still in flight, the request is
        // recorded and nothing is sent: `open` applies it the moment the service has
        // acknowledged the manual-turn configuration, which is the only ordering that keeps
        // the "no unauthorized VAD, ever" property of the handshake intact.
        guard turns.isOpen, handshakeGeneration == nil else { return }
        applyTurnDetection(generation: sessionGeneration)
    }

    /// Brings the live session into the requested mode, or does nothing if it is already
    /// there. Idempotent by construction, so every caller can call it unconditionally.
    private func applyTurnDetection(generation: UInt64) {
        guard sessionGeneration == generation else { return }
        guard nativeTurnDetectionApplied != nativeTurnDetectionRequested else { return }
        nativeTurnDetectionApplied = nativeTurnDetectionRequested
        // The state machine learns the mode before the frame goes out, not after: the
        // service can answer a `session.update` with a VAD commit in the same breath, and a
        // machine that still thought the session was manual would call that a violation and
        // kill the session TapQ had just degraded on purpose.
        turns.setNativeTurnDetection(nativeTurnDetectionApplied)
        var update = configuration
        update.turnDetection = nativeTurnDetectionApplied ? .serverVAD : nil
        enqueue(.sessionUpdate(update), generation: generation)
        diagnostics.record("turn_detection.updated",
                           fields: ["mode": nativeTurnDetectionApplied ? "server_vad" : "null"])
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
        case .speechStarted:
            // Recorded, never acted on. The service's opinion about where speech began is
            // not an event TapQ has any use for — it does not open windows, does not
            // attribute the speaker, and does not arm barge-in — but a "voice did nothing"
            // report is far easier to read when the log shows whether the service heard
            // anything at all.
            diagnostics.record("native_turn.speech_started")
        case .speechStopped:
            diagnostics.record("native_turn.speech_stopped")
        case .inputAudioCommitted:
            handleInputAudioCommitted(generation: generation)
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
            if expectCancelAck {
                // The server acked a locally-initiated cancel with response.done (cancelled).
                // The state machine is already in .open from cancelResponse(); calling
                // responseCompleted() would throw .noResponseInFlight. Still emit the event
                // so the caller clears any response-in-flight tracking (straggler audio
                // deltas after the cancel re-arm the provider's _responseInFlight, and
                // without a terminal responseCompleted the next start() would hit the same
                // violation path).
                expectCancelAck = false
                diagnostics.record("cancel_ack.received")
                emit(.responseCompleted)
                return
            }
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
            if expectCancelAck, !failure.isAuthorization {
                // A cancel racing a just-completed response: the server returns an error
                // because there is nothing to cancel. This is expected and benign — the
                // response finished normally, and the cancel was simply too late.
                expectCancelAck = false
                diagnostics.record("cancel_ack.race_error",
                                   fields: ["message": failure.message])
                return
            }
            let mapped: VoiceBackendFailure = failure.isAuthorization
                ? .authorization(failure.message)
                : .protocolViolation(failure.message)
            failSession(mapped, generation: generation)
        case .unsupported(let type):
            diagnostics.record("event.ignored", fields: ["type": type])
        }
    }

    /// Sorts an `input_audio_buffer.committed` into an ack for a commit TapQ sent and a
    /// commit the service's own VAD made, and lets only the second one reach the caller.
    private func handleInputAudioCommitted(generation: UInt64) {
        if pendingOwnCommits > 0 {
            pendingOwnCommits -= 1
            diagnostics.record("commit.acked")
            return
        }
        let endedUtterance: Bool
        do {
            endedUtterance = try turns.backendCommittedUserTurn()
        } catch {
            // Native mode is off and the service committed anyway. This is precisely the
            // failure non-negotiable 1 names: the transcript that follows such a commit can
            // match the grammar and resolve an approval window nobody authorized, so the
            // session dies here rather than one frame later with a decision attached.
            return failSession(
                .protocolViolation(
                    "the realtime peer committed the input buffer while TapQ owned turn arbitration"),
                generation: generation)
        }
        // The buffer the service just took is gone; what follows belongs to the next
        // utterance. The transcript is reset for the same reason — each VAD segment is a
        // whole utterance as far as the grammar is concerned, and carrying the previous
        // sentence's words into the next one would have the matcher answering a question
        // out of two half-heard ones.
        turnAudioByteCount = 0
        transcript = ""
        guard endedUtterance else {
            // A segment that closed outside an open user turn: between windows, or while a
            // response is playing. Tolerated (the service's VAD tracks the audio stream, not
            // TapQ's windows) and reported to nobody — there is no window it could resolve.
            diagnostics.record("native_turn.commit_ignored",
                               fields: ["state": turns.state.rawValue])
            return
        }
        diagnostics.record("native_turn.committed")
        emit(.userAudioCommittedByBackend)
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
        expectCancelAck = false
        turnAudioByteCount = 0
        pendingOwnCommits = 0
        // The applied mode belongs to the session that just died; the requested one belongs
        // to the caller and is re-applied by the next `open`.
        nativeTurnDetectionApplied = false
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
