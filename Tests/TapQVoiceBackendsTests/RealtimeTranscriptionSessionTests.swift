import XCTest
@testable import TapQVoiceBackends
import TapQContracts

/// The wire contract of a transcription-only session, against the same hostile fake peer
/// every realtime session here is tested with.
///
/// Two things these tests are careful about, because both are what the object exists for:
/// the handshake frame is pinned as an exact JSON object rather than spot-checked (a
/// transcription session that quietly grew a `model` or an `output_modalities` is a session
/// the service refuses, and a spot-check would not see it), and every ending is asserted to
/// reach the caller (the posture is fail out loud, and the one failure mode that matters is
/// a recording that stopped without saying so).
@MainActor
final class RealtimeTranscriptionSessionTests: XCTestCase {
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

    /// Drains `events` the way a real caller would, so the assertions see exactly what the
    /// stream delivered and can also see that it *finished*.
    @MainActor
    private final class TranscriptionLog {
        private(set) var events: [RealtimeTranscriptionEvent] = []
        private(set) var finished = false
        private var drain: Task<Void, Never>?

        init(_ session: RealtimeTranscriptionSession) {
            let stream = session.events
            drain = Task { @MainActor [weak self] in
                for await event in stream { self?.events.append(event) }
                self?.finished = true
            }
        }

        func stop() {
            drain?.cancel()
            drain = nil
        }

        var failures: [String] {
            events.compactMap { if case .failed(let r) = $0 { return r } else { return nil } }
        }

        /// The network's endings, which a recording outlives (2026-10-19).
        var drops: [String] {
            events.compactMap { if case .dropped(let r) = $0 { return r } else { return nil } }
        }

        var transcriptText: [String] {
            events.compactMap {
                switch $0 {
                case .delta(_, let text), .completed(_, let text): return text
                default: return nil
                }
            }
        }
    }

    private nonisolated static let now: TimeInterval = 1_234.5

    private func makeSession(_ server: ScriptedRealtimeServer,
                             configuration: RealtimeTranscriptionConfiguration
                                = RealtimeTranscriptionConfiguration(),
                             sleeps: ManualSleeps = ManualSleeps(),
                             sink: RecordingSink = RecordingSink())
        -> RealtimeTranscriptionSession {
        server.expectsTranscriptionSession = true
        return RealtimeTranscriptionSession(transport: server,
                                            configuration: configuration,
                                            sleep: sleeps.sleep,
                                            diagnosticSink: sink)
    }

    private func pcm16(_ frames: Int, byte: UInt8 = 0x11) -> VoiceAudioChunk {
        VoiceAudioChunk(data: Data(repeating: byte, count: frames * 2),
                        format: RealtimeTranscriptionSession.audioFormat,
                        timestamp: Self.now)
    }

    // MARK: - Endpoint

    func testTheDefaultEndpointAsksForATranscriptionIntent() async throws {
        // T0, 2026-09-20 (`spikes/transcription-wire`, question 1): against the live
        // service the plain `wss://api.openai.com/v1/realtime` is closed before the first
        // client frame — WebSocket code 4000, `invalid_request_error.missing_model` — and
        // this URL is the one that is accepted and acknowledged. Pinned as a string because
        // the query is the whole finding and a `URL` comparison would pass on a host that
        // silently lost it.
        XCTAssertEqual(RealtimeTranscriptionSession.defaultEndpoint.absoluteString,
                       "wss://api.openai.com/v1/realtime?intent=transcription")
        XCTAssertNotEqual(RealtimeTranscriptionSession.defaultEndpoint,
                          RealtimeDefaults.endpoint,
                          "the conversation path's URL is not a transcription endpoint")
    }

    // MARK: - Handshake

    func testTheHandshakeFrameIsExactlyTheTranscriptionSessionObject() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()

