import XCTest
import TapQContracts
import TapQKernel
import TapQVoiceIO
@testable import TapQVoiceBackends

/// `RealtimeSpeechInput` over a fake microphone and the hostile fake
/// transcription peer.
@MainActor
final class RealtimeSpeechInputTests: XCTestCase {

    @MainActor
    private final class FakeCapture: AudioCapturing {
        private(set) var starts = 0
        private(set) var stops = 0
        var startFailure: (any Error)?
        private var onBlock: (@MainActor (VoiceAudioChunk) -> Void)?
        private var onFailure: (@MainActor (AudioDeviceFailure) -> Void)?

        func start(onBlock: @escaping @MainActor (VoiceAudioChunk) -> Void,
                   onFailure: @escaping @MainActor (AudioDeviceFailure) -> Void) throws {
            starts += 1
            if let startFailure { throw startFailure }
            self.onBlock = onBlock
            self.onFailure = onFailure
        }

        func stop() { stops += 1 }

        func deliver(_ chunk: VoiceAudioChunk) { onBlock?(chunk) }
        func fail(_ failure: AudioDeviceFailure) { onFailure?(failure) }
    }

    private struct Refused: Error, CustomStringConvertible {
        var description: String { "the device refused" }
    }

    private struct Fixture {
        let input: RealtimeSpeechInput
        let log: StreamLog<SpeechInputEvent>
        let capture: FakeCapture
        let sink: RecordingSink
        let servers: [ScriptedRealtimeServer]
    }

    /// TapQ's span, as the player would report it; tests move it.
    private var span = VoiceSelfAudioActivity.silent

    private func makeFixture(hysteresis: TimeInterval = 0.6,
                             sessions: Int = 2) async throws -> Fixture {
        let servers = (0..<sessions).map { _ in ScriptedRealtimeServer() }
        servers.forEach { $0.expectsTranscriptionSession = true }
        let capture = FakeCapture()
        let sink = RecordingSink()
        var opened = 0
        let input = RealtimeSpeechInput(
            capture: capture,
            makeSession: {
                defer { opened += 1 }
                return RealtimeTranscriptionSession(
                    transport: servers[opened],
                    configuration: RealtimeSpeechInput.configuration(environment: [:],
                                                                     language: "en"))
            },
            selfAudio: { [unowned self] in self.span },
            hysteresis: hysteresis,
            diagnosticSink: sink)
        let log = StreamLog(input.events)
        try await input.open()
        return Fixture(input: input, log: log, capture: capture, sink: sink, servers: servers)
    }

    func testOpenHandshakesBeforeTheMicrophoneStarts() async throws {
        let server = ScriptedRealtimeServer()
        server.expectsTranscriptionSession = true
        server.acknowledgesSessionUpdate = false
        let capture = FakeCapture()
        let input = RealtimeSpeechInput(
            capture: capture,
            makeSession: { RealtimeTranscriptionSession(
                transport: server,
                configuration: RealtimeSpeechInput.configuration(environment: [:],
                                                                 language: nil)) },
            selfAudio: { .silent }, hysteresis: 0.6)
        let opening = Task { @MainActor in try await input.open() }

        await waitUntil { server.sentTypes == ["session.update"] }
        XCTAssertEqual(capture.starts, 0, "no audio before the session is stated")
        server.push(RealtimeFrame.sessionUpdated)
        try await opening.value
        XCTAssertEqual(capture.starts, 1)
        let input0 = ScriptedRealtimeServer.inputAudio(of: server.sessionConfiguration)
        XCTAssertEqual((input0?["transcription"] as? [String: Any])?["prompt"] as? String,
                       RealtimeSpeechInput.prompt)
    }

    /// `at` = the capture instant of the session's first sample + `audio_start_ms`.
    func testSpeechStartedCarriesTheItemAndItsCaptureInstant() async throws {
        let f = try await makeFixture()

        f.capture.deliver(pcm(at: 500))
        f.capture.deliver(pcm(at: 500.1))
        f.servers[0].speechStarted(itemID: "item_1", audioStartMs: 1500)
        f.servers[0].speechStopped(itemID: "item_1", audioEndMs: 2900)
        f.servers[0].push(RealtimeFrame.transcriptCompleted("Claude, run the tests.",
                                                            itemID: "item_1"))
        f.servers[0].speechStarted(itemID: "item_2")
        await waitUntil { f.log.events.count == 4 }

        XCTAssertEqual(f.log.events, [
            .speechStarted(itemID: "item_1", at: 501.5),
            .speechStopped(itemID: "item_1"),
            .utterance(itemID: "item_1", text: "Claude, run the tests."),
            .speechStarted(itemID: "item_2", at: nil),
        ])
    }

