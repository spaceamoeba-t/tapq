import XCTest
@testable import TapQVoiceBackends

final class RealtimeMessagesTests: XCTestCase {

    private func object(_ frame: String) throws -> [String: Any] {
        let data = try XCTUnwrap(frame.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Client events

    /// Reaches into `session.audio.input`, which is where GA moved every setting that used
    /// to sit flat on the session object.
    private func inputAudio(_ session: [String: Any]) throws -> [String: Any] {
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        return try XCTUnwrap(audio["input"] as? [String: Any])
    }

    func testSessionUpdateDisablesServerTurnDetection() throws {
        let frame = try RealtimeClientEvent.sessionUpdate(RealtimeSessionConfiguration())
            .encodedFrame()
        let json = try object(frame)

        XCTAssertEqual(json["type"] as? String, "session.update")
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "realtime",
                       "GA rejects a session object with no discriminator")
        let input = try inputAudio(session)
        XCTAssertTrue(input["turn_detection"] is NSNull,
                      "manual-turn mode is the whole reason this adapter exists")
    }

    /// The one encoding detail this migration cannot get wrong.
    ///
    /// GA's `session.update` merges: a key that is absent keeps whatever the session already
    /// had. So turning native detection back *off* has to send a literal `null`, not drop
    /// the key — a dropped key would leave the service's VAD running while TapQ believed it
    /// had taken turn arbitration back, which is the exact failure the handshake exists to
    /// prevent.
    func testManualModeSendsAnExplicitNullRatherThanOmittingTheKey() throws {
        let frame = try RealtimeClientEvent
            .sessionUpdate(RealtimeSessionConfiguration(turnDetection: nil)).encodedFrame()

        XCTAssertTrue(frame.contains("\"turn_detection\":null"),
                      "an omitted key is a no-op merge, not a disable: \(frame)")
        let input = try inputAudio(try XCTUnwrap(try object(frame)["session"] as? [String: Any]))
        XCTAssertTrue(input.keys.contains("turn_detection"))
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func testSessionUpdateCarriesTheAudioAndTranscriptionSlice() throws {
        let configuration = RealtimeSessionConfiguration(model: "gpt-realtime-mini",
                                                         instructions: "be brief",
                                                         voice: "cedar")
        let json = try object(try RealtimeClientEvent.sessionUpdate(configuration).encodedFrame())
        let session = try XCTUnwrap(json["session"] as? [String: Any])

        XCTAssertEqual(session["model"] as? String, "gpt-realtime-mini")
        XCTAssertEqual(session["instructions"] as? String, "be brief")
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"],
                       "GA takes one modality, and audio carries its own transcript")

        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        // GA describes an encoding with an object, and accepts only 24 kHz for audio/pcm —
        // which is what keeps `VoiceAudioFormat.pcm16Mono24k` the right wire format.
        for side in ["input", "output"] {
            let format = try XCTUnwrap((audio[side] as? [String: Any])?["format"] as? [String: Any],
                                       "\(side) needs a format object, not a bare string")
            XCTAssertEqual(format["type"] as? String, "audio/pcm")
            XCTAssertEqual(format["rate"] as? Int, 24_000)
        }
        XCTAssertEqual((audio["output"] as? [String: Any])?["voice"] as? String, "cedar",
                       "GA moved the voice under audio.output")

        let transcription = try XCTUnwrap(try inputAudio(session)["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String,
                       RealtimeDefaults.inputTranscriptionModel,
                       "without input transcription the grammar has nothing to match")
    }

    func testSessionUpdateOmitsUnsetOptionalFields() throws {
        let json = try object(
            try RealtimeClientEvent.sessionUpdate(RealtimeSessionConfiguration()).encodedFrame())
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])

        XCTAssertNil(session["instructions"])
        XCTAssertNil((audio["output"] as? [String: Any])?["voice"],
                     "unset settings stay at the service default")
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
        // GA nests it under the input audio config; Beta carried it flat on the session.
        let detection = try XCTUnwrap(try inputAudio(session)["turn_detection"] as? [String: Any])

        XCTAssertEqual(detection["type"] as? String, "server_vad")
        XCTAssertEqual(detection["create_response"] as? Bool, false,
                       "the service may end a turn; it may never author a sentence")
        XCTAssertEqual(detection["interrupt_response"] as? Bool, false,
                       "barge-in stays with the IMU, which knows who spoke")
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

    func testDecodesResponseCompletion() throws {
        XCTAssertEqual(try RealtimeServerEvent.decode(RealtimeFrame.responseDone),
                       .responseCompleted)
    }

    /// The Beta names for the two response events are gone, not aliased.
    ///
    /// Keeping them would read as a compatibility promise to an API that no longer answers,
    /// and would quietly mask the next rename the way this one was masked: a session that
    /// decodes an unknown audio event as `.unsupported` plays silence rather than failing.
    func testRetiredBetaEventNamesAreNotAccepted() throws {
        XCTAssertEqual(try RealtimeServerEvent.decode(#"{"type":"response.completed"}"#),
                       .unsupported("response.completed"))
        XCTAssertEqual(try RealtimeServerEvent.decode(#"{"type":"response.audio.delta"}"#),
                       .unsupported("response.audio.delta"))
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
