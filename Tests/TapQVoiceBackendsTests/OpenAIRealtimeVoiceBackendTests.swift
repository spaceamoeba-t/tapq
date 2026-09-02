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

    /// `turnEagerness` is stated rather than defaulted, deliberately: the shipped default
    /// reads `TAPQ_TURN_EAGERNESS` from the process environment, and a suite whose wire
    /// assertions depended on the machine running it would pass or fail for reasons that
    /// have nothing to do with the adapter.
    private func makeBackend(_ server: ScriptedRealtimeServer,
                             timeout: TimeInterval = 1,
                             turnEagerness: RealtimeTurnEagerness = .low,
                             sink: RecordingSink = RecordingSink())
        -> OpenAIRealtimeVoiceBackend {
        OpenAIRealtimeVoiceBackend(transport: server,
                                   timeout: timeout,
                                   turnEagerness: turnEagerness,
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
        let input = ScriptedRealtimeServer.inputAudio(of: server.sessionConfiguration)
        XCTAssertTrue(input?["turn_detection"] is NSNull)
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

        let input = ScriptedRealtimeServer.inputAudio(of: server.sessionConfiguration)
        XCTAssertTrue(input?["turn_detection"] is NSNull,
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

    /// The service's own speech, reported settled and passed straight on. The host records
    /// it; nothing here routes on it, which is the difference between this and the two above.
    func testTheServicesOwnSpokenTranscriptIsPassedOn() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.push(sequence: [
            RealtimeFrame.spokenTranscript("Windsurf is an AI coding editor."),
        ])
        await settle()

        XCTAssertEqual(events.events.last,
                       .spokenByBackend("Windsurf is an AI coding editor."))
    }

    /// It must not join the wearer's turn. `transcript` accumulates the wearer's deltas and
    /// is what the matchers see; TapQ's own words landing in it would be TapQ answering its
    /// own window.
    func testTheServicesOwnSpokenTranscriptDoesNotJoinTheWearersTurn() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        server.push(sequence: [RealtimeFrame.transcriptDelta("yes"),
                               RealtimeFrame.spokenTranscript("I've told Claude Code: rerun."),
                               RealtimeFrame.transcriptCompleted("yes, go ahead")])
        await settle()

        XCTAssertEqual(events.transcripts, ["yes", "yes, go ahead"],
                       "the wearer's turn is untouched by what TapQ said in the middle of it")
    }

    /// An empty one is dropped rather than emitted: a host recording "" would file a
    /// sentence nobody said.
    func testAnEmptySpokenTranscriptIsNotEmitted() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        let before = events.events.count

        server.push(sequence: [RealtimeFrame.spokenTranscript("")])
        await settle()

        XCTAssertEqual(events.events.count, before, "\(events.events)")
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

    /// A sentence TapQ wrote goes out as an out-of-band response carrying the text.
    ///
    /// The wire shape itself is `RealtimeMessagesTests`' subject; what this asserts is that
    /// the adapter reaches for that shape rather than the grounded-answer one, which is the
    /// difference between "read this to the wearer" and "reply to the conversation".
    func testScriptedSpeechGoesOutOfBandWithTheSentence() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await backend.open { events.append($0) }

        backend.requestScriptedSpeech(text: "Queued for Codex.")
        await settle()

        XCTAssertEqual(server.sentTypes, ["session.update", "response.create"])
        let response = try XCTUnwrap(server.responseObject(at: 0))
        XCTAssertEqual(response["conversation"] as? String, "none")
        XCTAssertTrue((response["instructions"] as? String)?
            .contains("Queued for Codex.") ?? false)
        XCTAssertTrue(sink.names.contains("scripted_speech.requested"))
        XCTAssertFalse(sink.names.contains("response.requested"),
                       "a scripted reading is not a grounded answer")
    }

    /// Half-duplex is not relaxed for TapQ's own sentences. A scripted line while the
    /// wearer's turn is open would be TapQ talking into its own microphone, which is the
    /// exact failure voice-output isolation exists to end.
    func testScriptedSpeechDuringAUserTurnIsRejected() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server)
        let events = EventLog()
        try await openTurn(backend, collecting: events)

        backend.requestScriptedSpeech(text: "Listening.")
        await settle()

        XCTAssertFalse(server.sentTypes.contains("response.create"))
        guard case .protocolViolation? = events.failures.first else {
            return XCTFail("expected a protocol violation, got \(events.events)")
        }
    }

    /// A scripted response is a response: it is named, cancellable, and its cancelled tail
    /// is drained against the same tombstone every other response uses. Without this the
    /// prompt a barge-in interrupts would come back as "a response TapQ never requested"
    /// and kill the session.
    func testScriptedSpeechIsCancellableAndTombstonedLikeAnyResponse() async throws {
        let server = ScriptedRealtimeServer()
        // The tail arrives on the peer's own schedule, not on the cancel's heels.
        server.acknowledgesCancelWithDone = false
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await backend.open { events.append($0) }

        backend.requestScriptedSpeech(text: "Claude Code wants to run the tests.")
        await settle()
        server.push(RealtimeFrame.audioDelta(Data(repeating: 0x21, count: 480)))
        await settle()

        // The wearer starts talking over the prompt, and the window it belongs to opens.
        backend.cancelResponse()
        backend.beginUserTurn()
        await settle()
        XCTAssertEqual(backend.cancelledResponseIDsForTesting, ["resp_1"],
                       "a scripted reading is tombstoned like any other response")

        // The peer still owes the frames it had already produced, then this response's own
        // terminal frame. Drained, never fatal.
        server.push(sequence: RealtimeFrame.cancelledResponseTail(id: "resp_1"))
        server.push(RealtimeFrame.responseDoneCancelled(id: "resp_1"))
        await settle()

        XCTAssertEqual(events.failures, [],
                       "a cancelled scripted reading must not end the session")
        XCTAssertTrue(sink.names.contains("response.cancelled_done_drained"))
        XCTAssertEqual(backend.turnStateForTesting, .userTurn,
                       "the listening window the cancel opened is untouched")
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
        // The peer named the response, so the ack is drained against its tombstone rather
        // than against "the next done that happens to arrive".
        XCTAssertTrue(sink.names.contains("response.cancelled_done_drained"))
        XCTAssertEqual(backend.cancelledResponseIDsForTesting, [],
                       "the done the peer owed retires the tombstone")
    }

    /// A peer that names nothing still gets its cancel acked: with no id to tombstone, the
    /// next terminal frame is the ack, which is the bookkeeping this adapter has always had.
    func testCancelAckIsAbsorbedForAPeerThatNamesNoResponses() async throws {
        let server = ScriptedRealtimeServer()
        server.namesResponses = false
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await openTurn(backend, collecting: events)
        backend.sendAudio(pcm16(240))
        backend.endUserTurn(expectingResponse: true)
        await settle()

        backend.cancelResponse()
        await settle()

        XCTAssertEqual(events.failures, [])
        XCTAssertTrue(sink.names.contains("cancel_ack.received"))
        XCTAssertTrue(events.events.contains(.responseCompleted))
        XCTAssertEqual(backend.turnStateForTesting, .open)
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

    // Superseded by `testCancellingWithNothingInFlightIsRecordedAndSendsNothing` under
    // "Cancel idempotence" below: a cancel with nothing in flight used to be reported as a
    // protocol violation, which is a dead session under the no-degradation policy for a
    // caller doing nothing worse than repeating itself. It is a recorded no-op now. What
    // that test kept from this one is the half that never changed: no frame goes out.

    // MARK: - Cancelled-response tombstones

    /// The live failure this bookkeeping exists for (2026-08-27, `--voice-session`).
    ///
    /// TapQ speaks a turn-end notice through the backend voice; the agent's Stop opens the
    /// first listening window in the same breath, and the window cancels the still-streaming
    /// response. The peer then delivers the rest of that response — its constituent `*.done`
    /// frames, and finally its own `response.done` — into a session that has already begun a
    /// new user turn. Forgetting the response at the cancel made that done a completion TapQ
    /// never requested, which ended the session and degraded the run to Apple for good, with
    /// no user input involved anywhere.
    func testACancelledResponsesTailDoesNotEndTheSession() async throws {
        let server = ScriptedRealtimeServer()
        // The tail arrives on the peer's own schedule, not on the cancel's heels.
        server.acknowledgesCancelWithDone = false
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await backend.open { events.append($0) }

        backend.requestResponse(text: "Claude Code finished.")
        await settle()
        server.push(RealtimeFrame.audioDelta(Data(repeating: 0x21, count: 480)))
        await settle()

        // The window opens: cancel the notice, then begin the wearer's turn immediately.
        backend.cancelResponse()
        backend.beginUserTurn()
        await settle()
        XCTAssertEqual(backend.cancelledResponseIDsForTesting, ["resp_1"],
                       "a cancel remembers the response rather than forgetting it")

        server.push(sequence: RealtimeFrame.cancelledResponseTail(id: "resp_1"))
        server.push(RealtimeFrame.responseDoneCancelled(id: "resp_1"))
        await settle()

        XCTAssertEqual(events.failures, [], "the tail of a cancelled response is expected")
        XCTAssertEqual(backend.turnStateForTesting, .userTurn,
                       "the listening window the cancel opened is untouched")
        XCTAssertTrue(sink.names.contains("response.cancelled_done_drained"))
        XCTAssertEqual(backend.cancelledResponseIDsForTesting, [],
                       "the done the peer owed retires the tombstone")

        // And the window still works: the turn it opened ends normally.
        backend.sendAudio(pcm16(240))
        XCTAssertTrue(backend.endUserTurn(expectingResponse: true))
    }

    /// The strict check is not relaxed into "ignore every done nobody claims": a completion
    /// for a response that is neither in flight nor tombstoned still ends the session, which
    /// is the whole of what the manual-turn contract buys.
    func testAResponseDoneForAnUnknownResponseIsStillAProtocolError() async throws {
        let server = ScriptedRealtimeServer()
        server.acknowledgesCancelWithDone = false
        let backend = makeBackend(server)
        let events = EventLog()
        try await backend.open { events.append($0) }

        backend.requestResponse(text: "Claude Code finished.")
        await settle()
        backend.cancelResponse()
        backend.beginUserTurn()
        await settle()

        server.push(RealtimeFrame.responseDone(id: "resp_9"))
        await settle()

        guard case .protocolViolation(let detail)? = events.failures.first else {
            return XCTFail("expected a protocol violation, got \(events.events)")
        }
        XCTAssertTrue(detail.contains("never requested"), detail)
        XCTAssertEqual(backend.cancelledResponseIDsForTesting, [],
                       "the session died; its bookkeeping went with it")
    }

    /// The suppression path cancels from inside the first `.audio` callback — a response the
    /// caller decided it no longer wants the moment it started arriving. That cancel is a
    /// cancel like any other: the response is tombstoned, not forgotten, so the done it still
    /// owes lands on a live session.
    func testASuppressedResponseCancelledOnFirstAudioIsTombstoned() async throws {
        let server = ScriptedRealtimeServer()
        server.acknowledgesCancelWithDone = false
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await backend.open { event in
            events.append(event)
            // What `response.suppressed_on_first_audio` does one level up. The state check
            // stands in for the provider's suppression mark: only the first chunk cancels.
            if case .audio = event, backend.turnStateForTesting == .responding {
                backend.cancelResponse()
            }
        }

        backend.requestResponse(text: "an answer nobody is waiting for any more")
        await settle()
        server.push(RealtimeFrame.audioDelta(Data(repeating: 0x42, count: 480)))
        await settle()

        XCTAssertEqual(backend.cancelledResponseIDsForTesting, ["resp_1"])
        XCTAssertEqual(server.sentTypes.last, "response.cancel")

        // The window that suppressed it opens, and only then does the peer finish.
        backend.beginUserTurn()
        server.push(sequence: RealtimeFrame.cancelledResponseTail(id: "resp_1"))
        server.push(RealtimeFrame.responseDoneCancelled(id: "resp_1"))
        await settle()

        XCTAssertEqual(events.failures, [])
        XCTAssertEqual(backend.turnStateForTesting, .userTurn)
        XCTAssertTrue(sink.names.contains("response.cancelled_done_drained"))
    }

    /// A peer that owes a `response.done` and never sends it must not grow the record
    /// forever, and the record does not outlive the peer that issued the ids.
    func testTombstonesAreBoundedAndEndWithTheSession() async throws {
        let server = ScriptedRealtimeServer()
        server.acknowledgesCancelWithDone = false
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await backend.open { events.append($0) }

        for _ in 0..<(OpenAIRealtimeVoiceBackend.maxCancelledResponses + 1) {
            backend.requestResponse(text: "a sentence")
            await settle()
            backend.cancelResponse()
            await settle()
        }

        XCTAssertEqual(backend.cancelledResponseIDsForTesting,
                       ["resp_2", "resp_3", "resp_4", "resp_5"],
                       "the ring keeps the newest cancels and drops the oldest")
        XCTAssertTrue(sink.names.contains("response.cancelled_tombstone_dropped"))
        XCTAssertEqual(events.failures, [])

        backend.close()
        try await backend.open { events.append($0) }
        XCTAssertEqual(backend.cancelledResponseIDsForTesting, [],
                       "ids belong to the peer that issued them")
    }

    // MARK: - Cancel idempotence

    /// The live sequence that took hands-free voice down (2026-08-27, `--voice-session`,
    /// `--voice-freeform`), replayed frame for frame.
    ///
    /// A dictation read-back is speaking. The suppression path cancels it because the window
    /// it belonged to has just resolved. The peer keeps streaming the tail it had already
    /// produced, which is what a cancel does *not* stop — and one of those straggler chunks
    /// re-arms the caller's response-in-flight tracking. The voice-session loop's next
    /// listening window comes due, sees a response in flight, and cancels a second time.
    /// That second cancel used to be `noResponseInFlight`, which under the no-degradation
    /// policy latched the break and killed voice for the rest of the run.
    func testASecondCancelOfAnAlreadyCancelledResponseIsANoOp() async throws {
        let server = ScriptedRealtimeServer()
        // The peer answers on its own schedule, as it did live: the tail is still coming
        // when the second cancel is issued.
        server.acknowledgesCancelWithDone = false
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await backend.open { events.append($0) }

        backend.requestResponse(text: "Instruction queued for Claude Code.")
        await settle()
        server.push(RealtimeFrame.audioDelta(Data(repeating: 0x31, count: 480)))
        await settle()

        // The suppression path: the window this response belonged to resolved.
        backend.cancelResponse()
        await settle()
        // Straggler audio, which is what re-armed the caller's tracking.
        server.push(RealtimeFrame.audioDelta(Data(repeating: 0x31, count: 480)))
        await settle()

        // The second cancel: the next listening window opening.
        backend.cancelResponse()
        await settle()

        XCTAssertEqual(events.failures, [],
                       "cancelling twice is TapQ repeating itself, not a protocol violation")
        XCTAssertTrue(sink.names.contains("response.cancel_skipped_idle"))
        XCTAssertFalse(sink.names.contains("session.failed"))
        XCTAssertEqual(server.sentTypes.filter { $0 == "response.cancel" }.count, 1,
                       "a cancel with nothing to cancel puts no frame on the wire")
        XCTAssertEqual(backend.cancelledResponseIDsForTesting, ["resp_1"],
                       "the skipped cancel leaves the first one's bookkeeping alone")

        // The session is still usable, and the tail still drains against the tombstone.
        backend.beginUserTurn()
        server.push(sequence: RealtimeFrame.cancelledResponseTail(id: "resp_1"))
        server.push(RealtimeFrame.responseDoneCancelled(id: "resp_1"))
        await settle()

        XCTAssertEqual(events.failures, [])
        XCTAssertEqual(backend.turnStateForTesting, .userTurn)
        XCTAssertTrue(sink.names.contains("response.cancelled_done_drained"))
        backend.sendAudio(pcm16(240))
        XCTAssertTrue(backend.endUserTurn(expectingResponse: true))
    }

    /// A cancel on a session that has never had a response is the same no-op, reached from
    /// the other side: nothing was cancelled, so nothing is remembered and nothing is sent.
    func testCancellingWithNothingInFlightIsRecordedAndSendsNothing() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await backend.open { events.append($0) }
        let framesBefore = server.sentTypes.count

        backend.cancelResponse()
        await settle()

        XCTAssertEqual(events.failures, [])
        XCTAssertTrue(sink.names.contains("response.cancel_skipped_idle"))
        XCTAssertEqual(server.sentTypes.count, framesBefore,
                       "no response.cancel for a peer that is not speaking")
        XCTAssertEqual(backend.turnStateForTesting, .open)
        XCTAssertEqual(backend.cancelledResponseIDsForTesting, [])
    }

    /// The skip must not spend the id-less cancel's bookkeeping either. Against a peer that
    /// names nothing there is no tombstone to protect the first cancel — the next terminal
    /// frame is its ack — so a second cancel that cleared `expectCancelAck` would hand that
    /// frame to the strict check and kill the session one event later.
    func testASecondCancelDoesNotConsumeAnUnnamedCancelsAck() async throws {
        let server = ScriptedRealtimeServer()
        server.namesResponses = false
        server.acknowledgesCancelWithDone = false
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        try await backend.open { events.append($0) }

        backend.requestResponse(text: "Claude Code finished.")
        await settle()
        backend.cancelResponse()
        await settle()
        backend.cancelResponse()
        await settle()
        XCTAssertTrue(sink.names.contains("response.cancel_skipped_idle"))

        server.push(RealtimeFrame.responseDoneCancelled())
        await settle()

        XCTAssertEqual(events.failures, [],
                       "the unnamed cancel is still owed an ack, and this is it")
        XCTAssertTrue(sink.names.contains("cancel_ack.received"))
        XCTAssertEqual(backend.turnStateForTesting, .open)
    }

    /// The absorption is exactly one violation wide. A cancel into a session that no longer
    /// exists is still a caller reaching for a dead pipe, and is not quietly skipped.
    func testCancellingAClosedSessionIsNotTreatedAsAnIdleSkip() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        try await backend.open { _ in }
        backend.close()

        backend.cancelResponse()
        await settle()

        XCTAssertFalse(sink.names.contains("response.cancel_skipped_idle"),
                       "no session is not the same fact as no response")
    }

    func testCapabilitiesDescribeTheTransportNotThePolicy() async {
        let backend = makeBackend(ScriptedRealtimeServer())
        XCTAssertEqual(backend.capabilities,
                       VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                duplex: true,
                                                supportsNativeTurnDetection: true,
                                                // Declaring it is not turning it on: TapQ
                                                // still resolves nothing a backend says, and
                                                // a tool call is refused outright when no
                                                // window is open to receive one.
                                                supportsToolCalling: true))
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

    /// The raw `audio.input.turn_detection` value of one `session.update` — an object when
    /// native detection is on, and `NSNull` when it is off. Deliberately not collapsed to
    /// `nil`: "off" and "absent" are different frames to GA, and only one of them disables
    /// anything.
    private func turnDetectionValue(_ server: ScriptedRealtimeServer,
                                    ofUpdate index: Int) -> Any? {
        let updates = server.sent.filter { $0["type"] as? String == "session.update" }
        guard index < updates.count else { return nil }
        return ScriptedRealtimeServer.inputAudio(of: updates[index]["session"] as? [String: Any])?
            .first { $0.key == "turn_detection" }?.value
    }

    private func turnDetection(_ server: ScriptedRealtimeServer,
                               ofUpdate index: Int) -> [String: Any]? {
        turnDetectionValue(server, ofUpdate: index) as? [String: Any]
    }

    private func turnDetectionIsOff(_ server: ScriptedRealtimeServer,
                                    ofUpdate index: Int) -> Bool {
        turnDetectionValue(server, ofUpdate: index) is NSNull
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

        XCTAssertTrue(turnDetectionIsOff(server, ofUpdate: 0))
        XCTAssertEqual(turnDetection(server, ofUpdate: 1)?["type"] as? String, "semantic_vad")
        XCTAssertEqual(turnDetection(server, ofUpdate: 1)?["eagerness"] as? String, "low")
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
        XCTAssertEqual(turnDetection(server, ofUpdate: baseline)?["type"] as? String, "semantic_vad")
        XCTAssertTrue(turnDetectionIsOff(server, ofUpdate: baseline + 1),
                      "and the way back is an explicit null, which is how GA disables it")
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
        XCTAssertTrue(turnDetectionIsOff(server, ofUpdate: 2),
                      "the reconnect handshakes manual, like every other handshake")
        XCTAssertEqual(turnDetection(server, ofUpdate: 3)?["type"] as? String, "semantic_vad",
                       "and is then put back into the mode the caller asked for")
    }

    // MARK: - Semantic turn detection

    /// The eagerness is a property of the *run*, resolved once at composition, and it is
    /// what every restatement of the session says.
    ///
    /// `session.update` is a merge in GA, so `sendSessionUpdate` restates turn detection on
    /// every frame it sends — the mode flip, a tool declaration, an instruction change. This
    /// walks all three and asserts they say the same thing, because a second spelling of
    /// `semantic_vad` reachable from one of those paths would be a session that drifted into
    /// a mode nobody chose without any single frame looking wrong.
    func testEveryRestatementCarriesTheSameSemanticConfiguration() async throws {
        let server = ScriptedRealtimeServer()
        let backend = makeBackend(server, turnEagerness: .high)
        backend.setNativeTurnDetection(true)
        try await backend.open { _ in }
        await settle()

        backend.declareTools([VoiceToolDeclaration(name: "approve", description: "yes")])
        await settle()
        backend.updateInstructions("One request is waiting.")
        await settle()

        let updates = server.sent.filter { $0["type"] as? String == "session.update" }
        XCTAssertEqual(updates.count, 4, "handshake, mode flip, tools, instructions")

        // The handshake is manual, as it must be. Everything after it is the degraded mode,
        // spelled identically each time.
        XCTAssertTrue(turnDetectionIsOff(server, ofUpdate: 0))
        for index in 1..<updates.count {
            let detection = turnDetection(server, ofUpdate: index)
            XCTAssertEqual(detection?["type"] as? String, "semantic_vad",
                           "restatement \(index) left the degraded mode")
            XCTAssertEqual(detection?["eagerness"] as? String, "high",
                           "restatement \(index) forgot the run's eagerness")
            XCTAssertEqual(detection?["create_response"] as? Bool, false,
                           "restatement \(index) let the service answer the wearer")
            XCTAssertEqual(detection?["interrupt_response"] as? Bool, false,
                           "restatement \(index) handed barge-in to the service")
        }
    }

    /// Choreography parity: what `semantic_vad` changed is *where* a turn ends, and nothing
    /// about what happens next.
    ///
    /// Under the `server_vad` this replaced, a native-mode window ran exactly this sequence,
    /// and each step is asserted rather than the outcome alone:
    ///
    /// 1. the service commits on its own and TapQ reports it as `userAudioCommittedByBackend`
    ///    without ending the turn — the microphone stays open;
    /// 2. `endUserTurn` sends **no** commit (the buffer is the service's now) and answers
    ///    `false`, clearing instead;
    /// 3. `requestModelTurn()` is what asks for the response, because the service was
    ///    forbidden to start one by `create_response: false`;
    /// 4. that `response.create` carries no instructions, so the session's standing rules
    ///    stand.
    func testTheTurnChoreographyUnderSemanticVADIsUnchanged() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, sink: sink)
        let events = EventLog()
        backend.setNativeTurnDetection(true)
        try await openTurn(backend, collecting: events)

        backend.sendAudio(pcm16(2_400))
        await settle()
        server.commitFromServerVAD()
        await settle()

        XCTAssertTrue(events.events.contains {
            if case .userAudioCommittedByBackend = $0 { return true } else { return false }
        }, "the service's own endpoint must reach the caller")
        XCTAssertFalse(server.sentTypes.contains("input_audio_buffer.commit"),
                       "TapQ committed over a buffer the service had already taken")
        XCTAssertFalse(server.sentTypes.contains("response.create"),
                       "the service's commit must not start a response by itself")

        // The wearer kept talking past the endpoint the model chose, so a tail is sitting in
        // the buffer when the window ends. That fragment is the only reason the clear below
        // has anything to do — an endpoint with nothing after it takes the empty-turn path.
        backend.sendAudio(pcm16(600))
        await settle()

        // (2) The window ends. No commit, no response — just the buffer being let go.
        // `expectingResponse: false` because that is what `askModelForCommittedSegment`
        // passes; in native mode the mode guard answers before the flag is ever read.
        XCTAssertFalse(backend.endUserTurn(expectingResponse: false),
                       "a native-mode turn end never commits")
        await settle()
        XCTAssertFalse(server.sentTypes.contains("input_audio_buffer.commit"))
        XCTAssertTrue(server.sentTypes.contains("input_audio_buffer.clear"))
        XCTAssertTrue(sink.names.contains("turn.ended_native"))

        // (3) and (4): TapQ asks, and asks with nothing of its own to say.
        XCTAssertTrue(backend.requestModelTurn())
        await settle()
        XCTAssertEqual(server.sentTypes.filter { $0 == "response.create" }.count, 1)
        let created = try XCTUnwrap(
            server.sent.last { $0["type"] as? String == "response.create" })
        let response = created["response"] as? [String: Any]
        XCTAssertNil(response?["instructions"],
                     "a per-response instruction would replace the standing tool policy for "
                        + "exactly the response that most needs it")
        XCTAssertTrue(sink.names.contains("tool.model_turn_requested"))
        XCTAssertEqual(events.failures, [])
    }

    /// The tuning is in the diagnostics at composition, before any window needs it: an
    /// operator reading a "it cut me off" report has to be able to see what the run was set
    /// to even when the run never left manual turns.
    /// `async` for the Linux discovery rule this suite already follows: a synchronous test
    /// method on a `@MainActor` class is not callable from the generated nonisolated runner.
    func testTheConfiguredEagernessIsDiagnosedAtComposition() async {
        let sink = RecordingSink()
        _ = makeBackend(ScriptedRealtimeServer(), turnEagerness: .medium, sink: sink)
        let configured = sink.events.first { $0.name == "turn_detection.configured" }
        XCTAssertEqual(configured?.fields["type"], "semantic_vad")
        XCTAssertEqual(configured?.fields["eagerness"], "medium")
    }
}