    /// Continuous feed: blocks overlapping TapQ's span plus the hysteresis go out as zeros
    /// of the same length, so the service's clock stays the capture clock.
    func testBlocksOverlappingTapQsVoiceAreSentAsZerosOfTheSameLength() async throws {
        let f = try await makeFixture(hysteresis: 0.45)
        span = VoiceSelfAudioActivity(startedAt: 500.25, stoppedAt: 500.5)

        for index in 0..<12 { f.capture.deliver(pcm(at: 500 + Double(index) / 10)) }
        await waitUntil { f.servers[0].appendedAudio.count == 12 }

        let appended = f.servers[0].appendedAudio
        XCTAssertEqual(appended.map(\.count), Array(repeating: 4_800, count: 12),
                       "2,400 samples per block, every block sent")
        let zeroed = appended.indices.filter { appended[$0].allSatisfy { $0 == 0 } }
        XCTAssertEqual(zeroed, Array(2...9),
                       "from the block TapQ starts in to the last one inside stop + 0.45 s")
        XCTAssertNotNil(f.sink.first("self_audio.zero_fill.began"))
        XCTAssertNotNil(f.sink.first("self_audio.zero_fill.ended"))
    }

    /// `audio_start_ms` includes 300 ms of prefix padding, so the hysteresis never goes
    /// below 0.4 s whatever the environment says.
    func testTheHysteresisIsAtLeastFourHundredMilliseconds() async throws {
        let f = try await makeFixture(hysteresis: 0.1)
        span = VoiceSelfAudioActivity(startedAt: 499, stoppedAt: 500)

        f.capture.deliver(pcm(at: 500.3))
        f.capture.deliver(pcm(at: 500.45))
        await waitUntil { f.servers[0].appendedAudio.count == 2 }

        XCTAssertTrue(f.servers[0].appendedAudio[0].allSatisfy { $0 == 0 })
        XCTAssertFalse(f.servers[0].appendedAudio[1].allSatisfy { $0 == 0 })
    }

    /// D4: `session_expired` is a rollover; `reopen()` opens a new session on the same
    /// capture, and the audio origin resets with it.
    func testSessionExpiredIsReportedAndReopenStartsANewSessionWithANewOrigin() async throws {
        let f = try await makeFixture()

        f.capture.deliver(pcm(at: 500))
        await waitUntil { f.servers[0].appendedAudio.count == 1 }
        f.servers[0].push(RealtimeFrame.error(message: "Your session hit the maximum duration",
                                              code: "session_expired"))
        await waitUntil { f.log.events == [.sessionExpired] }
        try await f.input.reopen()
        f.capture.deliver(pcm(at: 3_600))
        f.servers[1].speechStarted(itemID: "item_9", audioStartMs: 1_500)
        await waitUntil { f.log.events.count == 2 }

        XCTAssertEqual(f.log.events.last, .speechStarted(itemID: "item_9", at: 3_601.5))
        XCTAssertEqual(f.capture.starts, 1, "the same capture throughout")
        await waitUntil { f.servers[1].appendedAudio.count == 1 }
        XCTAssertEqual(f.servers[0].appendedAudio.count, 1)
    }

    func testAnyOtherErrorFrameFails() async throws {
        let f = try await makeFixture()

        f.servers[0].push(RealtimeFrame.error(message: "Internal error", code: "server_error"))
        await waitUntil { f.log.finished }

        XCTAssertEqual(f.log.events, [.failed(reason: "Internal error (server_error)")])
        XCTAssertEqual(f.capture.stops, 1)
    }

    func testAFailedSegmentIsUtteranceFailed() async throws {
        let f = try await makeFixture()

        f.servers[0].push(RealtimeFrame.transcriptFailed(itemID: "item_3",
                                                         code: "audio_unintelligible"))
        await waitUntil { !f.log.events.isEmpty }

        XCTAssertEqual(f.log.events,
                       [.utteranceFailed(itemID: "item_3", reason: "audio_unintelligible")])
    }

