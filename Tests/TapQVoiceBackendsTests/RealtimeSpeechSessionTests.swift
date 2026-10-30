import XCTest
import TapQContracts
@testable import TapQVoiceBackends

/// The TTS wire: an output-only session, one out-of-band
/// response per reading, and every way a reading can end.
@MainActor
final class RealtimeSpeechSessionTests: XCTestCase {

    private func open(_ server: ScriptedRealtimeServer,
                      sleeps: ManualSleeps = ManualSleeps())
        async throws -> (RealtimeSpeechSession, StreamLog<RealtimeSpeechEvent>) {
        server.expectsSpeechSession = true
        let session = RealtimeSpeechSession(transport: server, sleep: sleeps.sleep)
        let log = StreamLog(session.events)
        try await session.open()
        return (session, log)
    }

    func testTheSessionIsOutputOnly() async throws {
        let server = ScriptedRealtimeServer()
        _ = try await open(server)

        let session = try XCTUnwrap(server.sessionConfiguration)
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["model"] as? String, "gpt-realtime-2.1-mini")
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual(output["voice"] as? String, "cedar")
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        XCTAssertTrue((audio["input"] as? [String: Any])?["turn_detection"] is NSNull)
        XCTAssertEqual(Set(session.keys), ["type", "model", "output_modalities", "audio"],
                       "no tools, no instructions")
    }

    func testAReadingIsOneOutOfBandResponse() async throws {
        let server = ScriptedRealtimeServer()
        let (session, _) = try await open(server)

        session.speak("Allowed.")
        await waitUntil { !server.sentFrames(ofType: "response.create").isEmpty }

        let response = try XCTUnwrap(
            server.sentFrames(ofType: "response.create").first?["response"] as? [String: Any])
        XCTAssertEqual(response["instructions"] as? String, RealtimeSpeechSession.readerInstructions)
        XCTAssertEqual(response["conversation"] as? String, "none")
        XCTAssertEqual(ScriptedRealtimeServer.readText(of: response), "Allowed.")
        XCTAssertEqual(response["output_modalities"] as? [String], ["audio"])
        XCTAssertEqual(Set(response.keys),
                       ["conversation", "input", "instructions", "output_modalities"])
    }

    func testAudioTranscriptAndDoneAreReportedInOrder() async throws {
        let server = ScriptedRealtimeServer()
        let (session, log) = try await open(server)
        let audio = Data([1, 2, 3, 4])

        session.speak("Allowed.")
        await waitUntil { server.currentResponseID != nil }
        server.push(RealtimeFrame.audioDelta(audio))
        server.push(RealtimeFrame.spokenTranscript("Allowed."))
        server.finishResponse()
        await waitUntil { log.events.count == 3 }

        XCTAssertEqual(log.events, [.audio(audio), .transcript("Allowed."), .done])
        XCTAssertFalse(log.finished)
    }

    /// 03-4: a response that did not complete is a voice that failed.
    func testAFailedOrIncompleteResponseEndsTheSession() async throws {
        for (status, reason) in [("failed", "inference_rate_limit_exceeded"),
                                 ("incomplete", "max_output_tokens")] {
            let server = ScriptedRealtimeServer()
            let (session, log) = try await open(server)

            session.speak("Allowed.")
            await waitUntil { server.currentResponseID != nil }
            server.finishResponse(status: status, reason: reason)
            await waitUntil { log.finished }

            XCTAssertEqual(log.events,
                           [.failed(reason: "the response ended \(status) (\(reason))")])
            XCTAssertEqual(server.closeCount, 1)
        }
    }

    func testAStalledResponseEndsTheSession() async throws {
        let server = ScriptedRealtimeServer()
        let sleeps = ManualSleeps()
        let (session, log) = try await open(server, sleeps: sleeps)

        session.speak("Allowed.")
        await waitUntil {
            sleeps.fireAll()
            return log.finished
        }

        XCTAssertEqual(log.events, [.failed(reason: "the response sent no frame for 10 s")])
    }

    func testTheBoundEndsWithTheResponse() async throws {
        let server = ScriptedRealtimeServer()
        let sleeps = ManualSleeps()
        let (session, log) = try await open(server, sleeps: sleeps)

        session.speak("Allowed.")
        await waitUntil { server.currentResponseID != nil }
        server.finishResponse()
        await waitUntil { log.events == [.done] }
        sleeps.fireAll()
        session.speak("Denied.")
        await waitUntil { server.sentFrames(ofType: "response.create").count == 2 }

        XCTAssertEqual(log.events, [.done], "an idle session has no bound to miss")
        XCTAssertFalse(log.finished)
    }

    /// D4: the cap is a planned end, reported as such.
    func testSessionExpiredEndsTheSessionAsExpired() async throws {
        let server = ScriptedRealtimeServer()
        let (session, log) = try await open(server)
        defer { session.close() }

        server.push(RealtimeFrame.error(message: "Your session hit the maximum duration",
                                        code: "session_expired"))
        await waitUntil { log.finished }

        XCTAssertEqual(log.events, [.expired])
    }

    func testAnyOtherErrorFrameFails() async throws {
        let server = ScriptedRealtimeServer()
        let (session, log) = try await open(server)
        defer { session.close() }

        server.push(RealtimeFrame.error(message: "Internal error", code: "server_error"))
        await waitUntil { log.finished }

        XCTAssertEqual(log.events, [.failed(reason: "Internal error (server_error)")])
    }

    func testAPeerThatHangsUpFails() async throws {
        let server = ScriptedRealtimeServer()
        let (session, log) = try await open(server)
        defer { session.close() }

        server.hangUp()
        await waitUntil { log.finished }

        XCTAssertEqual(log.events, [.failed(reason: "the peer closed the session")])
    }

    /// 03-9: the cancel names the response, and nothing of it is reported afterwards.
    func testCancelNamesTheResponseAndSilencesTheRest() async throws {
        let server = ScriptedRealtimeServer()
        let (session, log) = try await open(server)

        session.speak("A long read-all.")
        await waitUntil { server.currentResponseID != nil }
        session.cancel()
        await waitUntil { !server.sentFrames(ofType: "response.cancel").isEmpty }
        server.push(RealtimeFrame.audioDelta(Data([9, 9])))
        server.finishResponse(status: "cancelled")
        session.close()
        await waitUntil { log.finished }

        XCTAssertEqual(server.sentFrames(ofType: "response.cancel").first?["response_id"]
                           as? String, "resp_1")
        XCTAssertEqual(log.events, [])
    }

    func testAnUnacknowledgedHandshakeIsBounded() async throws {
        let server = ScriptedRealtimeServer()
        server.acknowledgesSessionUpdate = false
        server.expectsSpeechSession = true
        let sleeps = ManualSleeps()
        let session = RealtimeSpeechSession(transport: server, sleep: sleeps.sleep)
        let opened = StreamLog(AsyncStream<VoiceBackendFailure?> { continuation in
            Task { @MainActor in
                do {
                    try await session.open()
                    continuation.yield(nil)
                } catch {
                    continuation.yield(error as? VoiceBackendFailure)
                }
                continuation.finish()
            }
        })

        await waitUntil {
            sleeps.fireAll()
            return opened.finished
        }

        XCTAssertEqual(opened.events,
                       [.network("the speech handshake timed out after 10 s")])
        XCTAssertEqual(server.closeCount, 1)
    }
}
