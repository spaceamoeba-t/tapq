import XCTest
@testable import TapQVoiceBackends

final class RealtimeMessagesTests: XCTestCase {

    private func object(_ frame: String) throws -> [String: Any] {
        let data = try XCTUnwrap(frame.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Client events

    func testAppendFramesBase64EncodeTheAudio() throws {
        let audio = Data([0x00, 0x01, 0xFE, 0xFF, 0x10, 0x20])
        let json = try object(try RealtimeClientEvent.appendInputAudio(audio).encodedFrame())

        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.append")
        let encoded = try XCTUnwrap(json["audio"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), audio, "audio survives the framing round-trip")
    }

    func testCommitIsABareFrame() throws {
        XCTAssertEqual(try RealtimeClientEvent.commitInputAudio.encodedFrame(),
                       #"{"type":"input_audio_buffer.commit"}"#)
    }

    /// The out-of-band reading, byte for byte (research §4.3): in no conversation, the text
    /// its one input item, audio only.
    func testTheOutOfBandResponseIsPinned() throws {
        let frame = try RealtimeClientEvent
            .createOutOfBandResponse(instructions: "Read it.", text: "Allowed.")
            .encodedFrame()
        XCTAssertEqual(frame, #"{"response":{"conversation":"none","input":[{"content":"#
                       + #"[{"text":"Allowed.","type":"input_text"}],"role":"user","type":"message"}],"#
                       + #""instructions":"Read it.","output_modalities":["audio"]},"#
                       + #""type":"response.create"}"#)
    }

    /// 03-9: a cancel names the response it means.
    func testACancelNamesItsResponse() throws {
        XCTAssertEqual(try RealtimeClientEvent.cancelResponse(id: "resp_7").encodedFrame(),
                       #"{"response_id":"resp_7","type":"response.cancel"}"#)
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
            .transcriptDelta(itemID: nil, delta: "yes"))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(RealtimeFrame.transcriptCompleted("yes go")),
            .transcriptCompleted(itemID: nil, transcript: "yes go"))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(
                RealtimeFrame.transcriptDelta("yes", itemID: "item_7")),
            .transcriptDelta(itemID: "item_7", delta: "yes"))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(
                RealtimeFrame.transcriptCompleted("yes go", itemID: "item_7")),
            .transcriptCompleted(itemID: "item_7", transcript: "yes go"))
    }

    /// The failed segment carries its item and the service's code, so the kernel can clear
    /// the one item rather than wait for a `completed` that never comes.
    func testDecodesAFailedTranscription() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(
                RealtimeFrame.transcriptFailed(itemID: "item_3", code: "audio_unintelligible")),
            .transcriptFailed(itemID: "item_3", reason: "audio_unintelligible"))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(
                #"{"type":"conversation.item.input_audio_transcription.failed","item_id":"i"}"#),
            .transcriptFailed(itemID: "i", reason: "unspecified"))
    }

    /// The VAD's two frames carry the item they belong to and the millisecond they name.
    func testDecodesTheServerVADFlow() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"type":"input_audio_buffer.speech_started"}"#),
            .speechStarted(itemID: nil, audioStartMs: nil))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(
                RealtimeFrame.speechStarted(itemID: "item_1", audioStartMs: 3412)),
            .speechStarted(itemID: "item_1", audioStartMs: 3412))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(
                RealtimeFrame.speechStopped(itemID: "item_1", audioEndMs: 4528)),
            .speechStopped(itemID: "item_1", audioEndMs: 4528))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(
                #"{"type":"input_audio_buffer.committed","item_id":"item_1"}"#),
            .inputAudioCommitted(itemID: "item_1"))
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

    func testDecodesTheServicesOwnSpokenTranscript() throws {
        let frame = """
        {"type":"response.output_audio_transcript.done","response_id":"resp_7",\
        "item_id":"item_4","output_index":0,"content_index":0,"transcript":"Allowed."}
        """
        XCTAssertEqual(try RealtimeServerEvent.decode(frame), .spokenTranscript("Allowed."))
    }

    /// 03-4: `response.done` says how the response ended, and why when it did not complete.
    func testDecodesTheResponseLifecycleWithItsStatus() throws {
        XCTAssertEqual(try RealtimeServerEvent.decode(RealtimeFrame.responseCreated(id: "resp_1")),
                       .responseCreated(id: "resp_1"))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(
                RealtimeFrame.responseDone(id: "resp_1", status: "completed")),
            .responseDone(id: "resp_1", status: "completed", reason: nil))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(RealtimeFrame.responseDone(
                id: "resp_2", status: "failed", reason: "inference_rate_limit_exceeded")),
            .responseDone(id: "resp_2", status: "failed",
                          reason: "inference_rate_limit_exceeded"))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(RealtimeFrame.responseDone(
                id: "resp_3", status: "incomplete", reason: "max_output_tokens")),
            .responseDone(id: "resp_3", status: "incomplete", reason: "max_output_tokens"))
        XCTAssertEqual(try RealtimeServerEvent.decode(#"{"type":"response.done"}"#),
                       .responseDone(id: nil, status: nil, reason: nil))
    }

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
        XCTAssertFalse(failure.isSessionExpired)
    }

    /// D4 is decided by the code, and only by the code.
    func testSessionExpiryIsRecognizedByItsCode() throws {
        let expired = RealtimeServerFailure(type: "invalid_request_error",
                                            code: "session_expired",
                                            message: "Your session hit the maximum duration")
        XCTAssertTrue(expired.isSessionExpired)
        let worded = RealtimeServerFailure(type: nil, code: "server_error",
                                           message: "session_expired")
        XCTAssertFalse(worded.isSessionExpired, "a message is not a code")
    }

    func testAuthorizationErrorsAreRecognized() throws {
        for code in ["invalid_api_key", "unauthorized"] {
            let event = try RealtimeServerEvent.decode(
                RealtimeFrame.error(message: "rejected", code: code))
            guard case .failure(let failure) = event else {
                return XCTFail("expected a failure event for \(code)")
            }
            XCTAssertTrue(failure.isAuthorization, code)
        }
    }

    // MARK: - Transport failures

    /// 03-8: the close code and reason ride in the failure when the peer sent a close frame.
    /// One whose reason names a refusal is one (2026-10-19): the 4000 measured in §8.1 is the
    /// service refusing the request, and a new connection would be refused the same way.
    func testAReceiveFailureCarriesThePeersCloseCodeAndReason() {
        struct Dropped: Error, CustomStringConvertible { var description: String { "ENOTCONN" } }
        XCTAssertEqual(
            RealtimeTransportFailure.receiveFailed(
                Dropped(), closeCode: 4000,
                closeReason: Data("invalid_request_error.missing_model".utf8)),
            .refused("close 4000 (invalid_request_error.missing_model): ENOTCONN",
                     authorization: false))
        XCTAssertEqual(
            RealtimeTransportFailure.receiveFailed(Dropped(), closeCode: 1001, closeReason: nil),
            .receiveFailed("close 1001: ENOTCONN"))
        XCTAssertEqual(
            RealtimeTransportFailure.receiveFailed(Dropped(), closeCode: 0, closeReason: nil),
            .receiveFailed("ENOTCONN"), "no close frame, no close code")
    }

    /// Only a refusal the peer stated is one: a recording ends on it. An upgrade answered
    /// 401 or 403 blames the credentials, 400 or 404 the request; a policy close (1008) or a
    /// reason naming a refusal's type is the service saying no. A 4xxx that names nothing,
    /// a 429, a 5xx stay the network's, which a recording outlives.
    func testARefusalIsOnlyWhatThePeerSaidWasOne() {
        struct Dropped: Error, CustomStringConvertible { var description: String { "bad response" } }
        XCTAssertEqual(
            RealtimeTransportFailure.receiveFailed(Dropped(), closeCode: 0, closeReason: nil,
                                                   httpStatus: 401),
            .refused("HTTP 401 at the upgrade: bad response", authorization: true))
        XCTAssertEqual(
            RealtimeTransportFailure.receiveFailed(Dropped(), closeCode: 0, closeReason: nil,
                                                   httpStatus: 403),
            .refused("HTTP 403 at the upgrade: bad response", authorization: true))
        XCTAssertEqual(
            RealtimeTransportFailure.receiveFailed(Dropped(), closeCode: 0, closeReason: nil,
                                                   httpStatus: 404),
            .refused("HTTP 404 at the upgrade: bad response", authorization: false))
        XCTAssertEqual(
            RealtimeTransportFailure.receiveFailed(Dropped(), closeCode: 1008, closeReason: nil),
            .refused("close 1008: bad response", authorization: false))
        XCTAssertEqual(
            RealtimeTransportFailure.receiveFailed(
                Dropped(), closeCode: 4001,
                closeReason: Data("authentication_error.invalid_api_key".utf8)),
            .refused("close 4001 (authentication_error.invalid_api_key): bad response",
                     authorization: true))
        XCTAssertEqual(
            RealtimeTransportFailure.receiveFailed(Dropped(), closeCode: 4000, closeReason: nil),
            .receiveFailed("close 4000: bad response"), "a 4xxx that names nothing")
        XCTAssertEqual(
            RealtimeTransportFailure.receiveFailed(Dropped(), closeCode: 0, closeReason: nil,
                                                   httpStatus: 429),
            .receiveFailed("bad response"), "a rate limit passes")
        XCTAssertEqual(
            RealtimeTransportFailure.receiveFailed(Dropped(), closeCode: 0, closeReason: nil,
                                                   httpStatus: 503),
            .receiveFailed("bad response"), "the service failing passes")
    }

    // MARK: - Tolerance

    func testUnknownEventTypesDecodeAsUnsupported() throws {
        XCTAssertEqual(try RealtimeServerEvent.decode(RealtimeFrame.unknownEvent),
                       .unsupported("rate_limits.updated"))
    }

    func testUnknownFieldsAreIgnored() throws {
        let frame = """
        {"type":"conversation.item.input_audio_transcription.delta","delta":"ok",\
        "event_id":"ev_9","item_id":"item_3","content_index":0,"logprobs":[{"token":"ok"}]}
        """
        XCTAssertEqual(try RealtimeServerEvent.decode(frame),
                       .transcriptDelta(itemID: "item_3", delta: "ok"))
    }

    func testMissingPayloadFieldsDegradeRatherThanThrow() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(
                #"{"type":"conversation.item.input_audio_transcription.completed"}"#),
            .transcriptCompleted(itemID: nil, transcript: ""))
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"type":"response.output_audio_transcript.done"}"#),
            .spokenTranscript(""))
    }

    func testFramesWithoutATypeAreMalformed() {
        for frame in [#"{"delta":"yes"}"#, "not json at all", ""] {
            XCTAssertThrowsError(try RealtimeServerEvent.decode(frame))
        }
    }

    func testErrorEventWithoutAnErrorBodyIsMalformed() {
        XCTAssertThrowsError(try RealtimeServerEvent.decode(#"{"type":"error"}"#))
    }
}