    /// gpt-4o-transcribe returned its prompt for a segment with no speech (live, 2026-10-11),
    /// and the kernel sent it to Codex as an instruction. The prompt, in any case or
    /// punctuation, is a failed segment; a sentence that only names the agents is not.
    func testATranscriptThatIsThePromptIsAFailedSegment() async throws {
        let f = try await makeFixture()

        f.servers[0].push(RealtimeFrame.transcriptCompleted(RealtimeSpeechInput.prompt, itemID: "item_1"))
        f.servers[0].push(RealtimeFrame.transcriptCompleted(
            "the speaker gives instructions to coding agents named Claude Claude Code and Codex "
                + "and to the chat assistants Claude chat and ChatGPT",
            itemID: "item_2"))
        f.servers[0].push(RealtimeFrame.transcriptCompleted(
            "Codex, tell the coding agents named Claude, Claude Code and Codex hello.", itemID: "item_3"))
        await waitUntil { f.log.events.count == 3 }

        XCTAssertEqual(f.log.events, [
            .utteranceFailed(itemID: "item_1", reason: RealtimeSpeechInput.promptEchoReason),
            .utteranceFailed(itemID: "item_2", reason: RealtimeSpeechInput.promptEchoReason),
            .utterance(itemID: "item_3",
                       text: "Codex, tell the coding agents named Claude, Claude Code and Codex hello."),
        ])
    }

    /// P2-9: "run the tests" then "stop" must not arrive reversed.
    func testResultsAreForwardedInCommitOrder() async throws {
        let f = try await makeFixture()

        for item in ["item_1", "item_2", "item_3"] {
            f.servers[0].push(RealtimeFrame.inputAudioCommitted(itemID: item))
        }
        f.servers[0].push(RealtimeFrame.transcriptCompleted("Claude, stop.", itemID: "item_3"))
        f.servers[0].push(RealtimeFrame.transcriptFailed(itemID: "item_2",
                                                         code: "audio_unintelligible"))
        f.servers[0].push(RealtimeFrame.transcriptCompleted("Claude, run the tests.",
                                                            itemID: "item_1"))
        await waitUntil { f.log.events.count == 3 }

        XCTAssertEqual(f.log.events, [
            .utterance(itemID: "item_1", text: "Claude, run the tests."),
            .utteranceFailed(itemID: "item_2", reason: "audio_unintelligible"),
            .utterance(itemID: "item_3", text: "Claude, stop."),
        ])
    }

    /// An expiry leaves no committed item without a result: a held one is released, one
    /// the dead session never transcribed fails.
    func testAnExpiryReleasesHeldResultsAndFailsTheRest() async throws {
        let f = try await makeFixture()

        f.servers[0].push(RealtimeFrame.inputAudioCommitted(itemID: "item_1"))
        f.servers[0].push(RealtimeFrame.inputAudioCommitted(itemID: "item_2"))
        f.servers[0].push(RealtimeFrame.transcriptCompleted("Codex, stop.", itemID: "item_2"))
        f.servers[0].push(RealtimeFrame.error(message: "Your session hit the maximum duration",
                                              code: "session_expired"))
        await waitUntil { f.log.events.count == 3 }

        XCTAssertEqual(f.log.events, [
            .utteranceFailed(itemID: "item_1", reason: "the session ended before it was transcribed"),
            .utterance(itemID: "item_2", text: "Codex, stop."),
            .sessionExpired,
        ])
        try await f.input.reopen()
        f.servers[1].push(RealtimeFrame.inputAudioCommitted(itemID: "item_3"))
        f.servers[1].push(RealtimeFrame.transcriptCompleted("Claude, go.", itemID: "item_3"))
        await waitUntil { f.log.events.count == 4 }
        XCTAssertEqual(f.log.events.last, .utterance(itemID: "item_3", text: "Claude, go."),
                       "nothing of the dead session holds the new one back")
    }

    func testAnItemlessTranscriptFails() async throws {
        let f = try await makeFixture()

        f.servers[0].push(RealtimeFrame.transcriptCompleted("Claude, stop."))
        await waitUntil { f.log.finished }

        XCTAssertEqual(f.log.events,
                       [.failed(reason: "the service named no item for a transcript")])
    }

