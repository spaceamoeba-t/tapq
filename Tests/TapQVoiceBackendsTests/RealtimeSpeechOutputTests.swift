import XCTest
import TapQContracts
import TapQKernel
@testable import TapQVoiceIO
@testable import TapQVoiceBackends

/// `RealtimeSpeechOutput` over the hostile fake peer and a player
/// whose drain the test reports by hand.
@MainActor
final class RealtimeSpeechOutputTests: XCTestCase {

    @MainActor
    private final class FakePlayer: VoiceResponseAudioPlaying {
        private(set) var enqueued: [VoiceAudioChunk] = []
        private(set) var flushes = 0
        private(set) var finishes = 0
        private var drainReport: (@MainActor (VoiceResponseStreamEnding) -> Void)?

        var awaitsDrain: Bool { drainReport != nil }

        func enqueue(_ chunk: VoiceAudioChunk) { enqueued.append(chunk) }
        func finishStream(onDrained: (@MainActor (VoiceResponseStreamEnding) -> Void)?) {
            finishes += 1
            if let onDrained { drainReport = onDrained }
        }
        func stopAndFlush() { flushes += 1 }

        func drain(_ ending: VoiceResponseStreamEnding = .playedBack) {
            let report = drainReport
            drainReport = nil
            report?(ending)
        }
    }

    private final class Clock {
        var now: TimeInterval = 1_000
    }

    private struct Fixture {
        let output: RealtimeSpeechOutput
        let log: StreamLog<SpeechOutputEvent>
        let player: FakePlayer
        let clock: Clock
        let sleeps: ManualSleeps
        let sink: RecordingSink
        /// One peer per session, in the order the output opens them.
        let servers: [ScriptedRealtimeServer]
    }

    private func makeFixture(sessions: Int = 2) async throws -> Fixture {
        let servers = (0..<sessions).map { _ in ScriptedRealtimeServer() }
        servers.forEach { $0.expectsSpeechSession = true }
        let player = FakePlayer()
        let clock = Clock()
        let sleeps = ManualSleeps()
        let sink = RecordingSink()
        var opened = 0
        let output = RealtimeSpeechOutput(
            makeSession: {
                defer { opened += 1 }
                return RealtimeSpeechSession(transport: servers[opened], sleep: sleeps.sleep)
            },
            player: player,
            monotonicNow: { clock.now },
            diagnosticSink: sink)
        let log = StreamLog(output.events)
        try await output.open()
        return Fixture(output: output, log: log, player: player, clock: clock, sleeps: sleeps,
                       sink: sink, servers: servers)
    }

    private let one = SpeechID(raw: 1)

    /// Answers the active reading on `server` with `audio`, its transcript and `status`.
    private func answer(_ server: ScriptedRealtimeServer, saying transcript: String,
                        audio: Data = Data([1, 0, 2, 0]), status: String = "completed",
                        creates: Int = 1) async {
        await waitUntil { server.sentFrames(ofType: "response.create").count == creates }
        server.push(RealtimeFrame.audioDelta(audio))
        server.push(RealtimeFrame.spokenTranscript(transcript))
        server.finishResponse(status: status, reason: status == "completed" ? nil : "boom")
    }

    func testDeltasReachThePlayerAndADrainedReadingIsPlayedVerbatim() async throws {
        let f = try await makeFixture()

        f.output.speak("Allowed.", id: one)
        await answer(f.servers[0], saying: "Allowed.", audio: Data([7, 0, 8, 0]))
        await waitUntil { f.player.awaitsDrain }
        XCTAssertEqual(f.player.enqueued.map(\.data), [Data([7, 0, 8, 0])])
        XCTAssertEqual(f.player.enqueued.first?.format, .pcm16Mono24k)
        XCTAssertEqual(f.log.events, [.started(one)], "nothing is played before the drain")

        f.clock.now = 1_004.5
        f.player.drain()
        await waitUntil { f.log.events.count == 2 }

        XCTAssertEqual(f.log.events, [.started(one),
                                      .played(one, at: 1_004.5, verbatim: true)])
    }

