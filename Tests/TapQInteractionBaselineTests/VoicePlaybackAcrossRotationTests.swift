import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// The 2026-08-29 hardware defect, and the boundaries of the rule that fixes it.
///
/// The report, twice on hardware under `--voice-backend openai-realtime --voice-session`:
/// the wearer asked TapQ a question, the model began answering in voice, and the answer was
/// cut off mid-sentence. The log said why in five lines — `tool.model_turn_requested`,
/// `listening.paused`, `playback.engine_started`, `listen.resolved intent=none`,
/// `window.closed` — and the fourth is the whole of it: the eight-second window's own idle
/// timer came round while the player was still draining, and the window ending flushed it.
///
/// Two things made it invisible to the 2026-08-28 suppression fix. The answer is
/// `.wearerTurn`, not `.scripted`, so the exemption written for TapQ's own sentences did not
/// cover it. And the response was usually already *settled* on the wire —
/// `response.suppression_skipped_settled reason=nothing_pending` — with seconds of audio
/// still queued locally, so nothing keyed on `_responseInFlight` would have caught it either.
///
/// The rule these tests fix in place: a window that ends because nothing resolved it is a
/// clock, not an audience leaving. Every *other* way a window ends keeps the behavior it has
/// always had, which is what the second half of this file is about.
@MainActor
final class VoicePlaybackAcrossRotationTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock(); storage.append(event); lock.unlock()
        }

        var names: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage.map(\.name)
        }

        func count(_ name: String) -> Int { names.filter { $0 == name }.count }

        func fields(_ name: String) -> [[String: String]] {
            lock.lock(); defer { lock.unlock() }
            return storage.filter { $0.name == name }.map(\.fields)
        }
    }

    /// The realtime adapter's shape: duplex, tool-calling, barge-in capable, and able to end
    /// the wearer's turn from its own VAD — the only capabilities under which the trace's
    /// `userAudioCommittedByBackend` → `requestModelTurn` path exists at all.
    @MainActor
    private final class RealtimeBackend: VoiceBackend {
        let capabilities = VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                    duplex: true,
                                                    supportsNativeTurnDetection: true,
                                                    supportsToolCalling: true)

        var activeResponseIdentity: String?
        private(set) var isOpen = false
        private(set) var isTurnActive = false
        private(set) var turnsBegun = 0
        private(set) var cancels = 0
        private(set) var modelTurnRequests = 0
        private(set) var scriptedSpeech: [String] = []
        private var handler: (@MainActor (VoiceBackendEvent) -> Void)?

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            handler = onEvent
            isOpen = true
        }

        func close() {
            handler = nil
            isOpen = false
            isTurnActive = false
        }

        func beginUserTurn() {
            isTurnActive = true
            turnsBegun += 1
        }

        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool {
            isTurnActive = false
            if expectingResponse { activeResponseIdentity = "resp_turn_\(turnsBegun)" }
            return expectingResponse
        }

        func sendAudio(_ chunk: VoiceAudioChunk) {}
        func requestResponse(text: String) { activeResponseIdentity = "resp_grounded" }

        func requestScriptedSpeech(text: String) {
            scriptedSpeech.append(text)
            activeResponseIdentity = "resp_scripted_\(scriptedSpeech.count)"
        }

        func cancelResponse() {
            cancels += 1
            activeResponseIdentity = nil
        }

        func setNativeTurnDetection(_ enabled: Bool) {}

        @discardableResult
        func requestModelTurn() -> Bool {
            modelTurnRequests += 1
            activeResponseIdentity = "resp_model_\(modelTurnRequests)"
            return true
        }

        func declareTools(_ tools: [VoiceToolDeclaration]) {}
        func updateInstructions(_ instructions: String) {}
        func sendToolResult(callID: String, output: String) {}

        func emit(_ event: VoiceBackendEvent) { handler?(event) }

        /// The peer finishing a response: it forgets the id, then sends the terminal frame.
        func completeResponse() {
            activeResponseIdentity = nil
            emit(.responseCompleted)
        }
    }

    /// A player that behaves like `BackendAudioPlayback` in the one respect this file turns
    /// on: `isPlaying` rises inside the first `enqueue` and stays up through `finishStream()`
    /// until the buffers actually drain. That gap — response over, audio not yet heard — is
    /// where the defect lived.
    @MainActor
    private final class FakePlayback: VoiceResponseAudioPlaying {
        private(set) var isPlaying = false
        var onPlayingChange: (@MainActor (Bool) -> Void)?
        private(set) var enqueued = 0
        private(set) var finishStreamCount = 0
        private(set) var stopAndFlushCount = 0

        func enqueue(_ chunk: VoiceAudioChunk) {
            enqueued += 1
            guard !isPlaying else { return }
            isPlaying = true
            onPlayingChange?(true)
        }

        func finishStream() { finishStreamCount += 1 }

        func stopAndFlush() {
            stopAndFlushCount += 1
            guard isPlaying else { return }
            isPlaying = false
            onPlayingChange?(false)
        }

        /// The last scheduled buffer completing after `finishStream()` — the only legitimate
        /// way the player goes quiet on its own.
        func completeDrain() {
            guard isPlaying else { return }
            isPlaying = false
            onPlayingChange?(false)
        }
    }

    /// A voice channel that only records which of the two endings it was given.
    @MainActor
    private final class ReasonRecordingVoice: VoiceCommandProviding {
        var onCommand: (@MainActor (VoiceCommand) -> Void)?
        private(set) var stops = 0
        private(set) var unresolvedStops = 0

        func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {
            self.onCommand = onCommand
        }

        func stop() { stops += 1 }
        func stopUnresolved() { unresolvedStops += 1 }
        func fire(_ command: VoiceCommand) { onCommand?(command) }
    }

    @MainActor
    private final class FakeSpeechActivity: SpeechActivitySignaling {
        private(set) var isSpeaking = false
        var onSpeakingChange: (@MainActor (Bool) -> Void)?

        func setSpeaking(_ value: Bool) {
            guard value != isSpeaking else { return }
            isSpeaking = value
            onSpeakingChange?(value)
        }
    }

    private func makeProvider(_ backend: RealtimeBackend,
                              playback: FakePlayback,
                              sink: RecordingSink) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            intentSource: .modelToolCalls,
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            responseAudio: playback,
            // Bounded rather than the shipped sixty seconds: an unbounded sleep left running
            // in-process stalls whichever test runs next.
            idleSleep: { _ in try? await Task.sleep(for: .seconds(1)) },
            diagnosticSink: sink)
    }

    private func settle() async { for _ in 0..<6 { await Task.yield() } }

    private func chunk() -> VoiceAudioChunk {
        VoiceAudioChunk(data: Data([0, 1, 2, 3]), format: .pcm16Mono24k, timestamp: 0)
    }

    /// The trace up to the moment of the defect: the wearer's sentence is committed by the
    /// backend's own VAD, TapQ asks the model to act on it, and the answer starts playing
    /// while the gate pauses listening for it.
    private func answerTheWearer(_ backend: RealtimeBackend,
                                 _ provider: VoiceBackendCommandProvider,
                                 chunks: Int = 1) async {
        backend.emit(.userAudioCommittedByBackend)
        backend.emit(.transcriptFinal("what is claude waiting on"))
        // `SpeechGatedVoice` pauses the moment the first chunk raises `isPlaying`; in a
        // provider-level test the pause is stated directly, in the same order the log shows.
        provider.pauseListening()
        for _ in 0..<chunks { backend.emit(.audio(chunk())) }
        await settle()
    }

    // MARK: - (a) The hardware trace

    /// The report itself: the response has settled, seconds of it are still in the player,
    /// and the eight-second window rotates.
    ///
    /// `response.suppression_skipped_settled reason=nothing_pending` is the line from the log
    /// that proves gating on `_responseInFlight` could never have fixed this — by the time the
    /// window rotated there was nothing in flight to gate on, only audio nobody had heard yet.
    func testASettledAnswerSurvivesAnIdleWindowRotation() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        defer { provider.shutdown() }

        provider.start { _ in }
        await settle()
        XCTAssertEqual(backend.modelTurnRequests, 0)
        await answerTheWearer(backend, provider, chunks: 3)
        XCTAssertEqual(backend.modelTurnRequests, 1, "the model was asked to answer the wearer")
        XCTAssertEqual(playback.enqueued, 3)

        // The peer delivers a sentence far faster than it takes to say it: `response.done`
        // lands while every sample is still queued.
        backend.completeResponse()
        await settle()
        XCTAssertEqual(playback.finishStreamCount, 1)
        XCTAssertTrue(playback.isPlaying, "the player is still draining the answer")

        // And now the clock comes round with nobody having said or done anything.
        provider.stopUnresolved()

        XCTAssertEqual(playback.stopAndFlushCount, 0,
                       "the window's own timer flushed the model's answer out of the player")
        XCTAssertTrue(playback.isPlaying, "the answer must keep playing across the rotation")
        XCTAssertEqual(backend.cancels, 0)
        XCTAssertTrue(sink.names.contains("playback.survives_rotation"))
        XCTAssertEqual(sink.fields("playback.survives_rotation").first?["playing"], "true")
        // The window still rotated: surviving playback must not hold a window open.
        XCTAssertFalse(provider.isWindowOpenForTesting)
        XCTAssertTrue(provider.isSessionOpenForTesting, "the conversation session outlives it")
    }

    /// The other half of the same trace: the rotation lands while chunks are still arriving.
    ///
    /// Skipping the flush is only half a fix here. With no handler, no pause and nothing
    /// scripted, every remaining chunk used to be dropped as `audio.dropped_no_window` — the
    /// answer would stop at whatever had already been buffered, which from the wearer's side
    /// is the same truncated sentence with a quieter log.
    func testAStreamingAnswerKeepsReachingThePlayerAcrossARotation() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        defer { provider.shutdown() }

        provider.start { _ in }
        await settle()
        await answerTheWearer(backend, provider, chunks: 2)
        XCTAssertEqual(playback.enqueued, 2)

        provider.stopUnresolved()
        XCTAssertEqual(playback.stopAndFlushCount, 0)
        XCTAssertEqual(backend.cancels, 0, "a clock must not cancel the answer")

        // The rest of the sentence arrives after the window it belonged to is gone.
        backend.emit(.audio(chunk()))
        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 4,
                       "the tail of the answer was dropped after the rotation")
        XCTAssertFalse(sink.names.contains("audio.dropped_no_window"))

        backend.completeResponse()
        await settle()
        XCTAssertEqual(playback.finishStreamCount, 1)
    }

    /// A rotation arms nothing. A suppression mark armed by a timer would fire on the first
    /// audio of the answer the wearer is waiting for — the same silence by a different door.
    func testARotationArmsNoSuppressionAgainstTheAnswer() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        defer { provider.shutdown() }

        provider.start { _ in }
        await settle()
        // The coordinator endpoints the wearer's turn: a response exists, no audio yet.
        provider.endActiveTurn()

        provider.stopUnresolved()
        XCTAssertEqual(sink.count("response.suppression_armed"), 0,
                       "a timed-out window armed suppression against the wearer's answer")

        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 1, "the answer's first audio was suppressed")
        XCTAssertEqual(backend.cancels, 0)
        XCTAssertFalse(sink.names.contains("response.suppressed_on_first_audio"))
    }

    /// An answer already speaking when the clock comes round is not cancelled either.
    func testARotationDoesNotCancelAnAudibleAnswer() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        defer { provider.shutdown() }

        provider.start { _ in }
        await settle()
        provider.endActiveTurn()
        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 1)

        provider.stopUnresolved()
        XCTAssertEqual(backend.cancels, 0,
                       "the window's timer cancelled a response that was mid-sentence")
        XCTAssertEqual(playback.stopAndFlushCount, 0)
        XCTAssertFalse(sink.names.contains("response.suppressed_match_resolved"))
    }

    /// A rotation over a silent player says nothing. The diagnostic is there to explain a
    /// sentence that outlived its window, and one line per eight seconds of silence would
    /// bury the ones that mean something.
    func testARotationOverASilentPlayerIsNotRecorded() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        defer { provider.shutdown() }

        provider.start { _ in }
        await settle()
        provider.stopUnresolved()

        XCTAssertFalse(sink.names.contains("playback.survives_rotation"))
        XCTAssertFalse(provider.isWindowOpenForTesting)
    }

    // MARK: - (b) TapQ's own voice, unchanged

    /// The 2026-08-28 rule still holds on its own path: a window the *wearer* resolved does
    /// not flush TapQ's scripted sentence, and says so by name.
    func testScriptedSpeechStillSurvivesAWearerResolvedWindow() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        defer { provider.shutdown() }

        provider.start { _ in }
        await settle()
        provider.stop()
        XCTAssertEqual(provider.speakScripted("Claude is waiting on a Bash command."), .spoken)
        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 1)

        provider.start { _ in }
        await settle()
        let flushesBefore = playback.stopAndFlushCount
        provider.stop()
        XCTAssertEqual(playback.stopAndFlushCount, flushesBefore)
        XCTAssertTrue(sink.names.contains("playback.flush_skipped_scripted"))
    }

    /// And it survives a rotation too — by the rotation's rule rather than the scripted one,
    /// which is why the diagnostic differs.
    func testScriptedSpeechAlsoSurvivesARotation() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        defer { provider.shutdown() }

        provider.start { _ in }
        await settle()
        provider.stop()
        XCTAssertEqual(provider.speakScripted("Claude finished the tests."), .spoken)
        backend.emit(.audio(chunk()))

        provider.start { _ in }
        await settle()
        // Counted from here: the `stop()` that opened the gap for this sentence flushed an
        // already-idle player on its way past, which is a no-op the fake still counts.
        let flushesBefore = playback.stopAndFlushCount
        provider.stopUnresolved()

        XCTAssertEqual(playback.stopAndFlushCount, flushesBefore)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(sink.fields("playback.survives_rotation").last?["origin"], "scripted")
    }

    // MARK: - (c) Wearer-resolved windows keep every behavior they had

    /// The case the suppression mechanism exists for, restated next to its opposite: a
    /// window the wearer resolved still abandons the answer it no longer wants.
    func testAWearerResolvedWindowStillCancelsAndFlushesTheAnswer() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        defer { provider.shutdown() }

        provider.start { _ in }
        await settle()
        provider.endActiveTurn()
        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 1)

        provider.stop()
        XCTAssertEqual(backend.cancels, 1)
        XCTAssertGreaterThan(playback.stopAndFlushCount, 0)
        XCTAssertTrue(sink.names.contains("response.suppressed_match_resolved"))
    }

    /// The pending half: a mark is still armed and still spent on that response's first
    /// audio when the wearer resolved the window.
    func testAWearerResolvedWindowStillArmsAgainstAPendingAnswer() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        defer { provider.shutdown() }

        provider.start { _ in }
        await settle()
        provider.endActiveTurn()
        provider.stop()
        XCTAssertEqual(sink.count("response.suppression_armed"), 1)

        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, 0, "a suppressed response must not be played")
        XCTAssertEqual(backend.cancels, 1)
    }

    /// A rotation's permission belongs to the response it was granted for, and to that
    /// window's successor only until the wearer resolves one. It must not accumulate into a
    /// standing licence for audio with no window anywhere.
    func testTheRotationPermissionDoesNotOutliveItsResponse() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        defer { provider.shutdown() }

        provider.start { _ in }
        await settle()
        await answerTheWearer(backend, provider)
        provider.stopUnresolved()
        backend.completeResponse()
        await settle()
        playback.completeDrain()

        // A wholly new wearer-turn response, created with no window open and nothing to
        // protect it: the ordinary drop rule applies again.
        let enqueuedBefore = playback.enqueued
        backend.emit(.audio(chunk()))
        XCTAssertEqual(playback.enqueued, enqueuedBefore,
                       "the rotation's permission leaked onto a later response")
        XCTAssertTrue(sink.names.contains("audio.dropped_no_window"))
    }

    // MARK: - (d) Teardown

    /// The session dying is a different fact from a window ending, and it still takes the
    /// player with it — including a player that a rotation had just let keep going.
    func testShutdownStillFlushesAnAnswerThatSurvivedARotation() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)

        provider.start { _ in }
        await settle()
        await answerTheWearer(backend, provider)
        provider.stopUnresolved()
        XCTAssertEqual(playback.stopAndFlushCount, 0)

        provider.shutdown()
        XCTAssertGreaterThan(playback.stopAndFlushCount, 0,
                             "teardown must still empty the player")
        XCTAssertFalse(playback.isPlaying)
        XCTAssertFalse(provider.isSessionOpenForTesting)
    }

    // MARK: - (e) Barge-in

    /// The wearer talking over an answer that survived a rotation still cuts it. Barge-in is
    /// origin-blind and stays that way: the rule is about a clock silencing TapQ, never about
    /// the wearer interrupting.
    func testBargeInStillCutsAnAnswerThatSurvivedARotation() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        defer { provider.shutdown() }

        provider.start { _ in }
        await settle()
        await answerTheWearer(backend, provider)
        provider.stopUnresolved()
        XCTAssertTrue(playback.isPlaying)

        provider.cancelActiveResponse()
        XCTAssertEqual(backend.cancels, 1)
        XCTAssertFalse(playback.isPlaying, "barge-in must flush what is queued")
        XCTAssertTrue(sink.names.contains("response.cancelled_by_coordinator"))
    }

    // MARK: - (f) The microphone the surviving audio must not reach

    /// The reason invariant (1) is safe on speaker-and-built-in-mic hardware: the next
    /// window's microphone is held shut for as long as the answer is still sounding.
    ///
    /// This is the composed path — `SpeechGatedVoice(CombinedSpeechActivity(tts, playback),
    /// provider)`, exactly as `AppleTapQRuntimeService` builds it — because the hold is the
    /// gate's, not the provider's, and it only engages if the player is still busy when the
    /// next window opens. Before the fix the flush made it idle first, and the log showed
    /// `microphone.reopened` → `mic.opened` → `window.started` immediately after every
    /// rotation, with the answer's own audio arriving at the recognizer.
    func testTheNextWindowsMicrophoneWaitsForTheAnswerToDrain() async {
        let backend = RealtimeBackend()
        let playback = FakePlayback()
        let sink = RecordingSink()
        let provider = makeProvider(backend, playback: playback, sink: sink)
        defer { provider.shutdown() }
        let tts = FakeSpeechActivity()
        let activity = CombinedSpeechActivity(tts: tts, playback: playback)
        let gated = SpeechGatedVoice(wrapping: provider, activity: activity,
                                     diagnosticSink: sink)

        gated.start { _ in }
        await settle()
        XCTAssertTrue(backend.isTurnActive)

        // The wearer's question is answered; the gate pauses on the first chunk.
        backend.emit(.userAudioCommittedByBackend)
        backend.emit(.audio(chunk()))
        await settle()
        XCTAssertTrue(playback.isPlaying)
        XCTAssertFalse(backend.isTurnActive, "the model turn ended the wearer's turn")

        // The clock comes round mid-answer and the loop opens its next window.
        gated.stopUnresolved()
        let turnsBefore = backend.turnsBegun
        gated.start { _ in }
        await settle()

        XCTAssertTrue(sink.names.contains("microphone.held_closed"),
                      "the next window opened a microphone into TapQ's own answer")
        XCTAssertEqual(backend.turnsBegun, turnsBefore,
                       "no turn may begin while the answer is still sounding")
        XCTAssertFalse(backend.isTurnActive)
        XCTAssertFalse(sink.names.contains("microphone.reopened"))

        // The answer finishes and drains. Only now does the microphone come back.
        backend.completeResponse()
        await settle()
        playback.completeDrain()
        await settle()

        XCTAssertTrue(sink.names.contains("microphone.reopened"))
        XCTAssertEqual(backend.turnsBegun, turnsBefore + 1)
        XCTAssertTrue(backend.isTurnActive, "the window listens once the answer is done")
        XCTAssertEqual(backend.cancels, 0, "nothing cancelled the answer along the way")
    }

    // MARK: - The arbiter seam

    /// A window nothing resolved reaches the voice channel as a timeout; one the wearer
    /// resolved reaches it as a stop. This is the only place the two are told apart, and the
    /// provider's whole rule hangs off it.
    func testTheArbiterTellsATimeoutApartFromAResolution() async {
        let timedOut = ReasonRecordingVoice()
        let arbiter = InputArbiter(gestures: nil, voice: timedOut, taps: nil,
                                   timeoutSleep: { _ in })
        _ = await arbiter.listen(timeout: 5)
        XCTAssertEqual(timedOut.unresolvedStops, 1, "a timeout must not read as a stop")
        XCTAssertEqual(timedOut.stops, 0)

        let resolved = ReasonRecordingVoice()
        let second = InputArbiter(gestures: nil, voice: resolved, taps: nil,
                                  timeoutSleep: { _ in try? await Task.sleep(for: .seconds(1)) })
        let task = Task { await second.listen(timeout: 5) }
        while resolved.onCommand == nil { await Task.yield() }
        resolved.fire(.yes)
        _ = await task.value
        XCTAssertEqual(resolved.stops, 1, "a resolved window must still be a plain stop")
        XCTAssertEqual(resolved.unresolvedStops, 0)
    }
}