    /// D7: a route change restarts the capture; the gap it leaves is sent as zeros, so the
    /// service's clock stays the capture clock.
    func testAConfigurationChangeRestartsTheCaptureAndFillsTheGap() async throws {
        let f = try await makeFixture()

        f.capture.deliver(pcm(at: 500))
        f.capture.fail(.configurationChanged)
        f.capture.deliver(pcm(at: 500.35, byte: 0x22))
        await waitUntil { f.servers[0].appendedAudio.reduce(0) { $0 + $1.count } == 21_600 }

        XCTAssertEqual(f.capture.stops, 1)
        XCTAssertEqual(f.capture.starts, 2)
        XCTAssertNotNil(f.sink.first("capture.reopened"))
        let sent = f.servers[0].appendedAudio.reduce(Data(), +)
        XCTAssertTrue(sent.prefix(4_800).allSatisfy { $0 == 0x11 })
        XCTAssertTrue(sent.dropFirst(4_800).prefix(12_000).allSatisfy { $0 == 0 },
                      "0.25 s of gap is 6,000 samples of zeros")
        XCTAssertTrue(sent.suffix(4_800).allSatisfy { $0 == 0x22 })
        XCTAssertTrue(f.log.events.isEmpty)
    }

    func testARestartThatThrowsFails() async throws {
        let f = try await makeFixture()

        f.capture.startFailure = Refused()
        f.capture.fail(.configurationChanged)
        await waitUntil { f.log.finished }

        XCTAssertEqual(f.log.events, [.failed(
            reason: "the microphone could not be reopened after a route change: the device refused")])
    }

    func testAnUnavailableMicrophoneFails() async throws {
        let f = try await makeFixture()

        f.capture.fail(.unavailable("engine_start: gone"))
        await waitUntil { f.log.finished }

        XCTAssertEqual(f.log.events,
                       [.failed(reason: "the microphone is unavailable: engine_start: gone")])
    }

    /// 07-2: judged on the bytes the microphone delivered.
    func testDigitalSilenceFails() async throws {
        let f = try await makeFixture()

        for index in 0..<60 { f.capture.deliver(pcm(at: 500 + Double(index) / 10, byte: 0)) }
        await waitUntil { f.log.finished }

        XCTAssertEqual(f.log.events, [.failed(reason: "microphone delivers only silence")])
    }

    /// TapQ's own zero-fill is not the microphone's silence: a long reading must not trip it.
    func testZeroFilledBlocksDoNotCountAsSilence() async throws {
        let f = try await makeFixture()
        span = VoiceSelfAudioActivity(startedAt: 499, stoppedAt: nil)

        for index in 0..<60 { f.capture.deliver(pcm(at: 500 + Double(index) / 10)) }
        await waitUntil { f.servers[0].appendedAudio.count == 60 }

        XCTAssertTrue(f.log.events.isEmpty)
    }

    /// 07-10: a socket that stopped draining fails the input once the backlog passes 2 MB.
    func testAnOutboundBacklogFails() async throws {
        let f = try await makeFixture()
        f.servers[0].stallsSends = true
        f.capture.deliver(pcm(at: 499, seconds: 1))
        await waitUntil { f.servers[0].parkedSends == 1 }

        // Forty more seconds of audio is ~2.6 MB queued behind the send that never returns.
        for second in 0..<40 { f.capture.deliver(pcm(at: 500 + Double(second), seconds: 1)) }
        await waitUntil { f.log.finished }

        guard case .failed(let reason) = f.log.events.last else {
            return XCTFail("expected a failure, got \(f.log.events)")
        }
        XCTAssertTrue(reason.contains("outbound queue"))
    }

    // MARK: - Long capture gaps (2026-10-20)

    /// Another app holds the microphone for minutes: zeros for that gap would pass the outbound
    /// cap and fail the session, so the session rolls over as at its expiry and the kernel
    /// reopens it. A short gap is still filled.
    func testAGapTooLongForZerosRollsTheSessionOver() async throws {
        let f = try await makeFixture()

        f.capture.deliver(pcm(at: 500))
        f.capture.fail(.configurationChanged)
        f.capture.deliver(pcm(at: 500 + RealtimeSpeechInput.maximumZeroFill + 5, byte: 0x22))
        await waitUntil { f.log.events.count == 1 }

        XCTAssertEqual(f.log.events, [.sessionExpired])
        let sent = f.servers[0].appendedAudio.reduce(Data(), +)
        XCTAssertFalse(sent.contains(0), "no zeros for the gap")
        XCTAssertLessThanOrEqual(sent.count, 4_800)
        XCTAssertEqual(f.sink.first("capture.gap_rollover")?.fields["gap_ms"], "14900",
                       "from the end of the last block to the next")

        try await f.input.reopen()
        f.capture.deliver(pcm(at: 516, byte: 0x33))
        await waitUntil { !f.servers[1].appendedAudio.isEmpty }
        XCTAssertTrue(f.servers[1].appendedAudio.reduce(Data(), +).allSatisfy { $0 == 0x33 },
                      "the new session starts its clock at the next block")
    }
}
