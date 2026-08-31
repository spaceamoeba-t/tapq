import XCTest
import Foundation
@testable import TapQVoiceBackends
import TapQContracts
@testable import TapQInteractionBaseline

/// TapQ answering itself, and the one number that separates that from a wearer answering.
///
/// The defect these are built from (hardware, 2026-08-30, `--voice-backend openai-realtime`
/// with no AirPods): TapQ speaks an answer through the Mac's speaker, the microphone reopens
/// as the last of it drains, the service's semantic VAD hears the tail and calls it the
/// wearer's turn, the commit that follows produces an empty transcript, and the empty-turn
/// rescue asks the model to act on the audio anyway — so the model, handed its own voice as
/// the wearer's, says the same thing again. After a beat of silence, forever.
///
/// What must survive is the rescue itself. The same empty-transcript path is how a real
/// question whose transcription lagged or came back blank still gets answered, and the log
/// this fix came from contains both shapes minutes apart. So the two halves of this file are
/// deliberately the same script with one number changed: how long ago TapQ's own audio
/// stopped.
///
/// The playback double is drain-aware on purpose. A double that went idle the moment the
/// response completed could not reproduce this bug at all — the whole shape of it is that
/// `response.done` arrives while seconds of audio are still sitting in the player, so the
/// window that opens next opens *into* TapQ's own voice.
@MainActor
final class RealtimeSelfAudioTests: XCTestCase {
    // MARK: - Doubles

    /// A monotonic clock the test moves by hand, shared by the adapter and the player so the
    /// two are comparing instants on one timeline.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval

        init(_ start: TimeInterval = 1_000) { self.value = start }

