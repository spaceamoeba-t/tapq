import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Voice-output isolation: with a specified backend composed, that backend says everything.
///
/// The suite is in two halves. The first is the sink's own policy — which sentences it
/// offers to the backend (all of them) and what it does when one cannot go out now (wait,
/// never speak it some other way). The second is the provider underneath it, where the
/// waiting actually happens: the queue, the session opened for a sentence with nowhere to
/// go, the ordering against a window that wants to open, and the one outcome that is a
/// failure rather than a delay.
@MainActor
final class BackendSpeechSinkTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage.map(\.name)
        }

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// The local synthesizer, present so a test can prove it was never spoken to.
    @MainActor
    private final class FakeEngine: SpeechPresenting {
        struct Utterance: Equatable {
            let text: String
            let priority: SpeechPriority
        }

        private(set) var spoken: [Utterance] = []
        private(set) var stopAllCount = 0

        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append(Utterance(text: text, priority: priority))
            onFinish?()
        }

        func stopAll() { stopAllCount += 1 }
    }

    /// A route that reports whatever the test says the backend would, and records what it
    /// was offered.
    @MainActor
    private final class FakeRoute {
        private(set) var offered: [String] = []
        var answer: BackendSpeechDelivery = .spoken

        func route(_ text: String) -> BackendSpeechDelivery {
            offered.append(text)
            return answer
        }
    }

    /// A duplex backend that records every call, so a test can say exactly which sentences
    /// reached the pipe and in which order.
    @MainActor
    private final class SpeakingBackend: VoiceBackend {
        let capabilities = VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                    duplex: true)
        private(set) var scripted: [String] = []
        private(set) var grounded: [String] = []
        private(set) var beganTurns = 0
        private(set) var cancels = 0
        private(set) var isOpen = false
        private var handler: (@MainActor (VoiceBackendEvent) -> Void)?
        /// Set to make `open` throw, as a dead pipe or a refused break latch does.
        var openFailure: VoiceBackendFailure?

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
            if let openFailure { throw openFailure }
            isOpen = true
            handler = onEvent
        }

        func close() {
            isOpen = false
            handler = nil
        }

        func beginUserTurn() {
            XCTAssertTrue(isOpen, "a turn was opened on a closed session")
            beganTurns += 1
        }

        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool { false }
        func sendAudio(_ chunk: VoiceAudioChunk) {}
        func requestResponse(text: String) { grounded.append(text) }
        func requestScriptedSpeech(text: String) { scripted.append(text) }
        func cancelResponse() { cancels += 1 }
        func setNativeTurnDetection(_ enabled: Bool) {}

        /// Plays the backend's side of one response: audio, then completion.
        func finishResponse() {
            handler?(.audio(VoiceAudioChunk(data: Data([0, 1]),
                                            format: .pcm16Mono24k, timestamp: 0)))
            handler?(.responseCompleted)
        }

        func fail(_ failure: VoiceBackendFailure = .network("socket dropped")) {
            handler?(.sessionFailed(failure))
        }
    }

    private func makeProvider(_ backend: SpeakingBackend,
                              sink: RecordingSink) -> VoiceBackendCommandProvider {
        VoiceBackendCommandProvider(
            backend: backend,
            match: { _ in nil },
            sessionPolicy: .conversation(idleClose: 60),
            supportsBargeIn: true,
            // Long enough that no test in here reaches an idle close (each finishes in
            // milliseconds), short enough that the sleep it leaves behind cannot stall the
            // suite. A pending 60-second sleep does exactly that on Linux: the next test to
            // run pays for it, which is worth knowing about before blaming the test that
            // happens to be holding the clock.
            idleSleep: { _ in try? await Task.sleep(for: .seconds(1)) },
            diagnosticSink: sink
        )
    }

    /// The open and the flush both hop the main actor.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    // MARK: - The sink offers everything

    /// The whole of the decision, as one assertion.
    ///
    /// The predecessor of this type offered only `.notification` and sent everything else to
    /// the local synthesizer, which is what produced two alternating voices — and a local
    /// voice audible to the backend's own open microphone. Every priority now goes to the
    /// one pipe the operator named.
    func testEveryPriorityIsOfferedToTheBackend() async {
        let route = FakeRoute()
        let sink = RecordingSink()
        let speech = BackendSpeechSink(route: { route.route($0) }, diagnosticSink: sink)

        speech.speak("Claude Code wants to run rm -rf build. Nod yes or shake no.",
                     priority: .approval, onFinish: nil)
        speech.speak("Claude Code is waiting: tests are green.", priority: .notification,
                     onFinish: nil)
        speech.speak("Working.", priority: .progress, onFinish: nil)

        XCTAssertEqual(route.offered, [
            "Claude Code wants to run rm -rf build. Nod yes or shake no.",
            "Claude Code is waiting: tests are green.",
            "Working.",
        ])
        XCTAssertEqual(sink.names.filter { $0 == "utterance.spoken_by_backend" }.count, 3)
    }

    /// The approval sentence reaches the pipe byte for byte. What keeps a model from
    /// rewriting it is the verbatim request on the wire, not a second synthesizer.
    func testApprovalTextIsOfferedUnaltered() async {
        let route = FakeRoute()
        let speech = BackendSpeechSink(route: { route.route($0) })
        let prompt = "Codex wants to force-push to main. Nod yes or shake no."

        speech.speak(prompt, priority: .approval, onFinish: nil)

        XCTAssertEqual(route.offered, [prompt])
    }

    /// A busy pipe delays a sentence; it never hands it to anything else. There is no
    /// engine reference in this type for a fallback to reach.
    func testAQueuedSentenceReleasesTheCallerAndIsNotSaidAnotherWay() async {
        let route = FakeRoute()
        route.answer = .queued
        let sink = RecordingSink()
        let speech = BackendSpeechSink(route: { route.route($0) }, diagnosticSink: sink)
        var finishes = 0

        speech.speak("Listening.", priority: .notification) { finishes += 1 }

        XCTAssertEqual(route.offered, ["Listening."])
        XCTAssertEqual(finishes, 1, "the caller sequences on acceptance, not on audio")
        XCTAssertTrue(sink.names.contains("utterance.queued_for_backend"))
    }

    func testADroppedSentenceIsRecordedAndStillReleasesTheCaller() async {
        let route = FakeRoute()
        route.answer = .dropped("shutdown")
        let sink = RecordingSink()
        let speech = BackendSpeechSink(route: { route.route($0) }, diagnosticSink: sink)
        var finishes = 0

        speech.speak("Voice session ended.", priority: .notification) { finishes += 1 }

        XCTAssertEqual(finishes, 1)
        let dropped = sink.events.first { $0.name == "utterance.dropped" }
        XCTAssertEqual(dropped?.fields["reason"], "shutdown")
    }

    // MARK: - The break is the only door to the local voice

    /// A local engine is present in the shipping composition, and while the pipe is alive
    /// nothing can reach it — not a busy route, not a dropped sentence, not an approval.
    func testTheLocalEngineIsUntouchedWhileTheBackendLives() async {
        let route = FakeRoute()
        let engine = FakeEngine()
        let speech = BackendSpeechSink(route: { route.route($0) },
                                       localAfterBreak: engine,
                                       isBackendBroken: { false })

        route.answer = .spoken
        speech.speak("Claude Code wants to run the tests.", priority: .approval, onFinish: nil)
        route.answer = .queued
        speech.speak("Listening.", priority: .notification, onFinish: nil)
        route.answer = .dropped("empty_text")
        speech.speak("Working.", priority: .progress, onFinish: nil)

        XCTAssertEqual(engine.spoken, [], "the local engine spoke: \(engine.spoken)")
        XCTAssertEqual(route.offered.count, 3)
    }

    /// After the break there is no pipe, and windows still open. A prompt nobody can hear
    /// would make them unanswerable, so from the break onwards the local engine speaks — and
    /// the route is not even consulted, because there is nothing on the other end of it.
    func testAfterTheBreakTheLocalEngineSpeaksAndTheRouteIsNotConsulted() async {
        let route = FakeRoute()
        let engine = FakeEngine()
        var broken = false
        let sink = RecordingSink()
        let speech = BackendSpeechSink(route: { route.route($0) },
                                       localAfterBreak: engine,
                                       isBackendBroken: { broken },
                                       diagnosticSink: sink)

        speech.speak("Before.", priority: .notification, onFinish: nil)
        broken = true
        speech.speak("Claude Code wants to run the tests.", priority: .approval, onFinish: nil)

        XCTAssertEqual(route.offered, ["Before."], "a dead pipe is not offered anything")
        XCTAssertEqual(engine.spoken,
                       [.init(text: "Claude Code wants to run the tests.",
                              priority: .approval)])
        XCTAssertTrue(sink.names.contains("utterance.spoken_locally_after_break"))
    }

    func testStopAllForgetsWhatHasNotBeenSaid() async {
        let route = FakeRoute()
        var stops = 0
        let speech = BackendSpeechSink(route: { route.route($0) }, stop: { stops += 1 })

        speech.stopAll()

        XCTAssertEqual(stops, 1)
    }

    // MARK: - The provider does the waiting

    /// A notice between windows has no session to be spoken through, and the answer is to
    /// open one — not to reach for the local voice.
    func testASentenceWithNoSessionOpensOneAndIsSpokenThroughIt() async {
        let backend = SpeakingBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend, sink: sink)

        XCTAssertEqual(provider.speakScripted("Codex finished."), .queued)
        XCTAssertTrue(sink.names.contains("speech_session.opening"))
        await settle()

        XCTAssertEqual(backend.scripted, ["Codex finished."])
        XCTAssertEqual(backend.beganTurns, 0,
                       "a session opened to say something must not open a microphone")
    }

    /// The ordering the whole feature turns on. `BargeIn` speaks and opens the window in one
    /// main-actor turn, so the prompt is requested first and the microphone waits for it —
    /// rather than opening over TapQ's own voice, which is how the backend ended up
    /// transcribing TapQ as the wearer.
    func testAPromptSpokenAsAWindowOpensDefersTheTurnUntilItHasBeenRead() async {
        let backend = SpeakingBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend, sink: sink)

        // The prompt, then the window, in the same turn — exactly `BargeIn.listen`.
        provider.speakScripted("Claude Code wants to run the tests. Nod yes or shake no.")
        provider.start { _ in }
        await settle()

        XCTAssertEqual(backend.scripted,
                       ["Claude Code wants to run the tests. Nod yes or shake no."])
        XCTAssertEqual(backend.beganTurns, 0, "the microphone must not open over the prompt")
        XCTAssertTrue(sink.names.contains("turn.deferred_scripted_speech"))

        backend.finishResponse()
        await settle()
        XCTAssertEqual(backend.beganTurns, 1, "the turn opens once the prompt has been read")
    }

    /// Half-duplex: nothing is said into an open user turn. The sentence waits for the turn
    /// to end and then goes out — on the same pipe, never on another voice.
    func testASentenceDuringAUserTurnWaitsForTheTurnRatherThanFallingBack() async {
        let backend = SpeakingBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend, sink: sink)

        provider.start { _ in }
        await settle()
        XCTAssertEqual(backend.beganTurns, 1)

        XCTAssertEqual(provider.speakScripted("Codex finished."), .queued)
        XCTAssertEqual(backend.scripted, [], "the wearer's turn is theirs")
        let queued = sink.events.first { $0.name == "speech.queued_for_backend" }
        XCTAssertEqual(queued?.fields["reason"], "user_turn_open")

        provider.stop()
        await settle()
        XCTAssertEqual(backend.scripted, ["Codex finished."])
    }

    /// One response at a time, and the sentence behind it keeps its place.
    func testSentencesKeepTheirOrderThroughTheQueue() async {
        let backend = SpeakingBackend()
        let provider = makeProvider(backend, sink: RecordingSink())

        provider.speakScripted("First.")
        await settle()
        XCTAssertEqual(backend.scripted, ["First."])

        XCTAssertEqual(provider.speakScripted("Second."), .queued)
        XCTAssertEqual(provider.speakScripted("Third."), .queued)
        XCTAssertEqual(backend.scripted, ["First."], "the pipe carries one response at a time")

        backend.finishResponse()
        await settle()
        XCTAssertEqual(backend.scripted, ["First.", "Second."])

        backend.finishResponse()
        await settle()
        XCTAssertEqual(backend.scripted, ["First.", "Second.", "Third."])
    }

    /// Two sentences in a row must not be separated by a listening window nobody asked for.
    func testADeferredTurnKeepsWaitingWhileThereIsStillSomethingToSay() async {
        let backend = SpeakingBackend()
        let provider = makeProvider(backend, sink: RecordingSink())

        provider.speakScripted("Instruction queued for Codex.")
        provider.speakScripted("Listening.")
        provider.start { _ in }
        await settle()
        XCTAssertEqual(backend.scripted, ["Instruction queued for Codex."])
        XCTAssertEqual(backend.beganTurns, 0)

        backend.finishResponse()
        await settle()
        XCTAssertEqual(backend.scripted, ["Instruction queued for Codex.", "Listening."])
        XCTAssertEqual(backend.beganTurns, 0, "the window still waits: TapQ is still talking")

        backend.finishResponse()
        await settle()
        XCTAssertEqual(backend.beganTurns, 1)
    }

    // MARK: - Undeliverable is a failure, never a fallback

    /// The break condition. A sentence the specified backend cannot say is the pipe failing
    /// at the job it was named for, and composition turns this report into the run's voice
    /// break — one local notice, voice dead for the run. What it is emphatically not is a
    /// cue to say the sentence in the Apple voice.
    func testASessionThatCannotBeOpenedReportsTheSentenceUndeliverable() async {
        let backend = SpeakingBackend()
        backend.openFailure = .closed("hands-free voice is disabled for this run")
        let sink = RecordingSink()
        let provider = makeProvider(backend, sink: sink)
        var reported: [String] = []
        provider.onScriptedSpeechUndeliverable = { reported.append($0) }

        provider.speakScripted("Codex finished.")
        await settle()

        XCTAssertEqual(backend.scripted, [])
        XCTAssertEqual(reported, ["session_open_failed"])
        let undeliverable = sink.events.first { $0.name == "scripted_speech.undeliverable" }
        XCTAssertEqual(undeliverable?.level, .error)
    }

    func testASessionThatDiesWithSentencesWaitingReportsThemUndeliverable() async {
        let backend = SpeakingBackend()
        let provider = makeProvider(backend, sink: RecordingSink())
        var reported: [String] = []
        provider.onScriptedSpeechUndeliverable = { reported.append($0) }

        provider.start { _ in }
        await settle()
        provider.speakScripted("Codex finished.")   // queued behind the open user turn
        backend.fail()
        await settle()

        XCTAssertEqual(reported, ["session_failed"])
    }

    /// A queue this deep means sentences are arriving faster than the pipe says them, which
    /// is a pipe that is not carrying TapQ's voice. Reported rather than quietly forgotten.
    func testQueueOverflowIsReportedRatherThanSilentlyDropped() async {
        let backend = SpeakingBackend()
        let provider = makeProvider(backend, sink: RecordingSink())
        var reported: [String] = []
        provider.onScriptedSpeechUndeliverable = { reported.append($0) }

        provider.start { _ in }   // an open user turn: nothing can go out
        await settle()
        for index in 0...VoiceBackendCommandProvider.maxQueuedScriptedUtterances {
            provider.speakScripted("Sentence \(index).")
        }

        XCTAssertEqual(reported, ["queue_overflow"])
    }

    /// Shutdown is not a failure: the run is ending, and a sentence that outlived the
    /// runtime asking for it is not a broken pipe.
    func testShutdownDropsWaitingSentencesWithoutCallingThemAFailure() async {
        let backend = SpeakingBackend()
        let sink = RecordingSink()
        let provider = makeProvider(backend, sink: sink)
        var reported: [String] = []
        provider.onScriptedSpeechUndeliverable = { reported.append($0) }

        provider.start { _ in }
        await settle()
        provider.speakScripted("Codex finished.")
        provider.shutdown()
        await settle()

        XCTAssertEqual(reported, [])
        XCTAssertTrue(sink.names.contains("scripted_speech.dropped"))
        XCTAssertEqual(provider.speakScripted("Anything."), .dropped("shutdown"))
    }

    func testEmptyTextIsDroppedRatherThanSentAsAResponse() async {
        let backend = SpeakingBackend()
        let provider = makeProvider(backend, sink: RecordingSink())

        XCTAssertEqual(provider.speakScripted("   \n "), .dropped("empty_text"))
        await settle()
        XCTAssertEqual(backend.scripted, [])
    }

    // MARK: - Composed

    /// The shape the runtime builds: the sink's route is the provider's `speakScripted`, so
    /// every sentence a controller speaks lands on the backend. Nothing in this composition
    /// can reach a synthesizer — the sink has no engine to reach for.
    func testComposedEverySentenceOfAWindowReachesTheBackend() async {
        let backend = SpeakingBackend()
        let provider = makeProvider(backend, sink: RecordingSink())
        let speech = BackendSpeechSink(route: { provider.speakScripted($0) })

        speech.speak("Claude Code wants to run the tests. Nod yes or shake no.",
                     priority: .approval, onFinish: nil)
        provider.start { _ in }
        await settle()
        backend.finishResponse()
        await settle()

        provider.stop()
        speech.speak("Deferring to the screen.", priority: .notification, onFinish: nil)
        await settle()
        backend.finishResponse()
        await settle()

        speech.speak("Queued for Codex.", priority: .notification, onFinish: nil)
        await settle()

        XCTAssertEqual(backend.scripted, [
            "Claude Code wants to run the tests. Nod yes or shake no.",
            "Deferring to the screen.",
            "Queued for Codex.",
        ])
        XCTAssertEqual(backend.grounded, [],
                       "a scripted sentence is never sent as a grounded answer")
    }
}