    /// The words go to `.debug` only: the warning says that a reading was a paraphrase,
    /// never what was said.
    func testAParaphraseIsPlayedButNotVerbatimAndLogged() async throws {
        let f = try await makeFixture()

        f.output.speak("Claude Code wants to run npm install. Allow it?", id: one)
        await answer(f.servers[0], saying: "Claude Code would like to install npm. Allow it?")
        await waitUntil { f.player.awaitsDrain }
        f.player.drain()
        await waitUntil { f.log.events.count == 2 }

        XCTAssertEqual(f.log.events.last, .played(one, at: 1_000, verbatim: false))
        let warning = try XCTUnwrap(f.sink.first("tts.paraphrase"))
        XCTAssertEqual(warning.level, .warning)
        XCTAssertEqual(warning.fields, ["id": "1"])
        let text = try XCTUnwrap(f.sink.first("tts.paraphrase.text"))
        XCTAssertEqual(text.level, .debug)
        XCTAssertEqual(text.fields["input"], "claude code wants to run npm install allow it")
        XCTAssertEqual(text.fields["heard"], "claude code would like to install npm allow it")
        XCTAssertEqual(text.fields["id"], "1")
    }

    /// 03-4.
    func testAFailedOrIncompleteResponseFailsTheItem() async throws {
        for status in ["failed", "incomplete"] {
            let f = try await makeFixture()

            f.output.speak("Allowed.", id: one)
            await answer(f.servers[0], saying: "Allowed.", status: status)
            await waitUntil { f.log.events.count == 2 }

            XCTAssertEqual(f.log.events.last,
                           .failed(one, reason: "the response ended \(status) (boom)"))
        }
    }

    func testAStalledResponseFailsTheItem() async throws {
        let f = try await makeFixture()

        f.output.speak("Allowed.", id: one)
        await waitUntil {
            f.sleeps.fireAll()
            return f.log.events.count == 2
        }

        XCTAssertEqual(f.log.events.last,
                       .failed(one, reason: "the response sent no frame for 10 s"))
    }

    /// P1-1: the output route changed under the reading (AirPods connecting). The player
    /// reports it `.flushed`; the item is read again from its start on the same session,
    /// and `played` comes once, for the complete reading.
    func testARouteChangeSpeaksTheItemAgainFromItsStart() async throws {
        let f = try await makeFixture()

        f.output.speak("Allowed.", id: one)
        await answer(f.servers[0], saying: "Allowed, I think.", audio: Data([1, 0]))
        await waitUntil { f.player.awaitsDrain }
        f.player.drain(.flushed)
        await answer(f.servers[0], saying: "Allowed.", audio: Data([2, 0]), creates: 2)
        await waitUntil { f.player.awaitsDrain }
        f.player.drain()
        await waitUntil { f.log.events.count == 2 }

        XCTAssertEqual(f.log.events, [.started(one), .played(one, at: 1_000, verbatim: true)],
                       "the kernel hears nothing of the first reading, paraphrase included")
        XCTAssertEqual(f.player.enqueued.map(\.data), [Data([1, 0]), Data([2, 0])])
        XCTAssertEqual(f.player.finishes, 2)
        let read = f.servers[0].sentFrames(ofType: "response.create")
            .compactMap { ($0["response"] as? [String: Any]).flatMap(ScriptedRealtimeServer.readText(of:)) }
        XCTAssertEqual(read, ["Allowed.", "Allowed."])
        XCTAssertEqual(f.servers[0].closeCount, 0, "the voice is not reopened")
    }

    func testAPlayerFailureFailsTheItem() async throws {
        let f = try await makeFixture()

        f.output.speak("Allowed.", id: one)
        await answer(f.servers[0], saying: "Allowed.")
        await waitUntil { f.player.awaitsDrain }
        f.player.drain(.failed)
        await waitUntil { f.log.events.count == 2 }

        XCTAssertEqual(f.log.events.last, .failed(one, reason: "the player failed"))
    }

    /// A read-all over 2,000 characters: consecutive responses under one id, one player
    /// stream, and `verbatim` the AND of the parts.
    func testALongItemIsSpokenInPartsUnderOneID() async throws {
        let f = try await makeFixture()
        let sentence = "Claude Code said the build is green and the tests pass. "
        let text = String(repeating: sentence, count: 60).trimmingCharacters(in: .whitespaces)
        let parts = RealtimeSpeechOutput.parts(of: text)
        XCTAssertEqual(parts.count, 2)

        f.output.speak(text, id: one)
        await answer(f.servers[0], saying: parts[0])
        await answer(f.servers[0], saying: "The build is green.", creates: 2)
        await waitUntil { f.player.awaitsDrain }
        f.player.drain()
        await waitUntil { f.log.events.count == 2 }

        let read = f.servers[0].sentFrames(ofType: "response.create")
            .compactMap { ($0["response"] as? [String: Any]).flatMap(ScriptedRealtimeServer.readText(of:)) }
        XCTAssertEqual(read, parts)
        XCTAssertEqual(f.player.finishes, 1, "one stream for the whole item")
        XCTAssertEqual(f.log.events, [.started(one), .played(one, at: 1_000, verbatim: false)],
                       "one paraphrased part makes the item a paraphrase")
    }