        var now: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            value += seconds
            lock.unlock()
        }
    }

    /// A response-audio player that takes as long to play audio as the audio lasts.
    ///
    /// `finishStream()` does *not* make it idle — that is the point. A real player is handed
    /// a whole response's audio in a fraction of the time it takes to say it, so the moment
    /// the response completes on the wire is the middle of the sentence in the room. Only
    /// `drain()` ends it, and it advances the clock by the audio's own duration on the way.
    @MainActor
    private final class DrainAwarePlayback: VoiceResponseAudioPlaying {
        private let clock: TestClock
        private(set) var isPlaying = false
        var onPlayingChange: (@MainActor (Bool) -> Void)?
        private(set) var selfAudioActivity: VoiceSelfAudioActivity = .silent
        private(set) var queuedSeconds: TimeInterval = 0
        private var streamFinished = false

        init(clock: TestClock) { self.clock = clock }

        func enqueue(_ chunk: VoiceAudioChunk) {
            if !isPlaying {
                streamFinished = false
                isPlaying = true
                selfAudioActivity = VoiceSelfAudioActivity(startedAt: clock.now, stoppedAt: nil)
                onPlayingChange?(true)
            }
            let bytesPerFrame = max(1, 2 * chunk.format.channels)
            queuedSeconds += Double(chunk.data.count / bytesPerFrame) / chunk.format.sampleRate
        }

        func finishStream() { streamFinished = true }

        func stopAndFlush() {
            queuedSeconds = 0
            goIdle()
        }

        /// Plays out everything queued: the clock moves by the audio's own length, and only
        /// then does the room go quiet.
        func drain() {
            clock.advance(queuedSeconds)
            queuedSeconds = 0
            goIdle()
        }

        private func goIdle() {
            guard isPlaying else { return }
            isPlaying = false
            selfAudioActivity = VoiceSelfAudioActivity(
                startedAt: selfAudioActivity.startedAt ?? clock.now, stoppedAt: clock.now)
            onPlayingChange?(false)
        }
    }

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

        func first(_ name: String) -> TapQDiagnosticEvent? { events.first { $0.name == name } }
    }

    @MainActor
    private final class EventLog {
        private(set) var events: [VoiceBackendEvent] = []
        func append(_ event: VoiceBackendEvent) { events.append(event) }
        var committedByBackend: Int {
            events.filter {
                if case .userAudioCommittedByBackend = $0 { return true } else { return false }
            }.count
        }
        var failures: [VoiceBackendFailure] {
            events.compactMap { if case .sessionFailed(let f) = $0 { return f } else { return nil } }
        }
    }

    // MARK: - Fixtures

    private static let hysteresis: TimeInterval = 0.6

    private func settle() async {
        for _ in 0..<12 { await Task.yield() }
    }

    private func pcm16(_ frames: Int) -> VoiceAudioChunk {
        VoiceAudioChunk(data: Data(repeating: 0x11, count: frames * 2),
                        format: OpenAIRealtimeVoiceBackend.audioFormat, timestamp: 0)
    }

    /// The adapter alone, with a clock and a player the test drives.
    private func makeBackend(_ server: ScriptedRealtimeServer,
                             clock: TestClock,
                             playback: DrainAwarePlayback?,
                             sink: RecordingSink = RecordingSink())
        -> OpenAIRealtimeVoiceBackend {
        let backend = OpenAIRealtimeVoiceBackend(
            transport: server,
            timeout: 1,
            turnEagerness: .low,
            selfAudioHysteresis: Self.hysteresis,
            monotonicNow: { clock.now },
            diagnosticSink: sink
        )
        if let playback {
            backend.selfAudioActivity = { [weak playback] in
                playback?.selfAudioActivity ?? .silent
            }
        }
        return backend
    }

    /// The stack the bug lives in: the real provider, on the real adapter, on a scripted
    /// peer, with a drain-aware player underneath.
    private struct Stack {
        let server: ScriptedRealtimeServer
        let realtime: OpenAIRealtimeVoiceBackend
        let playback: DrainAwarePlayback
        let provider: VoiceBackendCommandProvider
        let clock: TestClock
        let sink: RecordingSink
    }

    private func makeStack() -> Stack {
        let clock = TestClock()
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let playback = DrainAwarePlayback(clock: clock)
        let realtime = makeBackend(server, clock: clock, playback: playback, sink: sink)
        let provider = VoiceBackendCommandProvider(
            backend: realtime,
            intentSource: .modelToolCalls,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            responseAudio: playback,
            // The whole premise: no AirPods, so no wearer turn signal, so the service's own
            // VAD decides where sentences end and TapQ's voice reaches its own microphone.
            isWearerTurnSignalLive: { false },
            // Bounded, so the timer this leaves behind cannot stall the next test.
            idleSleep: { _ in try? await Task.sleep(for: .seconds(1)) },
            diagnosticSink: sink
        )
        return Stack(server: server, realtime: realtime, playback: playback,
                     provider: provider, clock: clock, sink: sink)
    }

    /// One whole answer in TapQ's own voice: requested, streamed, completed on the wire —
    /// and still sounding in the room when this returns.
    private func speakAnswer(_ stack: Stack, seconds: TimeInterval = 3) async {
        stack.provider.speakScripted("Codex finished the refactor.")
        await settle()
        let id = try? XCTUnwrap(stack.server.currentResponseID)
        stack.server.push(RealtimeFrame.audioDelta(
            Data(repeating: 0x22, count: Int(seconds * 24_000) * 2)))
        await settle()
        stack.server.push(RealtimeFrame.responseDone(id: id ?? "resp_1"))
        await settle()
    }

    private func responseCreateCount(_ stack: Stack) -> Int {
        stack.server.sentFrames(ofType: "response.create").count
    }

    // MARK: - The stack, as the hardware ran it

    /// The defect, end to end: the window that opens as TapQ's answer drains must not turn
    /// the tail of that answer into a question TapQ asks itself.
    ///
    /// Every step here is one line of the 2026-08-30 log, in order — the scripted sentence,
    /// the response completing while the audio is still playing, the microphone reopening on
    /// the drain, and the service reporting speech a beat later. The assertion is the line
    /// that must *not* appear after it: a second `response.create`, which is the model turn
    /// whose answer the wearer heard as a repeat.
    func testTheEchoOfTapQsOwnAnswerNeverBecomesAModelTurn() async {
        let stack = makeStack()
        stack.provider.start { _ in }
        await settle()
        stack.provider.stopUnresolved()
        await settle()

        await speakAnswer(stack)
        let afterSpeaking = responseCreateCount(stack)

        // The player finally drains — the clock moves by the length of the sentence — and
        // the gate reopens the microphone into a room that is still ringing.
        stack.playback.drain()
        stack.provider.start { _ in }
        await settle()
        XCTAssertTrue(stack.provider.isUserTurnActiveForCoordination,
                      "the window under test is the one that opens on the drain")

        // A beat later, the service reports the tail as the wearer's utterance.
        stack.clock.advance(0.2)
        stack.server.reportServerVADUtterance(itemID: "item_echo")
        await settle()

        XCTAssertEqual(responseCreateCount(stack), afterSpeaking,
                       "TapQ asked the model to act on its own voice")
        XCTAssertTrue(stack.sink.names.contains("native_turn.suppressed_self_audio"))
        XCTAssertFalse(stack.sink.names.contains("turn.model_turn_requested"))
        XCTAssertTrue(stack.provider.isUserTurnActiveForCoordination,
                      "the wearer's microphone stays open: nothing of theirs happened here")
    }

    /// The same script with one number changed: the wearer speaks well after the room went
    /// quiet, and the rescue that answers them is untouched.
    func testAWearersTurnAfterTheDrainStillReachesTheModel() async {
        let stack = makeStack()
        stack.provider.start { _ in }
        await settle()
        stack.provider.stopUnresolved()
        await settle()

        await speakAnswer(stack)
        let afterSpeaking = responseCreateCount(stack)

        stack.playback.drain()
        stack.provider.start { _ in }
        await settle()

        // Two full seconds of silence — far past the echo hysteresis — and then a wearer.
        stack.clock.advance(2)
        stack.server.reportServerVADUtterance(itemID: "item_wearer")
        await settle()

        XCTAssertEqual(responseCreateCount(stack), afterSpeaking + 1,
                       "the empty-transcript rescue is what answers a question whose "
                        + "transcription lagged, and it must survive this fix")
        XCTAssertTrue(stack.sink.names.contains("turn.model_turn_requested"))
        XCTAssertFalse(stack.sink.names.contains("native_turn.suppressed_self_audio"))
        XCTAssertFalse(stack.server.sentTypes.contains("conversation.item.delete"),
                       "nothing the wearer said is deleted from the conversation")
    }

    /// A segment TapQ recognized as its own voice does not get to stay in the conversation
    /// either: a model handed it as context a window later answers it a window later.
    func testTheSuppressedSegmentIsDeletedFromTheConversation() async {
        let stack = makeStack()
        stack.provider.start { _ in }
        await settle()
        stack.provider.stopUnresolved()
        await settle()
        await speakAnswer(stack)
        stack.playback.drain()
        stack.provider.start { _ in }
        await settle()

        stack.clock.advance(0.2)
        stack.server.reportServerVADUtterance(itemID: "item_echo")
        await settle()

        let deletes = stack.server.sentFrames(ofType: "conversation.item.delete")
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(deletes.first?["item_id"] as? String, "item_echo")
        XCTAssertEqual(stack.sink.first("native_turn.suppressed_self_audio")?
            .fields["item_deleted"], "true")
    }

    // MARK: - The rule, at the adapter

    /// Speech the service heard entirely inside TapQ's own playback is TapQ, and the caller
    /// never hears about the commit.
    func testSpeechEntirelyInsidePlaybackIsSuppressed() async throws {
        let clock = TestClock()
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let playback = DrainAwarePlayback(clock: clock)
        let backend = makeBackend(server, clock: clock, playback: playback, sink: sink)
        let events = EventLog()
        backend.setNativeTurnDetection(true)
        try await backend.open { events.append($0) }
        backend.beginUserTurn()
        await settle()

        playback.enqueue(pcm16(24_000))  // a second of TapQ's own voice, still sounding
        clock.advance(0.3)
        server.reportServerVADUtterance()
        await settle()

        XCTAssertEqual(events.committedByBackend, 0)
        XCTAssertEqual(events.failures, [])
        XCTAssertEqual(backend.turnStateForTesting, .userTurn,
                       "suppressing a segment must not disturb the turn it arrived in")
        let suppressed = try XCTUnwrap(sink.first("native_turn.suppressed_self_audio"))
        XCTAssertEqual(suppressed.fields["count"], "1")
        XCTAssertEqual(suppressed.fields["hysteresis_ms"], "600")
    }

    /// The hysteresis is what covers the room and the reporting lag, and it has two sides.
    func testTheHysteresisBoundaryDecidesTheAmbiguousCase() async throws {
        for (gap, expectSuppressed) in [(0.5, true), (0.9, false)] {
            let clock = TestClock()
            let server = ScriptedRealtimeServer()
            let sink = RecordingSink()
            let playback = DrainAwarePlayback(clock: clock)
            let backend = makeBackend(server, clock: clock, playback: playback, sink: sink)
            let events = EventLog()
            backend.setNativeTurnDetection(true)
            try await backend.open { events.append($0) }
            backend.beginUserTurn()
            await settle()

            playback.enqueue(pcm16(24_000))
            playback.drain()
            clock.advance(gap)
            server.reportServerVADUtterance()
            await settle()

            XCTAssertEqual(events.committedByBackend, expectSuppressed ? 0 : 1,
                           "a gap of \(gap)s against a \(Self.hysteresis)s hysteresis")
            XCTAssertEqual(sink.names.contains("native_turn.suppressed_self_audio"),
                           expectSuppressed)
        }
    }

    /// Speech that began before TapQ did is the wearer's, whatever landed on top of it.
    ///
    /// The fail direction, stated as a test. TapQ talking over a wearer who was already
    /// speaking costs them an interruption; TapQ dropping that turn as its own echo costs
    /// them the question, and on a run with no screen they have no way to discover which
    /// happened.
    func testSpeechThatBeganBeforeTapQSpokeIsTheWearers() async throws {
        let clock = TestClock()
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let playback = DrainAwarePlayback(clock: clock)
        let backend = makeBackend(server, clock: clock, playback: playback, sink: sink)
        let events = EventLog()
        backend.setNativeTurnDetection(true)
        try await backend.open { events.append($0) }
        backend.beginUserTurn()
        await settle()

        // The wearer starts talking into a quiet room.
        server.push(#"{"type":"input_audio_buffer.speech_started"}"#)
        await settle()
        // TapQ starts speaking over them, and is still speaking when they stop.
        playback.enqueue(pcm16(24_000))
        clock.advance(0.4)
        server.push(#"{"type":"input_audio_buffer.speech_stopped"}"#)
        server.commitFromServerVAD()
        await settle()

        XCTAssertEqual(events.committedByBackend, 1)
        XCTAssertFalse(sink.names.contains("native_turn.suppressed_self_audio"))
    }

    /// A composition that wires no player suppresses nothing at all — every existing test,
    /// and any host with no backend playback, behaves exactly as it did.
    func testWithNoPlayerWiredNothingIsEverSuppressed() async throws {
        let clock = TestClock()
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let backend = makeBackend(server, clock: clock, playback: nil, sink: sink)
        let events = EventLog()
        backend.setNativeTurnDetection(true)
        try await backend.open { events.append($0) }
        backend.beginUserTurn()
        await settle()

        server.reportServerVADUtterance()
        await settle()

        XCTAssertEqual(events.committedByBackend, 1)
        XCTAssertFalse(sink.names.contains("native_turn.suppressed_self_audio"))
    }

    /// The AirPods path is untouched. With a wearer turn signal live TapQ owns turns, the
    /// service makes no commits at all, and a manual turn cycle runs through playback
    /// exactly as it always has.
    func testTheManualTurnPathIsUnchangedWhileTapQIsSpeaking() async throws {
        let clock = TestClock()
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let playback = DrainAwarePlayback(clock: clock)
        let backend = makeBackend(server, clock: clock, playback: playback, sink: sink)
        let events = EventLog()
        try await backend.open { events.append($0) }
        backend.beginUserTurn()
        await settle()

        playback.enqueue(pcm16(24_000))
        backend.sendAudio(pcm16(2_400))
        await settle()
        XCTAssertTrue(backend.endUserTurn(expectingResponse: true),
                      "manual turns commit and ask for a response regardless of playback")
        await settle()

        XCTAssertTrue(server.sentTypes.contains("input_audio_buffer.commit"))
        XCTAssertTrue(server.sentTypes.contains("response.create"))
        XCTAssertFalse(sink.names.contains("native_turn.suppressed_self_audio"))
        XCTAssertEqual(events.failures, [])
    }

    /// A delete the service refuses is housekeeping that did not land, not a dead channel.
    func testARefusedDeleteDoesNotEndTheSession() async throws {
        let clock = TestClock()
        let server = ScriptedRealtimeServer()
        let sink = RecordingSink()
        let playback = DrainAwarePlayback(clock: clock)
        let backend = makeBackend(server, clock: clock, playback: playback, sink: sink)
        let events = EventLog()
        backend.setNativeTurnDetection(true)
        try await backend.open { events.append($0) }
        backend.beginUserTurn()
        await settle()

        playback.enqueue(pcm16(24_000))
        clock.advance(0.2)
        server.reportServerVADUtterance(itemID: "item_echo")
        await settle()
        server.push(#"""
            {"type":"error","error":{"type":"invalid_request_error",\#
            "code":"item_not_found","message":"no such item"}}
            """#)
        await settle()

        XCTAssertEqual(events.failures, [], "a refused delete must not take voice down")
        XCTAssertTrue(sink.names.contains("item_delete.refused"))
        XCTAssertNotEqual(backend.turnStateForTesting, .idle)
    }

    /// And the absorption is exactly one error wide: the next one is the session-ending
    /// protocol failure it has always been.
    func testASecondErrorAfterADeleteStillEndsTheSession() async throws {
        let clock = TestClock()
        let server = ScriptedRealtimeServer()
        let playback = DrainAwarePlayback(clock: clock)
        let backend = makeBackend(server, clock: clock, playback: playback)
        let events = EventLog()
        backend.setNativeTurnDetection(true)
        try await backend.open { events.append($0) }
        backend.beginUserTurn()
        await settle()

        playback.enqueue(pcm16(24_000))
        clock.advance(0.2)
        server.reportServerVADUtterance(itemID: "item_echo")
        await settle()
        let failure = #"{"type":"error","error":{"type":"server_error","message":"boom"}}"#
        server.push(failure)
        await settle()
        server.push(failure)
        await settle()

        XCTAssertEqual(events.failures.count, 1)
    }

    /// The tuning knob, and the composition line an operator reads it back from.
    func testTheHysteresisIsResolvedFromTheEnvironmentAndReported() async {
        XCTAssertEqual(VoiceSelfAudioEcho.resolvedHysteresis(environment: [:]),
                       VoiceSelfAudioEcho.defaultHysteresis)
        XCTAssertEqual(
            VoiceSelfAudioEcho.resolvedHysteresis(
                environment: [VoiceSelfAudioEcho.hysteresisEnvironmentKey: "350"]),
            0.35, accuracy: 0.0001)
        XCTAssertEqual(
            VoiceSelfAudioEcho.resolvedHysteresis(
                environment: [VoiceSelfAudioEcho.hysteresisEnvironmentKey: "not a number"]),
            VoiceSelfAudioEcho.defaultHysteresis,
            "a mistyped knob must not be why a wearer's only channel refuses to start")
        XCTAssertEqual(
            VoiceSelfAudioEcho.resolvedHysteresis(
                environment: [VoiceSelfAudioEcho.hysteresisEnvironmentKey: "999999"]),
            VoiceSelfAudioEcho.maximumHysteresis,
            "a hysteresis that long is a microphone that ignores the wearer")
        XCTAssertEqual(
            VoiceSelfAudioEcho.resolvedHysteresis(
                environment: [VoiceSelfAudioEcho.hysteresisEnvironmentKey: "-5"]), 0)

        let clock = TestClock()
        let sink = RecordingSink()
        _ = makeBackend(ScriptedRealtimeServer(), clock: clock, playback: nil, sink: sink)
        XCTAssertEqual(sink.first("turn_detection.configured")?
            .fields["self_audio_hysteresis_ms"], "600")
    }

    /// The span's own arithmetic, including the two ends it deliberately treats differently.
    func testAudibilitySpansExtendForwardOnly() async {
        let sounding = VoiceSelfAudioActivity(startedAt: 10, stoppedAt: nil)
        XCTAssertTrue(sounding.isSounding)
        XCTAssertTrue(sounding.wasAudible(at: 10, hysteresis: 0.5))
        XCTAssertTrue(sounding.wasAudible(at: 9_999, hysteresis: 0.5))
        XCTAssertFalse(sounding.wasAudible(at: 9.9, hysteresis: 0.5),
                       "nothing before TapQ started speaking can be TapQ")

        let past = VoiceSelfAudioActivity(startedAt: 10, stoppedAt: 12)
        XCTAssertFalse(past.isSounding)
        XCTAssertTrue(past.wasAudible(at: 12.4, hysteresis: 0.5))
        XCTAssertFalse(past.wasAudible(at: 12.6, hysteresis: 0.5))
        XCTAssertFalse(past.wasAudible(at: 12.4, hysteresis: 0),
                       "a hysteresis of nothing is the raw span")

        XCTAssertFalse(VoiceSelfAudioActivity.silent.wasAudible(at: 0, hysteresis: 10),
                       "a run whose voice has never played has no echo to suppress")
    }
}