        let expected: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": "gpt-4o-transcribe"],
                        "turn_detection": ["type": "server_vad"],
                    ],
                ],
            ],
        ]
        XCTAssertEqual(server.sent.count, 1, "the session is stated once and nothing else")
        let frame = try XCTUnwrap(server.sent.first)
        XCTAssertEqual(frame as NSDictionary, expected as NSDictionary,
                       "every key in this frame is load-bearing and every key absent from it "
                           + "is absent on purpose")

        // Restated as individual assertions, not because the comparison above is in doubt
        // but because a failure of the whole object says nothing about which key moved.
        let object = try XCTUnwrap(server.sessionConfiguration)
        XCTAssertEqual(object["type"] as? String, "transcription")
        XCTAssertNil(object["model"], "a transcription session names no model")
        let input = try XCTUnwrap(ScriptedRealtimeServer.inputAudio(of: object))
        XCTAssertEqual((input["turn_detection"] as? [String: Any])?["type"] as? String,
                       "server_vad")
        XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 24_000)
        XCTAssertTrue(session.isOpen)
        XCTAssertTrue(log.events.isEmpty, "a handshake is not news")
    }

    /// The same frame with every knob the recording path actually sets.
    ///
    /// Pinned whole, beside the default above, because these five values are one decision
    /// and a test that checked them one at a time would pass on a frame that carried three
    /// of them. The shape is the one the live service accepts (measured 2026-09-20): the
    /// language inside `transcription`, the filter beside it as an object with a `type`,
    /// and the three VAD numbers inside `turn_detection` rather than anywhere else.
    func testTheHandshakeCarriesLanguageNoiseReductionAndTheVADNumbers() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(
            server,
            configuration: RealtimeTranscriptionConfiguration(
                language: "en",
                noiseReduction: .farField,
                turnDetection: .serverVAD(threshold: 0.5,
                                          prefixPaddingMs: 300,
                                          silenceDurationMs: 600)))
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()

        let expected: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": "gpt-4o-transcribe", "language": "en"],
                        "noise_reduction": ["type": "far_field"],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 600,
                        ],
                    ],
                ],
            ],
        ]
        XCTAssertEqual(server.sent.count, 1, "the session is stated once and nothing else")
        let frame = try XCTUnwrap(server.sent.first)
        XCTAssertEqual(frame as NSDictionary, expected as NSDictionary,
                       "this is the object the service accepts; a key that moved is a "
                           + "handshake it refuses")
        XCTAssertTrue(session.isOpen)
    }

    /// Every one of the five is absent unless it is asked for — no `null`, no key at all.
    ///
    /// The frame above is pinned whole so this is already implied, but implied in the
    /// direction that fails silently: a `language: null` or a `threshold: null` would be a
    /// key the service has to have an opinion about, and the default handshake's whole
    /// argument is that it states nothing it does not mean.
    func testTheNewSettingsAreAbsentRatherThanNullWhenNobodyAsked() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()

        let input = try XCTUnwrap(
            ScriptedRealtimeServer.inputAudio(of: server.sessionConfiguration))
        XCTAssertNil(input["noise_reduction"], "no filter was asked for")
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertNil(transcription["language"], "no language was asked for")
        let detection = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        for key in ["threshold", "prefix_padding_ms", "silence_duration_ms"] {
            XCTAssertNil(detection[key], "\(key) was left to the service")
        }
        XCTAssertEqual(detection.count, 1, "server_vad and nothing else")
    }

    /// `serverVAD` the constant and `serverVAD()` the function are the same frame.
    ///
    /// They coexist so that a caller with a number to state has somewhere to put it without
    /// the callers that have none changing at all — which is only true while the function's
    /// defaults are the constant.
    func testTheServerVADConstantAndTheEmptyCallAgree() async throws {
        XCTAssertEqual(RealtimeTurnDetection.serverVAD, RealtimeTurnDetection.serverVAD())
    }

    func testAPromptRidesTheHandshakeWhenOneIsGiven() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(
            server,
            configuration: RealtimeTranscriptionConfiguration(prompt: "A recording on optics."))
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()

        let input = try XCTUnwrap(
            ScriptedRealtimeServer.inputAudio(of: server.sessionConfiguration))
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["prompt"] as? String, "A recording on optics.")
    }

    func testThereIsNoPromptUnlessTheCallerAsksForOne() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()

        let input = try XCTUnwrap(
            ScriptedRealtimeServer.inputAudio(of: server.sessionConfiguration))
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertNil(transcription["prompt"],
                     "a prior is not a neutral default: each caller states its own")
    }

    func testAudioDuringTheHandshakeQueuesBehindTheSessionUpdate() async throws {
        let server = ScriptedRealtimeServer()
        server.acknowledgesSessionUpdate = false
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        let opening = Task { try await session.open() }
        await waitUntil { server.sentTypes == ["session.update"] }
        XCTAssertEqual(server.sentTypes, ["session.update"])
        XCTAssertFalse(session.isOpen, "the session is not open until the peer says so")

        session.sendAudio(pcm16(8))
        await waitUntil { server.sentTypes.count == 2 }
        XCTAssertEqual(server.sentTypes, ["session.update", "input_audio_buffer.append"],
                       "audio may queue during the handshake; it may never overtake the "
                           + "frame that states the session")

        server.push(RealtimeFrame.sessionUpdated)
        try await opening.value
        XCTAssertTrue(session.isOpen)
    }

    func testAConnectFailureThrowsAndEmitsNothing() async throws {
        let server = ScriptedRealtimeServer()
        server.connectFailure = .connectFailed("no route to host")
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        do {
            try await session.open()
            XCTFail("a session that could not connect must not report itself open")
        } catch let failure as VoiceBackendFailure {
            guard case .network(let detail) = failure else {
                return XCTFail("expected a network failure, got \(failure)")
            }
            XCTAssertTrue(detail.contains("no route to host"))
        }
        await waitUntil { log.finished }
        XCTAssertFalse(session.isOpen)
        XCTAssertTrue(log.events.isEmpty,
                      "a caller whose open threw never started consuming and must not also "
                          + "be told the session it never had died")
        XCTAssertTrue(log.finished)
    }

    func testAnErrorFrameDuringTheHandshakeThrowsRatherThanEmitting() async throws {
        let server = ScriptedRealtimeServer()
        server.acknowledgesSessionUpdate = false
        server.onSend = { type, _ in
            guard type == "session.update" else { return }
            server.push(RealtimeFrame.error(message: "unknown parameter: 'session.model'",
                                            code: "unknown_parameter"))
        }
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        do {
            try await session.open()
            XCTFail("a refused session.update is not an open session")
        } catch let failure as VoiceBackendFailure {
            XCTAssertTrue(failure.localizedDescription.contains("unknown parameter"),
                          "the service's own words are what an operator has to act on")
        }
        await waitUntil { log.finished }
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertTrue(log.finished)
    }

    func testAnAuthorizationErrorDuringTheHandshakeIsNotANetworkBlip() async throws {
        let server = ScriptedRealtimeServer()
        server.acknowledgesSessionUpdate = false
        server.onSend = { type, _ in
            guard type == "session.update" else { return }
            server.push(RealtimeFrame.error(message: "Incorrect API key provided",
                                            code: "invalid_api_key"))
        }
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        do {
            try await session.open()
            XCTFail("a rejected key is not an open session")
        } catch let failure as VoiceBackendFailure {
            guard case .authorization = failure else {
                return XCTFail("a bad key must not be retried as a blip: \(failure)")
            }
        }
    }

    func testAHandshakeThatIsNeverAcknowledgedTimesOut() async throws {
        let server = ScriptedRealtimeServer()
        server.acknowledgesSessionUpdate = false
        let sleeps = ManualSleeps()
        let session = makeSession(server, sleeps: sleeps)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        let opening = Task { try await session.open() }
        await waitUntil {
            sleeps.fireAll()
            return server.closeCount == 1
        }
        do {
            try await opening.value
            XCTFail("a session nobody acknowledged is not an open session")
        } catch let failure as VoiceBackendFailure {
            XCTAssertEqual(failure, .network("the transcription handshake timed out after 10 s"))
        }
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(server.closeCount, 1, "a session that never opened still lets go of "
                           + "its socket")
    }

    /// A close that lands while `open()` is still waiting for the ack. The continuation it
    /// is parked on has to be settled by the teardown, or the caller's `open` never returns
    /// — which is the one failure this object's whole "nothing here can hang" claim is
    /// about.
    func testAClosewhileTheHandshakeIsOutstandingUnparksOpen() async throws {
        let server = ScriptedRealtimeServer()
        server.acknowledgesSessionUpdate = false
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        let opening = Task { try await session.open() }
        await waitUntil { server.sentTypes == ["session.update"] }
        session.close()
        await waitUntil { log.finished }

        do {
            try await opening.value
            XCTFail("a session that was closed mid-handshake did not open")
        } catch let failure as VoiceBackendFailure {
            guard case .closed = failure else {
                return XCTFail("expected a closed failure, got \(failure)")
            }
        }
        XCTAssertFalse(session.isOpen)
        XCTAssertTrue(log.finished)
    }

    func testOpeningTwiceIsRefused() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        do {
            try await session.open()
            XCTFail("a transcription session has one life")
        } catch let failure as VoiceBackendFailure {
            guard case .protocolViolation = failure else {
                return XCTFail("expected a protocol violation, got \(failure)")
            }
        }
    }

    // MARK: - Audio

    func testAudioIsForwardedInOrderAndBase64Encoded() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        let blocks = [pcm16(8, byte: 0x01), pcm16(8, byte: 0x02), pcm16(8, byte: 0x03)]
        for block in blocks { session.sendAudio(block) }
        await waitUntil { server.appendedAudio.count == 3 }

        XCTAssertEqual(server.appendedAudio, blocks.map(\.data),
                       "the peer reassembles a stream; a reordered append is scrambled audio")
        XCTAssertEqual(server.sentFrames(ofType: "input_audio_buffer.append").count, 3)
    }

    func testAnEmptyChunkIsNotAFrame() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        session.sendAudio(pcm16(0))
        session.commit()
        await waitUntil { server.sentTypes.last == "input_audio_buffer.commit" }

        XCTAssertTrue(server.sentFrames(ofType: "input_audio_buffer.append").isEmpty)
        XCTAssertTrue(log.failures.isEmpty, "silence is not a protocol violation")
    }

    func testAudioInTheWrongEncodingEndsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        session.sendAudio(VoiceAudioChunk(data: Data(repeating: 0x22, count: 32),
                                          format: .pcm16Mono16k,
                                          timestamp: Self.now))
        await waitUntil { log.finished }

        XCTAssertEqual(log.failures.count, 1)
        XCTAssertTrue(log.failures[0].contains("16000"),
                      "a caller feeding the wrong rate records noise transcribed as words")
        XCTAssertTrue(server.sentFrames(ofType: "input_audio_buffer.append").isEmpty)
    }

    func testCommitAsksForTheTrailingUtterance() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        session.sendAudio(pcm16(8))
        session.commit()
        await waitUntil { server.sentTypes.count == 3 }

        XCTAssertEqual(server.sentTypes,
                       ["session.update", "input_audio_buffer.append",
                        "input_audio_buffer.commit"])
    }

    func testSendingAudioBeforeOpenEndsTheSessionOutLoud() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        session.sendAudio(pcm16(8))
        await waitUntil { log.finished }

        XCTAssertEqual(log.failures.count, 1)
        XCTAssertTrue(log.failures[0].contains("before the session was opened"),
                      "a caller feeding a session it never opened is recording nothing and "
                          + "has to find out at the first chunk")
        XCTAssertTrue(log.finished)
        XCTAssertTrue(server.sent.isEmpty)
    }

    func testAFailedSendEndsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.sendFailure = .sendFailed("broken pipe")
        session.sendAudio(pcm16(8))
        await waitUntil { log.finished }

        XCTAssertTrue(log.failures.isEmpty, "a broken pipe is the network, not a refusal")
        XCTAssertEqual(log.drops.count, 1)
        XCTAssertTrue(log.drops.first?.contains("broken pipe") ?? false)
        XCTAssertTrue(log.finished)
    }

    // MARK: - Segments

    func testSegmentsAreReportedWithTheirItemIds() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.speechStarted(itemID: "item_1", audioStartMs: 1200)
        server.speechStopped(itemID: "item_1", audioEndMs: 2900)
        server.push(RealtimeFrame.inputAudioCommitted(itemID: "item_1"))
        server.push(RealtimeFrame.transcriptDelta("the wave ", itemID: "item_1"))
        server.push(RealtimeFrame.transcriptDelta("equation", itemID: "item_1"))
        server.push(RealtimeFrame.transcriptCompleted("The wave equation.", itemID: "item_1"))
        await waitUntil { log.events.count == 6 }

        XCTAssertEqual(log.events, [
            .speechStarted(itemID: "item_1", audioStartMs: 1200),
            .speechStopped(itemID: "item_1", audioEndMs: 2900),
            .committed(itemID: "item_1"),
            .delta(itemID: "item_1", text: "the wave "),
            .delta(itemID: "item_1", text: "equation"),
            .completed(itemID: "item_1", transcript: "The wave equation."),
        ])
    }

    func testDeltasAreFragmentsRatherThanTheSegmentSoFar() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.push(RealtimeFrame.transcriptDelta("one ", itemID: "item_1"))
        server.push(RealtimeFrame.transcriptDelta("two ", itemID: "item_1"))
        server.push(RealtimeFrame.transcriptDelta("three", itemID: "item_1"))
        await waitUntil { log.events.count == 3 }

        XCTAssertEqual(log.transcriptText, ["one ", "two ", "three"],
                       "this object forwards increments; the caller owns the accumulator, "
                           + "because only the caller knows how many segments are in flight")
    }

    func testTwoSegmentsInFlightStayApart() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.push(RealtimeFrame.transcriptDelta("first", itemID: "item_1"))
        server.push(RealtimeFrame.transcriptDelta("second", itemID: "item_2"))
        server.push(RealtimeFrame.transcriptCompleted("First.", itemID: "item_1"))
        await waitUntil { log.events.count == 3 }

        XCTAssertEqual(log.events, [
            .delta(itemID: "item_1", text: "first"),
            .delta(itemID: "item_2", text: "second"),
            .completed(itemID: "item_1", transcript: "First."),
        ])
    }

    func testAPeerThatNamesNoItemStillReportsSegments() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.push(RealtimeFrame.inputAudioCommitted())
        server.push(RealtimeFrame.transcriptCompleted("Unnamed."))
        await waitUntil { log.events.count == 2 }

        XCTAssertEqual(log.events, [
            .committed(itemID: nil),
            .completed(itemID: nil, transcript: "Unnamed."),
        ])
    }

    func testAnEmptySettledSegmentIsStillReported() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.push(RealtimeFrame.transcriptDelta("", itemID: "item_1"))
        server.push(RealtimeFrame.transcriptCompleted("", itemID: "item_1"))
        await waitUntil { log.events.count == 1 }

        XCTAssertEqual(log.events, [.completed(itemID: "item_1", transcript: "")],
                       "an empty fragment extends nothing, but an empty settled segment "
                           + "tells a caller to stop waiting for the rest of that item")
    }

    func testUnknownEventsAreIgnoredWithOneDiagnosticEach() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let session = makeSession(server, sink: sink)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.push(RealtimeFrame.unknownEvent)
        server.push(RealtimeFrame.transcriptCompleted("still here", itemID: "item_1"))
        await waitUntil { log.events.count == 1 }

        XCTAssertEqual(log.events, [.completed(itemID: "item_1", transcript: "still here")],
                       "a new upstream event must not be able to end a recording")
        let ignored = sink.events.filter { $0.name == "event.ignored" }
        XCTAssertEqual(ignored.compactMap { $0.fields["type"] },
                       ["session.created", "rate_limits.updated"],
                       "one line each, and `session.created` is on the list: the connection "
                           + "existing is not the peer acknowledging the session")
        XCTAssertEqual(ignored.first?.level, .debug)
    }

    func testTranscriptTextNeverLeavesTheSessionAboveDebug() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let session = makeSession(server, sink: sink)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.push(RealtimeFrame.transcriptCompleted("the private thing they said",
                                                      itemID: "item_1"))
        session.sendAudio(pcm16(8))
        await waitUntil { log.events.count == 1 && server.appendedAudio.count == 1 }
        session.close()
        await waitUntil { log.finished }

        for event in sink.events where event.level != .debug {
            for value in event.fields.values {
                XCTAssertFalse(value.contains("private thing"),
                               "what was said in the room belongs to the people in it")
            }
        }
        XCTAssertEqual(sink.events.first(where: { $0.name == "session.opened" })?.category,
                       "transcription")
    }

    /// The VAD trace: every inbound frame the peer's own detector sends, in the record, at
    /// debug.
    ///
    /// Added 2026-09-20 after a five-minute run in which the service sent nothing for four
    /// minutes while the room measured rms_peak 0.11-0.31. Nothing in the diagnostics could
    /// say whether the peer's VAD had stopped firing
    /// or whether it was firing and finding nothing, because the only thing this session
    /// used to say about an inbound frame was `event.ignored` for the ones it had no job for.
    func testTheVADTraceIsRecordedAtDebugWithTheMillisecondsThePeerStates() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let session = makeSession(server, sink: sink)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.speechStarted(audioStartMs: 0)
        server.speechStopped(audioEndMs: 4528)
        server.push(RealtimeFrame.inputAudioCommitted(itemID: "item_1"))
        server.push(RealtimeFrame.transcriptCompleted("The wave equation.", itemID: "item_1"))
        await waitUntil { log.events.count == 4 }

        let trace = sink.events.filter {
            $0.name.hasPrefix("vad.") || $0.name == "transcript.completed"
        }
        XCTAssertEqual(trace.map(\.name),
                       ["vad.speech_started", "vad.speech_stopped", "vad.committed",
                        "transcript.completed"])
        XCTAssertTrue(trace.allSatisfy { $0.level == .debug },
                      "a busy recording is a few hundred of these a minute")
        XCTAssertEqual(trace[0].fields["audio_start_ms"], "0")
        XCTAssertEqual(trace[1].fields["audio_end_ms"], "4528")
        XCTAssertEqual(trace[2].fields["item_id"], "item_1")
        XCTAssertEqual(trace[3].fields["item_id"], "item_1")
        XCTAssertEqual(trace[3].fields["chars"], "18",
                       "how long the transcript was, never a word of it")
        for event in sink.events {
            for value in event.fields.values {
                XCTAssertFalse(value.contains("wave"),
                               "the diagnostics file holds no transcript text at any "
                                   + "level, `.debug` included")
            }
        }
    }

    /// The peer that states no millisecond, which is what the end-to-end harness's fake peer
    /// sends: the field says `unstated` and the session goes on transcribing.
    func testAPeerThatStatesNoMillisecondIsTracedAnyway() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let session = makeSession(server, sink: sink)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.speechStarted()
        server.speechStopped()
        await waitUntil { log.events.count == 2 }

        XCTAssertEqual(log.events, [.speechStarted(itemID: nil, audioStartMs: nil),
                                    .speechStopped(itemID: nil, audioEndMs: nil)])
        XCTAssertEqual(sink.events.first { $0.name == "vad.speech_started" }?
                           .fields["audio_start_ms"], "unstated")
        XCTAssertEqual(sink.events.first { $0.name == "vad.speech_stopped" }?
                           .fields["audio_end_ms"], "unstated")
    }

    /// An error frame is the one failure the service named, and the name is the thing to
    /// grep for — so it gets its own line, at `.error`, beside the `session.failed` that
    /// every other way of dying shares.
    func testAnErrorFrameRecordsThePeersOwnCodeAtErrorLevel() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let session = makeSession(server, sink: sink)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.push(RealtimeFrame.error(message: "Invalid value: 'xx'.", code: "invalid_value"))
        await waitUntil { log.finished }

        let frame = sink.events.first { $0.name == "error.frame" }
        XCTAssertEqual(frame?.level, .error)
        XCTAssertEqual(frame?.fields["code"], "invalid_value")
        XCTAssertEqual(log.failures.count, 1)
    }

    /// An empty commit answers a commit of the caller's and ends nothing (2026-10-19): the
    /// session stays open, and what the peer says after it is still reported.
    func testAnEmptyCommitIsReportedAndTheSessionGoesOn() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let session = makeSession(server, sink: sink)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        session.commit()
        server.push(RealtimeFrame.error(message: "Error committing input audio buffer: buffer too small.",
                                        code: "input_audio_buffer_commit_empty"))
        server.push(RealtimeFrame.transcriptCompleted("still here", itemID: "item_1"))
        await waitUntil { log.events.count == 2 }

        XCTAssertEqual(log.events, [.commitEmpty,
                                    .completed(itemID: "item_1", transcript: "still here")])
        XCTAssertTrue(session.isOpen)
        XCTAssertFalse(log.finished)
        XCTAssertEqual(server.closeCount, 0)
        XCTAssertFalse(sink.names.contains("error.frame"), "an answer, not an error")
    }

    /// An ack with a drop right behind it: however the two land against `open()`, the session
    /// is never left open with nothing to say it ended (review, 2026-10-19). Either `open()`
    /// throws, or it returns and the drop is reported.
    func testAnAckFollowedAtOnceByADropNeverLeavesASilentOpenSession() async throws {
        let server = ScriptedRealtimeServer()
        server.onSend = { [unowned server] type, _ in
            // The fake has queued `session.created` and the ack; the drop lands behind them.
            if type == "session.update" { server.disconnect() }
        }
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        var opened = false
        do {
            try await session.open()
            opened = true
        } catch let failure as VoiceBackendFailure {
            guard case .network = failure else { return XCTFail("\(failure)") }
        }
        await waitUntil { server.closeCount == 1 }
        XCTAssertFalse(session.isOpen)
        if opened {
            await waitUntil { log.finished }
            XCTAssertEqual(log.drops.count, 1, "an open session that ended says so")
        }
    }

    /// A send that does not return within its bound is a socket that stopped draining (a
    /// half-open link fails no send): the session ends as a drop, which a recording outlives.
    func testASendThatNeverReturnsEndsTheSessionAsADrop() async throws {
        let server = ScriptedRealtimeServer()
        let sleeps = ManualSleeps()
        server.expectsTranscriptionSession = true
        let session = RealtimeTranscriptionSession(transport: server,
                                                   configuration: RealtimeTranscriptionConfiguration(),
                                                   sendTimeout: 15, sleep: sleeps.sleep)
        let log = TranscriptionLog(session)
        defer { log.stop() }
        try await session.open()

        server.stallsSends = true
        session.sendAudio(pcm16(2_400))
        await waitUntil { server.parkedSends == 1 }
        // Woken until the bound, armed beside the send, has parked too.
        await waitUntil {
            sleeps.fireAll()
            return log.finished
        }

        XCTAssertEqual(log.drops, ["a send did not return within 15 s: the connection is not draining"])
        XCTAssertTrue(log.failures.isEmpty)
        XCTAssertFalse(session.isOpen)
    }

    /// One that returns in time ends nothing, however slow it was: the bound is on a send
    /// that never comes back, not on a slow link.
    func testASendThatReturnsInTimeEndsNothing() async throws {
        let server = ScriptedRealtimeServer()
        let sleeps = ManualSleeps()
        server.expectsTranscriptionSession = true
        let session = RealtimeTranscriptionSession(transport: server,
                                                   configuration: RealtimeTranscriptionConfiguration(),
                                                   sendTimeout: 15, sleep: sleeps.sleep)
        let log = TranscriptionLog(session)
        defer { log.stop() }
        try await session.open()

        server.stallsSends = true
        session.sendAudio(pcm16(2_400))
        await waitUntil { server.parkedSends == 1 }
        server.releaseSends()
        await waitUntil { server.appendedAudio.count == 1 && session.outboundBytes == 0 }
        // Bounded, for the end that must not come: every bound is woken, its send returned,
        // and a woken bound whose send returned does nothing and leaves nothing to wait for.
        for _ in 0..<16 {
            sleeps.fireAll()
            await Task.yield()
        }

        XCTAssertTrue(session.isOpen)
        XCTAssertFalse(log.finished)
        XCTAssertEqual(session.sentBytes, session.handedBytes, "everything handed was sent")
    }

    /// A connection the peer refused mid-session (an upgrade answered 401 on a reconnect, a
    /// close naming a refusal) is a failure, not a drop: nothing outlives it.
    func testARefusedConnectionIsAFailureNotADrop() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.disconnect(.refused("close 4000 (invalid_request_error.missing_model): gone",
                                   authorization: false))
        await waitUntil { log.finished }

        XCTAssertEqual(log.failures, ["close 4000 (invalid_request_error.missing_model): gone"])
        XCTAssertTrue(log.drops.isEmpty)
    }

    // MARK: - Endings

    func testAnErrorFrameEndsTheSessionAndFinishesTheStream() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.push(RealtimeFrame.error(message: "Server error", code: "server_error"))
        server.push(RealtimeFrame.transcriptCompleted("after the end", itemID: "item_9"))
        await waitUntil { log.finished }

        XCTAssertEqual(log.events, [.failed(reason: "Server error (server_error)")],
                       "failed is terminal: nothing the peer says afterwards is reported")
        XCTAssertTrue(log.finished)
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(server.closeCount, 1)
    }

    /// The service's own `server_error` is it failing, not refusing: a drop, which a
    /// recording outlives; a refusal stays a failure (2026-10-19).
    func testAServerErrorFrameIsADropAndARefusalIsAFailure() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }
        try await session.open()
        server.push(RealtimeFrame.error(message: "The server had an error.", type: "server_error"))
        await waitUntil { log.finished }
        XCTAssertEqual(log.events, [.dropped(reason: "The server had an error.")])

        let refused = ScriptedRealtimeServer()
        let other = makeSession(refused)
        let otherLog = TranscriptionLog(other)
        defer { otherLog.stop() }
        try await other.open()
        refused.push(RealtimeFrame.error(message: "Invalid value: 'x'.", code: "invalid_value"))
        await waitUntil { otherLog.finished }
        XCTAssertEqual(otherLog.events, [.failed(reason: "Invalid value: 'x'. (invalid_value)")])
    }

    /// D4: the service's cap is a planned end, classified by its code and nothing else.
    func testSessionExpiredEndsTheSessionAsExpiredNotFailed() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let session = makeSession(server, sink: sink)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.push(RealtimeFrame.error(message: "Your session hit the maximum duration",
                                        code: "session_expired"))
        server.push(RealtimeFrame.transcriptCompleted("after the end", itemID: "item_9"))
        await waitUntil { log.finished }

        XCTAssertEqual(log.events, [.expired])
        XCTAssertTrue(log.finished)
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(server.closeCount, 1)
        XCTAssertFalse(sink.names.contains("session.failed"))
        session.sendAudio(pcm16(8))
        XCTAssertEqual(server.sentTypes, ["session.update"], "an expired session takes nothing")
    }

    /// A failed segment is one item's loss, not the session's.
    func testAFailedSegmentIsReportedAndTheSessionGoesOn() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.push(RealtimeFrame.transcriptFailed(itemID: "item_1", code: "audio_unintelligible"))
        server.push(RealtimeFrame.transcriptCompleted("Next.", itemID: "item_2"))
        await waitUntil { log.events.count == 2 }

        XCTAssertEqual(log.events, [
            .transcriptionFailed(itemID: "item_1", reason: "audio_unintelligible"),
            .completed(itemID: "item_2", transcript: "Next."),
        ])
        XCTAssertTrue(session.isOpen)
    }

    /// 07-10: audio queued behind a socket that has stopped draining ends the session, out
    /// loud, once the backlog passes the cap.
    func testAnOutboundBacklogPastTheCapEndsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.stallsSends = true
        // One second of audio is ten appends of ~6.4 KB of base64: the cap holds ~32 s.
        let second = pcm16(24_000)
        session.sendAudio(second)
        await waitUntil { server.parkedSends == 1 }
        var calls = 0
        while session.isOpen, calls < 100 {
            session.sendAudio(second)
            calls += 1
        }

        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(calls, 32, "the 2 MB cap, measured in queued frame bytes")
        await waitUntil { log.finished }
        XCTAssertEqual(log.drops.count, 1, "a socket that stopped draining is the network")
        XCTAssertTrue(log.drops.first?.contains("outbound queue") ?? false)
    }

    /// A burst queued in one main-actor turn, before the pump has run, is not a socket that
    /// stopped draining: transcription mode feeds a minute at once in its tests.
    func testABurstBeforeThePumpRunsIsNotABacklog() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        for _ in 0..<60 { session.sendAudio(pcm16(24_000)) }
        await waitUntil { server.sentFrames(ofType: "input_audio_buffer.append").count == 600 }

        XCTAssertTrue(session.isOpen)
        XCTAssertTrue(log.failures.isEmpty)
    }

    func testATransportDropEndsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.disconnect()
        await waitUntil { log.finished }

        XCTAssertEqual(log.drops.count, 1)
        XCTAssertTrue(log.drops.first?.contains("socket dropped") ?? false)
        XCTAssertTrue(log.failures.isEmpty)
        XCTAssertTrue(log.finished)
        XCTAssertFalse(session.isOpen)
    }

    func testAPeerHangingUpWithoutACloseEndsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.hangUp()
        await waitUntil { log.finished }

        XCTAssertEqual(log.events, [.dropped(reason: "the peer closed the session")],
                       "a clean close TapQ did not ask for ends the session, as the network does")
        XCTAssertTrue(log.finished)
    }

    func testAnUndecodableFrameEndsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        server.push("{ not json at all")
        await waitUntil { log.finished }

        XCTAssertEqual(log.failures.count, 1)
        XCTAssertTrue(log.failures[0].contains("could not be read"))
        XCTAssertTrue(log.finished)
    }

    func testCloseIsIdempotentAndFinishesTheStream() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        session.close()
        session.close()
        await waitUntil { log.finished }

        XCTAssertTrue(log.finished)
        XCTAssertTrue(log.failures.isEmpty,
                      "a close is what the caller asked for, not news about a failure")
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(server.closeCount, 1)
    }

    func testAPeerStreamEndingAfterACloseIsNotAFailure() async throws {
        let server = ScriptedRealtimeServer()
        let session = makeSession(server)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        session.close()
        server.hangUp()
        await waitUntil { log.finished }

        XCTAssertTrue(log.failures.isEmpty,
                      "the peer's stream ending is the expected consequence of a close")
        XCTAssertTrue(log.finished)
    }

    func testFramesAfterACloseAreRecordedRatherThanReported() async throws {
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let session = makeSession(server, sink: sink)
        let log = TranscriptionLog(session)
        defer { log.stop() }

        try await session.open()
        session.close()
        session.sendAudio(pcm16(8))
        session.commit()
        await waitUntil { log.finished }

        XCTAssertTrue(log.failures.isEmpty)
        XCTAssertEqual(sink.events.filter { $0.name == "frame.afterEnd" }.count, 2,
                       "the stream has already finished, so saying so in the log is the "
                           + "whole of what is left to do")
        XCTAssertEqual(server.sentTypes, ["session.update"])
    }
}
