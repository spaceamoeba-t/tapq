import XCTest
@testable import TapQVoiceBackends
import TapQContracts

@MainActor
final class OpenAIRealtimeVoiceBackendTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        var names: [String] { events.map(\.name) }
    }

    /// Fixed clock so audio timestamps are assertable.
    private nonisolated static let now: TimeInterval = 1_234.5

    private func makeBackend(_ server: ScriptedRealtimeServer,
                             timeout: TimeInterval = 1,
                             sink: RecordingSink = RecordingSink())
        -> OpenAIRealtimeVoiceBackend {
        OpenAIRealtimeVoiceBackend(transport: server,
                                   timeout: timeout,
                                   monotonicNow: { Self.now },
                                   diagnosticSink: sink)
    }

    /// Frames cross two task hops (the outbound pump and the receive loop), so tests hand
    /// the main actor back before asserting.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// Opens a session with a live turn, which is where most of these tests start.
    private func openTurn(_ backend: OpenAIRealtimeVoiceBackend,
                          collecting events: EventLog) async throws {
        try await backend.open { events.append($0) }
        backend.beginUserTurn()
        await settle()
    }

    /// Reference type so the capture in `open`'s handler and the assertions see the same
    /// list without fighting exclusivity.
    @MainActor
    final class EventLog {
        private(set) var events: [VoiceBackendEvent] = []
        func append(_ event: VoiceBackendEvent) { events.append(event) }
        var failures: [VoiceBackendFailure] {
            events.compactMap { if case .sessionFailed(let f) = $0 { return f } else { return nil } }
        }
        var transcripts: [String] {
            events.compactMap {
                switch $0 {
                case .transcriptPartial(let t), .transcriptFinal(let t): return t
                default: return nil
                }
            }
        }
    }

    private func pcm16(_ frames: Int, byte: UInt8 = 0x11) -> VoiceAudioChunk {
        VoiceAudioChunk(data: Data(repeating: byte, count: frames * 2),
                        format: OpenAIRealtimeVoiceBackend.audioFormat,
                        timestamp: 0)
    }

    // MARK: - Handshake

    func testOpenConfiguresManualTurnsBeforeAnythingElse() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)

        try await backend.open { _ in }

        XCTAssertEqual(server.sentTypes, ["session.update"])
        let detection = server.sessionConfiguration?["turn_detection"] as? [String: Any]
        XCTAssertEqual(detection?["type"] as? String, "none")
        XCTAssertTrue(sink.names.contains("session.opened"))
    }

    func testCallerSuppliedTurnDetectionIsOverridden() async throws {
        let server = ScriptedRealtimeServer()
        let backend = OpenAIRealtimeVoiceBackend(
            transport: server,
            configuration: RealtimeSessionConfiguration(
                turnDetection: RealtimeTurnDetection(type: "server_vad")),
            timeout: 1)

        try await backend.open { _ in }

        let detection = server.sessionConfiguration?["turn_detection"] as? [String: Any]
        XCTAssertEqual(detection?["type"] as? String, "none",
                       "the adapter refuses to run a session the service can end itself")
    }

    func testSessionCreatedAloneDoesNotCompleteTheHandshake() async {
        let server = ScriptedRealtimeServer()
        server.acknowledgesSessionUpdate = false
        server.announcesSessionCreated = true
        let backend = makeBackend(server, timeout: 0.05)

        do {
            try await backend.open { _ in }
            XCTFail("session.created is not confirmation that turn detection is off")
        } catch {
            guard case .network(let detail)? = error as? VoiceBackendFailure else {
                return XCTFail("expected a network failure, got \(error)")
            }
            XCTAssertTrue(detail.contains("timed out"))
        }
        XCTAssertEqual(server.closeCount, 1, "a session that never opened leaves no socket")
    }

    func testConnectFailureSurfacesAsATypedOpenError() async {
        let server = ScriptedRealtimeServer()
        server.connectFailure = .connectFailed("dns lookup failed")
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)

        do {
            try await backend.open { _ in }
            XCTFail("the handshake cannot succeed without a connection")
        } catch {
            guard case .network(let detail)? = error as? VoiceBackendFailure else {
                return XCTFail("expected a network failure, got \(error)")
            }
            XCTAssertTrue(detail.contains("dns lookup failed"))
        }
        XCTAssertEqual(server.sentTypes, [])
        XCTAssertEqual(sink.events.first { $0.name == "connect.failed" }?.level, .warning)
    }

    func testHandshakeFailureIsReportedByThrowingRatherThanAsAnEvent() async {
        let server = ScriptedRealtimeServer()
        server.acknowledgesSessionUpdate = false
        let events = EventLog()
        let backend = makeBackend(server, timeout: 0.05)

        do {
            try await backend.open { events.append($0) }
            XCTFail("the handshake timed out")
        } catch {
            XCTAssertTrue(error is VoiceBackendFailure)
        }
        await settle()

        XCTAssertEqual(events.events, [],
                       "a caller whose open threw never installed a window to fail")
    }

    func testASecondOpenAfterAFailedHandshakeSucceeds() async throws {
        let server = ScriptedRealtimeServer()
        server.acknowledgesSessionUpdate = false
        let backend = makeBackend(server, timeout: 0.05)

        try? await backend.open { _ in }
        server.acknowledgesSessionUpdate = true
        try await backend.open { _ in }

        XCTAssertEqual(backend.turnStateForTesting, .open)
    }

    func testOpeningAnAlreadyOpenSessionIsAProtocolViolation() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        try await backend.open { _ in }

        do {
            try await backend.open { _ in }
            XCTFail("a second open on a live session is a programming error")
        } catch {
            guard case .protocolViolation? = error as? VoiceBackendFailure else {
                return XCTFail("expected a protocol violation, got \(error)")
            }
        }
    }

    // MARK: - Manual turn cycle

    func testTurnCycleAppendsThenCommitsThenCreates() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()

        try await openTurn(backend, collecting: events)
        XCTAssertEqual(server.sentTypes, ["session.update"],
                       "beginning a turn is a local state change; nothing is on the wire yet")

        backend.sendAudio(pcm16(240))
        await settle()
        XCTAssertEqual(server.sentTypes, ["session.update", "input_audio_buffer.append"])

        backend.endUserTurn(expectingResponse: true)
        await settle()
        XCTAssertEqual(server.sentTypes, ["session.update", "input_audio_buffer.append",
                                          "input_audio_buffer.commit", "response.create"])
        XCTAssertEqual(backend.turnStateForTesting, .responding)
        XCTAssertEqual(events.events, [])
    }

    func testAudioIsFramedIntoBlocksOfAtMostOneHundredMilliseconds() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        // Half a second at 24 kHz mono: five 100 ms blocks.
        backend.sendAudio(pcm16(12_000))
        await settle()

        XCTAssertEqual(server.appendedAudio.count, 5)
        XCTAssertEqual(server.appendedAudio.map(\.count), Array(repeating: 4_800, count: 5))
        XCTAssertEqual(server.appendedAudio.reduce(Data(), +).count, 24_000,
                       "splitting must not lose or duplicate a byte")
    }

    func testSplitPreservesOrderAndSampleFrames() async {
        let chunk = VoiceAudioChunk(data: Data((0..<10).map { UInt8($0) }),
                                    format: VoiceAudioFormat(sampleRate: 20, channels: 1),
                                    timestamp: 0)
        // 100 ms at 20 Hz is two frames — four bytes a block.
        let blocks = OpenAIRealtimeVoiceBackend.split(chunk, maxSeconds: 0.1)

        XCTAssertEqual(blocks, [Data([0, 1, 2, 3]), Data([4, 5, 6, 7]), Data([8, 9])])
        XCTAssertTrue(blocks.dropLast().allSatisfy { $0.count % 2 == 0 },
                      "a block that ends mid-sample is a click in the wearer's audio")
    }

    func testSmallChunksAreSentWhole() async {
        let blocks = OpenAIRealtimeVoiceBackend.split(pcm16(10), maxSeconds: 0.1)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(OpenAIRealtimeVoiceBackend.split(pcm16(0), maxSeconds: 0.1), [])
    }

    func testAppendsReachThePeerInOrder() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        // Three 100 ms blocks, each stamped with its own byte value.
        var audio = Data()
        for block in 0..<3 { audio.append(Data(repeating: UInt8(block), count: 4_800)) }
        backend.sendAudio(VoiceAudioChunk(data: audio,
                                          format: OpenAIRealtimeVoiceBackend.audioFormat,
                                          timestamp: 0))
        await settle()

        XCTAssertEqual(server.appendedAudio.map { $0.first }, [0, 1, 2],
                       "a reordered append is scrambled audio in the transcript")
    }

    func testASecondTurnRunsOnTheSameSession() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        backend.sendAudio(pcm16(240))
        backend.endUserTurn(expectingResponse: true)
        server.push(RealtimeFrame.responseDone)
        await settle()

        backend.beginUserTurn()
        backend.sendAudio(pcm16(240))
        backend.endUserTurn(expectingResponse: true)
        await settle()

        XCTAssertEqual(server.sentTypes,
                       ["session.update",
                        "input_audio_buffer.append",
                        "input_audio_buffer.commit", "response.create",
                        "input_audio_buffer.append",
                        "input_audio_buffer.commit", "response.create"])
        XCTAssertEqual(events.failures, [], "one session serves many windows")
    }

    func testBeginningATurnTwiceIsAProtocolViolation() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        backend.beginUserTurn()
        await settle()

        guard case .protocolViolation? = events.failures.first else {
            return XCTFail("expected a protocol violation, got \(events.events)")
        }
    }

    func testAudioAfterTheCommitIsRejected() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        backend.endUserTurn(expectingResponse: true)
        await settle()

        backend.sendAudio(pcm16(240))
        await settle()

        XCTAssertEqual(server.appendedAudio, [],
                       "audio after the commit belongs to a turn that is already gone")
        guard case .protocolViolation? = events.failures.first else {
            return XCTFail("expected a protocol violation, got \(events.events)")
        }
    }

    func testAudioBeforeATurnIsAProtocolViolation() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await backend.open { events.append($0) }

        backend.sendAudio(pcm16(240))
        await settle()

        XCTAssertEqual(server.sentTypes, ["session.update"], "no audio reaches an unopened turn")
        guard case .protocolViolation? = events.failures.first else {
            return XCTFail("expected a protocol violation, got \(events.events)")
        }
    }

    func testAudioInTheWrongFormatIsRejectedLoudly() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        backend.sendAudio(VoiceAudioChunk(data: Data(repeating: 1, count: 320),
                                          format: .pcm16Mono16k, timestamp: 0))
        await settle()

        guard case .protocolViolation(let detail)? = events.failures.first else {
            return XCTFail("expected a protocol violation, got \(events.events)")
        }
        XCTAssertTrue(detail.contains("16000"), detail)
        XCTAssertEqual(server.appendedAudio, [], "mis-encoded audio transcribes as noise")
    }

    func testEndingATurnThatNeverBeganIsAProtocolViolation() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await backend.open { events.append($0) }

        backend.endUserTurn(expectingResponse: true)
        await settle()

        XCTAssertFalse(server.sentTypes.contains("input_audio_buffer.commit"))
        guard case .protocolViolation? = events.failures.first else {
            return XCTFail("expected a protocol violation, got \(events.events)")
        }
    }

    func testTheServerNeverEndsATurn() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        backend.sendAudio(pcm16(240))
        await settle()

        // Everything a chatty service can say mid-turn. None of it may commit the buffer.
        server.push(sequence: [RealtimeFrame.transcriptDelta("yes"),
                               RealtimeFrame.transcriptCompleted("yes"),
                               RealtimeFrame.unknownEvent,
                               #"{"type":"input_audio_buffer.speech_stopped"}"#])
        await settle()

        XCTAssertEqual(server.sentTypes, ["session.update", "input_audio_buffer.append"],
                       "only TapQ commits")
        XCTAssertEqual(backend.turnStateForTesting, .userTurn)
        XCTAssertEqual(events.failures, [])
    }

    func testAnUnrequestedResponseCompletionEndsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.push(RealtimeFrame.responseDone)
        await settle()

        guard case .protocolViolation(let detail)? = events.failures.first else {
            return XCTFail("expected a protocol violation, got \(events.events)")
        }
        XCTAssertTrue(detail.contains("never requested"), detail)
    }

    // MARK: - Event mapping

    func testTranscriptDeltasAccumulateIntoCumulativePartials() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.push(sequence: [RealtimeFrame.transcriptDelta("yes"),
                               RealtimeFrame.transcriptDelta(" go"),
                               RealtimeFrame.transcriptDelta(" ahead")])
        await settle()

        XCTAssertEqual(events.transcripts, ["yes", "yes go", "yes go ahead"],
                       "matchers see the whole utterance each time, exactly as with Apple's")
    }

    func testTranscriptCompletionEmitsAFinalTranscript() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.push(sequence: [RealtimeFrame.transcriptDelta("yes go"),
                               RealtimeFrame.transcriptCompleted("yes, go ahead")])
        await settle()

        XCTAssertEqual(events.events.last, .transcriptFinal("yes, go ahead"))
    }

    func testAnEmptyCompletionKeepsTheAccumulatedTranscript() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.push(sequence: [RealtimeFrame.transcriptDelta("yes"),
                               RealtimeFrame.transcriptCompleted("")])
        await settle()

        XCTAssertEqual(events.events.last, .transcriptFinal("yes"))
    }

    func testANewTurnStartsFromAnEmptyTranscript() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        server.push(RealtimeFrame.transcriptDelta("yes"))
        await settle()
        backend.endUserTurn(expectingResponse: true)
        server.push(RealtimeFrame.responseDone)
        await settle()

        backend.beginUserTurn()
        server.push(RealtimeFrame.transcriptDelta("no"))
        await settle()

        XCTAssertEqual(events.transcripts, ["yes", "no"],
                       "one turn's words must not bleed into the next")
    }

    func testResponseAudioIsMappedWithTheSessionFormatAndClock() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        backend.endUserTurn(expectingResponse: true)
        await settle()

        let audio = Data(repeating: 0x33, count: 480)
        server.push(RealtimeFrame.audioDelta(audio))
        await settle()

        XCTAssertEqual(events.events.last,
                       .audio(VoiceAudioChunk(data: audio,
                                              format: OpenAIRealtimeVoiceBackend.audioFormat,
                                              timestamp: Self.now)))
    }

    func testResponseCompletionReturnsTheSessionToIdleAndIsForwarded() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        backend.endUserTurn(expectingResponse: true)
        await settle()

        server.push(RealtimeFrame.responseDone)
        await settle()

        XCTAssertEqual(events.events.last, .responseCompleted)
        XCTAssertEqual(backend.turnStateForTesting, .open)
    }

    func testUnknownServerEventsAreIgnoredNotFatal() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.push(sequence: [RealtimeFrame.unknownEvent, RealtimeFrame.transcriptDelta("yes")])
        await settle()

        XCTAssertEqual(events.transcripts, ["yes"])
        XCTAssertEqual(sink.events.last { $0.name == "event.ignored" }?.fields["type"],
                       "rate_limits.updated")
    }

    func testAMalformedFrameEndsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.push("{ this is not json")
        await settle()

        guard case .protocolViolation? = events.failures.first else {
            return XCTFail("expected a protocol violation, got \(events.events)")
        }
    }

    // MARK: - Responses and barge-in

    func testRequestResponseCarriesTheText() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await backend.open { events.append($0) }

        backend.requestResponse(text: "the build finished")
        await settle()

        XCTAssertEqual(server.sentTypes, ["session.update", "response.create"])
        XCTAssertEqual(server.instructions(ofResponseAt: 0), "the build finished")
    }

    func testRequestResponseDuringAUserTurnIsRejected() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        backend.requestResponse(text: "talking over the wearer")
        await settle()

        XCTAssertFalse(server.sentTypes.contains("response.create"),
                       "half-duplex is TapQ policy even against a duplex transport")
        guard case .protocolViolation(let detail)? = events.failures.first else {
            return XCTFail("expected a protocol violation, got \(events.events)")
        }
        XCTAssertTrue(detail.contains("half-duplex"), detail)
    }

    func testCancelResponseSendsAResponseCancel() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        backend.sendAudio(pcm16(240))
        backend.endUserTurn(expectingResponse: true)
        await settle()

        backend.cancelResponse()
        await settle()

        XCTAssertEqual(server.sentTypes.last, "response.cancel")
        XCTAssertEqual(backend.turnStateForTesting, .open)
        XCTAssertEqual(events.failures, [],
                       "the cancel ack (response.done cancelled) must not fail the session")
        // The scripted server now models the documented cancel semantics: a response.cancel
        // is acked with response.done (cancelled). The adapter must emit responseCompleted
        // so the provider clears any response-in-flight tracking.
        XCTAssertTrue(events.events.contains(.responseCompleted),
                      "the cancel ack must be forwarded as responseCompleted")
        XCTAssertTrue(sink.names.contains("cancel_ack.received"))
    }

    func testCancelAckDoesNotFailSessionAndEmitsResponseCompleted() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        backend.sendAudio(pcm16(240))
        backend.endUserTurn(expectingResponse: true)
        await settle()

        // Straggler audio before the cancel ack.
        let audio = Data(repeating: 0x42, count: 480)
        server.push(RealtimeFrame.audioDelta(audio))
        await settle()

        backend.cancelResponse()
        await settle()

        // The scripted server acks with response.done (cancelled). The adapter handles it
        // via expectCancelAck rather than calling turns.responseCompleted() from .open.
        XCTAssertEqual(backend.turnStateForTesting, .open)
        XCTAssertEqual(events.failures, [],
                       "the cancel ack must not fail the session")
        XCTAssertTrue(events.events.contains(.responseCompleted),
                      "responseCompleted must be emitted so the provider clears tracking state")
        // The next turn must work.
        backend.beginUserTurn()
        XCTAssertEqual(backend.turnStateForTesting, .userTurn)
    }

    func testCancelRacingCompletedResponseTreatsErrorAsBenign() async throws {
        let server = ScriptedRealtimeServer()
        // Disable the auto-ack: simulate the server returning only an error for the cancel
        // because the response had already completed when the cancel arrived.
        server.acknowledgesCancelWithDone = false
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        backend.sendAudio(pcm16(240))
        backend.endUserTurn(expectingResponse: true)
        await settle()

        backend.cancelResponse()
        await settle()

        // The cancel was sent; now the server returns an error instead of response.done.
        server.push(RealtimeFrame.error(message: "response already completed",
                                         code: "cancel_failed"))
        await settle()

        XCTAssertEqual(events.failures, [],
                       "an error from a cancel race must not fail the session")
        XCTAssertEqual(backend.turnStateForTesting, .open)
        XCTAssertTrue(sink.names.contains("cancel_ack.race_error"))
    }

    func testCancelWithNothingInFlightIsRejected() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await backend.open { events.append($0) }

        backend.cancelResponse()
        await settle()

        XCTAssertFalse(server.sentTypes.contains("response.cancel"))
        guard case .protocolViolation? = events.failures.first else {
            return XCTFail("expected a protocol violation, got \(events.events)")
        }
    }

    func testCapabilitiesDescribeTheTransportNotThePolicy() async {
        let backend = makeBackend(ScriptedRealtimeServer())
        XCTAssertEqual(backend.capabilities,
                       VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                duplex: true))
    }

    // MARK: - Failure paths

    func testAnErrorEventEndsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.push(RealtimeFrame.error(message: "session expired", code: "server_error"))
        await settle()

        XCTAssertEqual(events.failures, [.protocolViolation("session expired")])
        XCTAssertEqual(server.closeCount, 1)
    }

    func testAnAuthorizationErrorIsTypedAsSuch() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.push(RealtimeFrame.error(message: "bad key", code: "invalid_api_key"))
        await settle()

        XCTAssertEqual(events.failures, [.authorization("bad key")],
                       "reconnecting against a rejected key is a loop, not a recovery")
    }

    func testAMidStreamDisconnectSurfacesAsSessionFailed() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.disconnect()
        await settle()

        guard case .network(let detail)? = events.failures.first else {
            return XCTFail("expected a network failure, got \(events.events)")
        }
        XCTAssertTrue(detail.contains("socket dropped"), detail)
    }

    func testACleanHangUpSurfacesAsAClosedSession() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.hangUp()
        await settle()

        guard case .closed? = events.failures.first else {
            return XCTFail("expected a closed failure, got \(events.events)")
        }
    }

    func testASendFailureEndsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.sendFailure = .sendFailed("broken pipe")
        backend.sendAudio(pcm16(240))
        await settle()

        guard case .network(let detail)? = events.failures.first else {
            return XCTFail("expected a network failure, got \(events.events)")
        }
        XCTAssertTrue(detail.contains("broken pipe"), detail)
    }

    func testNoEventsArriveAfterAFailure() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.disconnect()
        await settle()
        let afterFailure = events.events.count
        server.push(RealtimeFrame.transcriptDelta("too late"))
        await settle()

        XCTAssertEqual(events.events.count, afterFailure,
                       "frames from a dead session resolve nothing")
    }

    // MARK: - Teardown

    func testCloseIsIdempotentAndSilencesTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        backend.close()
        backend.close()
        backend.close()
        server.push(RealtimeFrame.transcriptDelta("after close"))
        await settle()

        XCTAssertEqual(events.events, [])
        XCTAssertEqual(backend.turnStateForTesting, .idle)
        XCTAssertGreaterThanOrEqual(server.closeCount, 1)
    }

    func testCloseDuringTheConnectHandshakeLeavesNothingRunning() async {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let gate = AsyncGate()
        server.connectGate = { await gate.wait() }

        let opening = Task { @MainActor in
            try await backend.open { _ in XCTFail("the window was abandoned") }
        }
        await settle()
        backend.close()
        gate.open()

        do {
            try await opening.value
            XCTFail("a torn-down session cannot finish opening")
        } catch {
            guard case .closed? = error as? VoiceBackendFailure else {
                return XCTFail("expected a closed failure, got \(error)")
            }
        }
        await settle()

        XCTAssertEqual(server.sentTypes, [], "nothing is configured on an abandoned session")
        XCTAssertFalse(server.isConnected, "a connection nobody wanted must not be left up")
    }

    func testCloseWithoutOpenIsHarmless() async {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)

        backend.close()
        backend.close()

        XCTAssertEqual(backend.turnStateForTesting, .idle)
        XCTAssertEqual(server.sentTypes, [])
    }

    func testALateAckAfterATimedOutHandshakeChangesNothing() async {
        let server = ScriptedRealtimeServer()
        server.acknowledgesSessionUpdate = false
        let backend = makeBackend(server, timeout: 0.05)
        try? await backend.open { _ in XCTFail("the handshake never completed") }

        server.push(RealtimeFrame.sessionUpdated)
        await settle()

        XCTAssertEqual(backend.turnStateForTesting, .idle,
                       "an ack for a session that gave up must not revive it")
        XCTAssertEqual(server.closeCount, 1)
    }

    func testAFullSessionCanBeReopenedAfterClose() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        backend.close()

        let second = EventLog()
        try await openTurn(backend, collecting: second)
        server.push(RealtimeFrame.transcriptDelta("yes"))
        await settle()

        XCTAssertEqual(second.transcripts, ["yes"])
        XCTAssertEqual(events.events, [], "the first window stays closed")
    }

    // MARK: - Empty-turn guard

    func testEmptyTurnSendsNeitherCommitNorResponseCreate() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        // End the turn without sending any audio.
        backend.endUserTurn(expectingResponse: true)
        await settle()

        XCTAssertFalse(server.sentTypes.contains("input_audio_buffer.commit"),
                       "an empty turn must not commit")
        XCTAssertFalse(server.sentTypes.contains("response.create"),
                       "an empty turn must not request a response")
        XCTAssertEqual(server.sentTypes, ["session.update"],
                       "only the handshake frame was sent")
        XCTAssertTrue(sink.names.contains("turn.empty_skipped"))
    }

    func testNormalTurnWithAudioIsUnchangedByEmptyGuard() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        backend.sendAudio(pcm16(240))
        backend.endUserTurn(expectingResponse: true)
        await settle()

        XCTAssertEqual(server.sentTypes, ["session.update", "input_audio_buffer.append",
                                          "input_audio_buffer.commit", "response.create"],
                       "a turn with audio commits and requests normally")
    }

    func testEmptyTurnFollowedByNormalTurnWorks() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        // First turn: empty
        backend.endUserTurn(expectingResponse: true)
        server.push(RealtimeFrame.responseDone)
        await settle()

        // Second turn: with audio
        backend.beginUserTurn()
        backend.sendAudio(pcm16(240))
        backend.endUserTurn(expectingResponse: true)
        await settle()

        XCTAssertTrue(server.sentTypes.contains("input_audio_buffer.commit"))
        XCTAssertTrue(server.sentTypes.contains("response.create"))
        XCTAssertEqual(events.failures, [], "the empty turn must not corrupt later turns")
    }

    // MARK: - Degraded turn detection

    private func turnDetection(_ server: ScriptedRealtimeServer,
                               ofUpdate index: Int) -> [String: Any]? {
        let updates = server.sent.filter { $0["type"] as? String == "session.update" }
        guard index < updates.count else { return nil }
        return (updates[index]["session"] as? [String: Any])?["turn_detection"] as? [String: Any]
    }

    /// The degraded mode is a *second* `session.update`, never a different handshake.
    ///
    /// `ScriptedRealtimeServer` fails the test if the first frame on a connection carries
    /// anything but `turn_detection: none`, and that is deliberate: there must be no instant
    /// in a session's life during which the service is running turn detection TapQ has not
    /// deliberately switched on. A caller asking before `open` gets it after the ack, not
    /// folded into it.
    func testNativeTurnDetectionIsAppliedAfterTheManualHandshake() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()

        backend.setNativeTurnDetection(true)
        try await backend.open { events.append($0) }
        await settle()

        XCTAssertEqual(turnDetection(server, ofUpdate: 0)?["type"] as? String, "none")
        XCTAssertEqual(turnDetection(server, ofUpdate: 1)?["type"] as? String, "server_vad")
        XCTAssertEqual(turnDetection(server, ofUpdate: 1)?["create_response"] as? Bool, false)
        XCTAssertEqual(events.failures, [])
    }

    /// The switch is idempotent and only ever sends a frame when something really changed —
    /// the provider calls it at every window open, and most windows do not change the answer.
    func testRepeatingTheSameModeSendsNothing() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await backend.open { events.append($0) }
        await settle()
        let baseline = server.sentTypes.filter { $0 == "session.update" }.count

        backend.setNativeTurnDetection(false)
        backend.setNativeTurnDetection(false)
        await settle()
        XCTAssertEqual(server.sentTypes.filter { $0 == "session.update" }.count, baseline,
                       "already-manual is already-manual")

        backend.setNativeTurnDetection(true)
        backend.setNativeTurnDetection(true)
        await settle()
        XCTAssertEqual(server.sentTypes.filter { $0 == "session.update" }.count, baseline + 1)

        backend.setNativeTurnDetection(false)
        await settle()
        XCTAssertEqual(turnDetection(server, ofUpdate: baseline)?["type"] as? String, "server_vad")
        XCTAssertEqual(turnDetection(server, ofUpdate: baseline + 1)?["type"] as? String, "none",
                       "and the way back is the same frame it always was")
    }

    /// The whole degraded flow as the service produces it, and the property the whole design
    /// turns on: the commit ends an utterance, not TapQ's turn.
    func testAServerVADCommitReportsTheUtteranceAndLeavesTheTurnOpen() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        backend.setNativeTurnDetection(true)
        try await openTurn(backend, collecting: events)

        backend.sendAudio(pcm16(2_400))
        await settle()
        server.push(#"{"type":"input_audio_buffer.speech_started"}"#)
        server.push(#"{"type":"input_audio_buffer.speech_stopped"}"#)
        server.push(#"{"type":"input_audio_buffer.committed","item_id":"item_1"}"#)
        await settle()

        XCTAssertEqual(events.events, [.userAudioCommittedByBackend])
        XCTAssertEqual(backend.turnStateForTesting, .userTurn,
                       "a native commit must never end TapQ's turn")
        XCTAssertFalse(server.sentTypes.contains("input_audio_buffer.commit"),
                       "TapQ does not commit when the service is doing it")
        XCTAssertFalse(server.sentTypes.contains("response.create"),
                       "and the service was told never to answer")

        // The turn is genuinely still usable: the wearer kept talking.
        backend.sendAudio(pcm16(2_400))
        server.push(#"{"type":"input_audio_buffer.committed","item_id":"item_2"}"#)
        server.push(RealtimeFrame.transcriptCompleted("yes"))
        await settle()

        XCTAssertEqual(events.failures, [], "audio after a native commit is still legal")
        XCTAssertEqual(events.events.last, .transcriptFinal("yes"))
        XCTAssertTrue(sink.names.contains("native_turn.speech_started"))
        XCTAssertTrue(sink.names.contains("native_turn.committed"))
    }

    /// Each committed segment is a whole utterance to the grammar above, so the transcript
    /// starts over rather than accreting two half-heard sentences into one.
    func testEachServerVADSegmentTranscribesOnItsOwn() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        backend.setNativeTurnDetection(true)
        try await openTurn(backend, collecting: events)
        backend.sendAudio(pcm16(2_400))
        await settle()

        server.push(#"{"type":"input_audio_buffer.committed","item_id":"item_1"}"#)
        server.push(RealtimeFrame.transcriptDelta("show me the "))
        server.push(RealtimeFrame.transcriptDelta("details"))
        await settle()
        XCTAssertEqual(events.events.last, .transcriptPartial("show me the details"))

        server.push(#"{"type":"input_audio_buffer.committed","item_id":"item_2"}"#)
        server.push(RealtimeFrame.transcriptDelta("yes"))
        await settle()
        XCTAssertEqual(events.events.last, .transcriptPartial("yes"),
                       "the second segment is its own utterance")
    }

    /// The other half of the asymmetry: with the mode off, the same frame kills the session.
    func testAnUnsolicitedServerCommitFailsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        backend.sendAudio(pcm16(2_400))
        await settle()

        server.push(#"{"type":"input_audio_buffer.committed","item_id":"item_1"}"#)
        await settle()

        guard case .protocolViolation(let detail) = try XCTUnwrap(events.failures.first) else {
            return XCTFail("expected a protocol violation, got \(events.failures)")
        }
        XCTAssertTrue(detail.contains("committed the input buffer"), detail)
        XCTAssertEqual(backend.turnStateForTesting, .idle)
    }

    /// TapQ's own commit comes back as the same event type. Mistaking the echo for a
    /// server-initiated commit would fail every manual-mode turn in the field.
    func testTheEchoOfTapQsOwnCommitIsNotMistakenForTheServices() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        backend.sendAudio(pcm16(2_400))
        backend.endUserTurn(expectingResponse: false)
        await settle()
        server.push(#"{"type":"input_audio_buffer.committed","item_id":"item_1"}"#)
        await settle()

        XCTAssertEqual(events.events, [], "an ack is not an event")
        XCTAssertEqual(events.failures, [])
        XCTAssertEqual(backend.turnStateForTesting, .committed)
    }

    /// Window teardown in the degraded mode discards the residue rather than committing it.
    ///
    /// Both halves matter. The service rejects a commit holding less than 100 ms, and a
    /// rejected commit is an `error` frame that ends the session; and the input buffer
    /// outlives the window, so a fragment left in it would be transcribed as the opening of
    /// a sentence spoken in some later window.
    func testANativeTurnEndClearsTheBufferInsteadOfCommittingIt() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        backend.setNativeTurnDetection(true)
        try await openTurn(backend, collecting: events)

        backend.sendAudio(pcm16(240))
        XCTAssertFalse(backend.endUserTurn(expectingResponse: true),
                       "a native turn end never creates a response")
        await settle()

        XCTAssertTrue(server.sentTypes.contains("input_audio_buffer.clear"))
        XCTAssertFalse(server.sentTypes.contains("input_audio_buffer.commit"))
        XCTAssertFalse(server.sentTypes.contains("response.create"))
        XCTAssertTrue(sink.names.contains("turn.ended_native"))
        XCTAssertEqual(events.failures, [])
    }

    /// A turn that carried no audio still skips the clear: the empty-turn guard runs first,
    /// and a frame about an empty buffer is a frame nobody needs.
    func testAnEmptyNativeTurnSendsNothingAtAll() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        backend.setNativeTurnDetection(true)
        try await openTurn(backend, collecting: events)

        backend.endUserTurn(expectingResponse: false)
        await settle()

        XCTAssertFalse(server.sentTypes.contains("input_audio_buffer.clear"))
        XCTAssertFalse(server.sentTypes.contains("input_audio_buffer.commit"))
    }

    /// A reconnect comes back up in the mode the caller is still expecting. Anything else
    /// would let a socket drop silently hand turn arbitration back to a wearer who has no
    /// AirPods to arbitrate with.
    func testTheRequestedModeSurvivesAReconnect() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        backend.setNativeTurnDetection(true)
        try await backend.open { _ in }
        await settle()
        backend.close()

        let reopened = EventLog()
        try await backend.open { reopened.append($0) }
        await settle()

        let updates = server.sent.filter { $0["type"] as? String == "session.update" }
        XCTAssertEqual(updates.count, 4, "two sessions, two frames each")
        XCTAssertEqual(turnDetection(server, ofUpdate: 2)?["type"] as? String, "none",
                       "the reconnect handshakes manual, like every other handshake")
        XCTAssertEqual(turnDetection(server, ofUpdate: 3)?["type"] as? String, "server_vad",
                       "and is then put back into the mode the caller asked for")
    }
}