    /// D4: the session that expired mid-item is replaced, and the item is spoken again
    /// from its start; the kernel hears nothing of it.
    func testAnExpiryMidItemReopensAndSpeaksTheItemAgain() async throws {
        let f = try await makeFixture()

        f.output.speak("Allowed.", id: one)
        await waitUntil { f.servers[0].currentResponseID != nil }
        f.servers[0].push(RealtimeFrame.audioDelta(Data([1, 0])))
        f.servers[0].push(RealtimeFrame.error(message: "Your session hit the maximum duration",
                                              code: "session_expired"))
        await answer(f.servers[1], saying: "Allowed.", audio: Data([2, 0]))
        await waitUntil { f.player.awaitsDrain }
        f.player.drain()
        await waitUntil { f.log.events.count == 2 }

        XCTAssertEqual(f.player.flushes, 1, "the cut-off half is not left to play")
        XCTAssertEqual(f.player.enqueued.map(\.data), [Data([1, 0]), Data([2, 0])])
        XCTAssertEqual(f.player.finishes, 1, "the flush ended the cut-off stream")
        XCTAssertEqual(f.log.events, [.started(one), .played(one, at: 1_000, verbatim: true)])
        XCTAssertEqual(f.servers[0].closeCount, 1)
    }

    func testAnExpiryWhileIdleIsReplacedBeforeTheNextItem() async throws {
        let f = try await makeFixture()

        f.servers[0].push(RealtimeFrame.error(message: "expired", code: "session_expired"))
        await waitUntil { f.servers[1].sentTypes.contains("session.update") }
        f.output.speak("Allowed.", id: one)
        await answer(f.servers[1], saying: "Allowed.")
        await waitUntil { f.player.awaitsDrain }
        f.player.drain()
        await waitUntil { f.log.events.count == 2 }

        XCTAssertEqual(f.log.events.last, .played(one, at: 1_000, verbatim: true))
        XCTAssertTrue(f.servers[0].sentFrames(ofType: "response.create").isEmpty)
    }

    func testAnyOtherCloseFailsTheItem() async throws {
        let f = try await makeFixture()

        f.output.speak("Allowed.", id: one)
        await waitUntil { f.servers[0].currentResponseID != nil }
        f.servers[0].disconnect()
        await waitUntil { f.log.events.count == 2 }

        guard case .failed(one, let reason) = f.log.events.last else {
            return XCTFail("expected the item to fail, got \(f.log.events)")
        }
        XCTAssertTrue(reason.contains("socket dropped"))
    }

    /// A voice that died while idle has no item to fail; the next one fails at once.
    func testAVoiceThatDiedWhileIdleFailsTheNextItem() async throws {
        let f = try await makeFixture()

        f.servers[0].hangUp()
        await waitUntil { f.servers[0].closeCount == 1 }
        f.output.speak("Allowed.", id: one)
        await waitUntil { f.log.events.count == 2 }

        XCTAssertEqual(f.log.events, [.started(one),
                                      .failed(one, reason: "the peer closed the session")])
    }

    /// 03-9: shutdown cancels the active response by its id, flushes, and says nothing more.
    func testCancelNamesTheResponseFlushesAndReportsNothingMore() async throws {
        let f = try await makeFixture()

        f.output.speak("A long read-all.", id: one)
        await waitUntil { f.servers[0].currentResponseID != nil }
        f.output.cancel()
        await waitUntil { !f.servers[0].sentFrames(ofType: "response.cancel").isEmpty }
        await waitUntil { f.log.finished }

        XCTAssertEqual(f.servers[0].sentFrames(ofType: "response.cancel").first?["response_id"]
                           as? String, "resp_1")
        XCTAssertEqual(f.player.flushes, 1)
        XCTAssertEqual(f.log.events, [.started(one)])
    }
}
