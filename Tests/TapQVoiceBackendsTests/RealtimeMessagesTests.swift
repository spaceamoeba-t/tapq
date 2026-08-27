import XCTest
@testable import TapQVoiceBackends

final class RealtimeMessagesTests: XCTestCase {

    private func object(_ frame: String) throws -> [String: Any] {
        let data = try XCTUnwrap(frame.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Client events

    func testSessionUpdateDisablesServerTurnDetection() throws {
        let frame = try RealtimeClientEvent.sessionUpdate(RealtimeSessionConfiguration())
            .encodedFrame()
        let json = try object(frame)

        XCTAssertEqual(json["type"] as? String, "session.update")
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let detection = try XCTUnwrap(session["turn_detection"] as? [String: Any])
        XCTAssertEqual(detection["type"] as? String, "none",
                       "manual-turn mode is the whole reason this adapter exists")
    }

    func testSessionUpdateCarriesTheAudioAndTranscriptionSlice() throws {
        let configuration = RealtimeSessionConfiguration(model: "gpt-realtime-mini",
                                                         instructions: "be brief",
                                                         voice: "cedar")
        let json = try object(try RealtimeClientEvent.sessionUpdate(configuration).encodedFrame())
        let session = try XCTUnwrap(json["session"] as? [String: Any])

        XCTAssertEqual(session["model"] as? String, "gpt-realtime-mini")
        XCTAssertEqual(session["input_audio_format"] as? String, "pcm16")
        XCTAssertEqual(session["output_audio_format"] as? String, "pcm16")
        XCTAssertEqual(session["instructions"] as? String, "be brief")
        XCTAssertEqual(session["voice"] as? String, "cedar")
        let transcription = try XCTUnwrap(session["input_audio_transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String,
                       RealtimeDefaults.inputTranscriptionModel,
                       "without input transcription the grammar has nothing to match")
    }

    func testSessionUpdateOmitsUnsetOptionalFields() throws {
        let json = try object(
            try RealtimeClientEvent.sessionUpdate(RealtimeSessionConfiguration()).encodedFrame())
        let session = try XCTUnwrap(json["session"] as? [String: Any])

        XCTAssertNil(session["instructions"])
        XCTAssertNil(session["voice"], "unset settings stay at the service default")
    }

    func testAppendFramesBase64EncodeTheAudio() throws {
        let audio = Data([0x00, 0x01, 0xFE, 0xFF, 0x10, 0x20])
        let json = try object(try RealtimeClientEvent.appendInputAudio(audio).encodedFrame())

        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.append")
        let encoded = try XCTUnwrap(json["audio"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), audio, "audio survives the framing round-trip")
    }

    func testCommitAndCancelAreBareFrames() throws {
        XCTAssertEqual(try object(try RealtimeClientEvent.commitInputAudio.encodedFrame())["type"]
                        as? String, "input_audio_buffer.commit")
        XCTAssertEqual(try object(try RealtimeClientEvent.cancelResponse.encodedFrame())["type"]
                        as? String, "response.cancel")
    }

    func testResponseCreateCarriesInstructionsOnlyWhenGiven() throws {
        let bare = try object(try RealtimeClientEvent.createResponse(instructions: nil)
            .encodedFrame())
        XCTAssertEqual(bare["type"] as? String, "response.create")
        XCTAssertNil(bare["response"])

        let directed = try object(try RealtimeClientEvent
            .createResponse(instructions: "say yes").encodedFrame())
        let response = try XCTUnwrap(directed["response"] as? [String: Any])
        XCTAssertEqual(response["instructions"] as? String, "say yes")
    }

    /// The degraded direction of the switch, field by field.
    ///
    /// Every one of these three is load-bearing and none of them is obvious from the type
    /// name: `server_vad` is what makes a transcript exist at all without an IMU endpoint;
    /// `create_response: false` is the line between "the service may say where the sentence
    /// ended" and "the service may answer it", which is the whole limit of the carve-out;
    /// and `interrupt_response: false` keeps barge-in with `WearerTurnCoordinator`, which is
    /// the only component that knows whether the voice it heard belonged to the wearer.
    func testSessionUpdateCanHandEndOfSpeechDetectionToTheService() throws {
        let configuration = RealtimeSessionConfiguration(turnDetection: .serverVAD)
        let json = try object(try RealtimeClientEvent.sessionUpdate(configuration).encodedFrame())
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let detection = try XCTUnwrap(session["turn_detection"] as? [String: Any])

        XCTAssertEqual(detection["type"] as? String, "server_vad")
        XCTAssertEqual(detection["create_response"] as? Bool, false,
                       "the service may end a turn; it may never author a sentence")
        XCTAssertEqual(detection["interrupt_response"] as? Bool, false,
                       "barge-in stays with the IMU, which knows who spoke")
    }

    /// The manual direction, byte for byte what it always was.
    ///
    /// The new fields are optional so that switching back is not a different frame from the
    /// one every session has always handshaked with — a `create_response: null` riding along
    /// would be a wire change nobody asked for.
    func testTheManualFrameIsUnchangedByTheNewFields() throws {
        let json = try object(
            try RealtimeClientEvent.sessionUpdate(
                RealtimeSessionConfiguration(turnDetection: .disabled)).encodedFrame())
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let detection = try XCTUnwrap(session["turn_detection"] as? [String: Any])

        XCTAssertEqual(detection["type"] as? String, "none")
        XCTAssertEqual(detection.count, 1,
                       "manual mode carries nothing but its type: \(detection)")
    }

    func testClearIsABareFrame() throws {
        XCTAssertEqual(try object(try RealtimeClientEvent.clearInputAudio.encodedFrame())["type"]
                        as? String, "input_audio_buffer.clear")
    }

    func testWireTypesMatchTheEncodedFrames() throws {
        let events: [RealtimeClientEvent] = [
            .sessionUpdate(RealtimeSessionConfiguration()),
            .appendInputAudio(Data([1, 2])),
            .commitInputAudio,
            .clearInputAudio,
            .createResponse(instructions: nil),
            .cancelResponse,
        ]
        for event in events {
            XCTAssertEqual(try object(try event.encodedFrame())["type"] as? String, event.wireType)
        }
    }

    func testFramesAreByteStable() throws {
        let event = RealtimeClientEvent.sessionUpdate(RealtimeSessionConfiguration())
        XCTAssertEqual(try event.encodedFrame(), try event.encodedFrame(),
                       "sorted keys keep frames diffable in logs and test failures")
    }

    // MARK: - Server events

    func testDecodesTheSessionLifecycle() throws {
        XCTAssertEqual(try RealtimeServerEvent.decode(#"{"type":"session.created"}"#),
                       .sessionCreated)
        XCTAssertEqual(try RealtimeServerEvent.decode(#"{"type":"session.updated"}"#),
                       .sessionUpdated)
    }

    func testDecodesTranscriptDeltasAndCompletions() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(RealtimeFrame.transcriptDelta("yes")),
            .transcriptDelta("yes"))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(RealtimeFrame.transcriptCompleted("yes go")),
            .transcriptCompleted("yes go"))
    }

    func testDecodesAudioDeltaFromBase64() throws {
        let audio = Data(repeating: 0x7F, count: 96)
        XCTAssertEqual(try RealtimeServerEvent.decode(RealtimeFrame.audioDelta(audio)),
                       .audioDelta(audio))
    }

    func testAudioDeltaThatIsNotBase64IsMalformed() {
        let frame = #"{"type":"response.output_audio.delta","delta":"not base64 !!"}"#
        XCTAssertThrowsError(try RealtimeServerEvent.decode(frame)) { error in
            guard case .malformedFrame(let detail)? = error as? RealtimeMessageError else {
                return XCTFail("expected a malformed-frame error, got \(error)")
            }
            XCTAssertTrue(detail.contains("base64"))
        }
    }

    func testDecodesResponseCompletionUnderBothSpellings() throws {
        XCTAssertEqual(try RealtimeServerEvent.decode(RealtimeFrame.responseDone),
                       .responseCompleted)
        XCTAssertEqual(try RealtimeServerEvent.decode(#"{"type":"response.completed"}"#),
                       .responseCompleted)
    }

    func testDecodesErrorEvents() throws {
        let event = try RealtimeServerEvent.decode(
            RealtimeFrame.error(message: "boom", code: "server_error"))
        guard case .failure(let failure) = event else {
            return XCTFail("expected a failure event, got \(event)")
        }
        XCTAssertEqual(failure.message, "boom")
        XCTAssertEqual(failure.code, "server_error")
        XCTAssertFalse(failure.isAuthorization)
    }

    func testAuthorizationErrorsAreRecognized() throws {
        let codes = ["invalid_api_key", "unauthorized"]
        for code in codes {
            let event = try RealtimeServerEvent.decode(
                RealtimeFrame.error(message: "rejected", code: code))
            guard case .failure(let failure) = event else {
                return XCTFail("expected a failure event for \(code)")
            }
            XCTAssertTrue(failure.isAuthorization,
                          "\(code) must not be retried as if it were a network blip")
        }
    }

    // MARK: - Tolerance

    func testUnknownEventTypesDecodeAsUnsupported() throws {
        XCTAssertEqual(try RealtimeServerEvent.decode(RealtimeFrame.unknownEvent),
                       .unsupported("rate_limits.updated"),
                       "a new upstream event must not be able to kill a session")
    }

    func testUnknownFieldsAreIgnored() throws {
        let frame = """
        {"type":"conversation.item.input_audio_transcription.delta","delta":"ok",\
        "event_id":"ev_9","item_id":"item_3","content_index":0,"logprobs":[{"token":"ok"}]}
        """
        XCTAssertEqual(try RealtimeServerEvent.decode(frame), .transcriptDelta("ok"))
    }

    func testMissingPayloadFieldsDegradeRatherThanThrow() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(
                #"{"type":"conversation.item.input_audio_transcription.delta"}"#),
            .transcriptDelta(""))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(
                #"{"type":"conversation.item.input_audio_transcription.completed"}"#),
            .transcriptCompleted(""))
    }

    func testFramesWithoutATypeAreMalformed() {
        for frame in [#"{"delta":"yes"}"#, "not json at all", ""] {
            XCTAssertThrowsError(try RealtimeServerEvent.decode(frame),
                                 "a frame with no type is unreadable, not unsupported")
        }
    }

    func testErrorEventWithoutAnErrorBodyIsMalformed() {
        XCTAssertThrowsError(try RealtimeServerEvent.decode(#"{"type":"error"}"#))
    }

    /// The server-VAD flow, decoded. Modelled rather than left to `.unsupported` because the
    /// commit is the event the degraded path turns on, and the two speech events around it
    /// are what make a silent run diagnosable from the log alone.
    func testDecodesTheServerVADFlow() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"type":"input_audio_buffer.speech_started"}"#),
            .speechStarted)
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"type":"input_audio_buffer.speech_stopped"}"#),
            .speechStopped)
        XCTAssertEqual(
            try RealtimeServerEvent.decode(
                #"{"type":"input_audio_buffer.committed","item_id":"item_1"}"#),
            .inputAudioCommitted,
            "the payload's item id is the service's bookkeeping, not TapQ's")
    }
}
