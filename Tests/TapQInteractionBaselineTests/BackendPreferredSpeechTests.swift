import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

@MainActor
final class BackendPreferredSpeechTests: XCTestCase {
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
    }

    /// Records what the local synthesizer was asked to say, in order.
    @MainActor
    private final class FakeEngine: SpeechPresenting {
        struct Utterance: Equatable {
            let text: String
            let priority: SpeechPriority
        }

        private(set) var spoken: [Utterance] = []
        private(set) var stopAllCount = 0
        private var finishers: [() -> Void] = []

        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append(Utterance(text: text, priority: priority))
            if let onFinish { finishers.append(onFinish) }
        }

        func stopAll() {
            stopAllCount += 1
        }

        /// Fires the pending completions, as a synthesizer does when an utterance ends.
        func finishAll() {
            let pending = finishers
            finishers = []
            pending.forEach { $0() }
        }
    }

    /// A route that reports whatever the test says the backend would, and records the text
    /// it was offered.
    @MainActor
    private final class FakeRoute {
        private(set) var offered: [String] = []
        var accepts = true

        func route(_ text: String) -> Bool {
            offered.append(text)
            return accepts
        }
    }

    private func makeSpeech(engine: FakeEngine, route: FakeRoute,
                            sink: RecordingSink = RecordingSink()) -> BackendPreferredSpeech {
        BackendPreferredSpeech(wrapping: engine,
                               route: { route.route($0) },
                               diagnosticSink: sink)
    }

    // MARK: - Priority policy

    func testNotificationGoesToTheBackendWhenItIsTaken() async {
        let engine = FakeEngine()
        let route = FakeRoute()
        let sink = RecordingSink()
        let speech = makeSpeech(engine: engine, route: route, sink: sink)

        speech.speak("Claude is waiting: tests are green.", priority: .notification,
                     onFinish: nil)

        XCTAssertEqual(route.offered, ["Claude is waiting: tests are green."])
        XCTAssertEqual(engine.spoken, [], "the local engine must stay silent")
        XCTAssertTrue(sink.names.contains("utterance.spoken_by_backend"))
    }

    /// The invariant this decorator exists to respect: no model may restate what the wearer
    /// is authorizing, so an approval never reaches the backend at all.
    func testApprovalIsNeverOfferedToTheBackend() async {
        let engine = FakeEngine()
        let route = FakeRoute()
        let speech = makeSpeech(engine: engine, route: route)

        speech.speak("Claude wants to run rm -rf build. Nod yes or shake no.",
                     priority: .approval, onFinish: nil)

        XCTAssertEqual(route.offered, [], "an approval must never be offered to a backend")
        XCTAssertEqual(engine.spoken,
                       [.init(text: "Claude wants to run rm -rf build. Nod yes or shake no.",
                              priority: .approval)],
                       "approval text reaches the synthesizer byte-identical")
    }

    func testProgressIsNeverOfferedToTheBackend() async {
        let engine = FakeEngine()
        let route = FakeRoute()
        let speech = makeSpeech(engine: engine, route: route)

        speech.speak("Working.", priority: .progress, onFinish: nil)

        XCTAssertEqual(route.offered, [])
        XCTAssertEqual(engine.spoken, [.init(text: "Working.", priority: .progress)])
    }

    // MARK: - Fallback

    func testDeclinedRouteFallsBackToTheEngineVerbatim() async {
        let engine = FakeEngine()
        let route = FakeRoute()
        route.accepts = false
        let sink = RecordingSink()
        let speech = makeSpeech(engine: engine, route: route, sink: sink)

        speech.speak("Claude is waiting.", priority: .notification, onFinish: nil)

        XCTAssertEqual(route.offered, ["Claude is waiting."])
        XCTAssertEqual(engine.spoken,
                       [.init(text: "Claude is waiting.", priority: .notification)],
                       "a declined route must not lose or alter the utterance")
        XCTAssertTrue(sink.names.contains("utterance.spoken_locally"))
    }

    func testEachUtteranceIsRoutedOnItsOwnMerits() async {
        let engine = FakeEngine()
        let route = FakeRoute()
        let speech = makeSpeech(engine: engine, route: route)

        speech.speak("First.", priority: .notification, onFinish: nil)
        route.accepts = false
        speech.speak("Second.", priority: .notification, onFinish: nil)
        route.accepts = true
        speech.speak("Third.", priority: .notification, onFinish: nil)

        XCTAssertEqual(route.offered, ["First.", "Second.", "Third."])
        XCTAssertEqual(engine.spoken, [.init(text: "Second.", priority: .notification)])
    }

    // MARK: - onFinish

    func testRoutedUtteranceCallsOnFinishOnce() async {
        let engine = FakeEngine()
        let route = FakeRoute()
        let speech = makeSpeech(engine: engine, route: route)
        var finishes = 0

        speech.speak("Claude is waiting.", priority: .notification) { finishes += 1 }

        XCTAssertEqual(finishes, 1, "the caller must be released when the backend takes it")
    }

    func testDeclinedRouteHandsOnFinishToTheEngine() async {
        let engine = FakeEngine()
        let route = FakeRoute()
        route.accepts = false
        let speech = makeSpeech(engine: engine, route: route)
        var finishes = 0

        speech.speak("Claude is waiting.", priority: .notification) { finishes += 1 }
        XCTAssertEqual(finishes, 0, "the engine owns completion on the fallback path")

        engine.finishAll()
        XCTAssertEqual(finishes, 1)
    }

    func testExcludedPriorityHandsOnFinishToTheEngine() async {
        let engine = FakeEngine()
        let route = FakeRoute()
        let speech = makeSpeech(engine: engine, route: route)
        var finishes = 0

        speech.speak("Approve?", priority: .approval) { finishes += 1 }
        XCTAssertEqual(finishes, 0)

        engine.finishAll()
        XCTAssertEqual(finishes, 1)
    }

    // MARK: - stopAll

    func testStopAllReachesTheEngine() async {
        let engine = FakeEngine()
        let route = FakeRoute()
        let speech = makeSpeech(engine: engine, route: route)

        speech.speak("Claude is waiting.", priority: .notification, onFinish: nil)
        speech.stopAll()

        XCTAssertEqual(engine.stopAllCount, 1)
    }

    // MARK: - Composed with the provider's own route

    /// The shape composition builds: the decorator's route is the provider's
    /// `speakViaBackend`, so the policy and the session state decide together.
    @MainActor
    private final class QuietBackend: VoiceBackend {
        let capabilities = VoiceBackendCapabilities(supportsBargeIn: true, producesAudio: true,
                                                    duplex: true)
        private(set) var spoken: [String] = []

        func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {}
        func close() {}
        func beginUserTurn() {}
        @discardableResult
        func endUserTurn(expectingResponse: Bool) -> Bool { false }
        func sendAudio(_ chunk: VoiceAudioChunk) {}
        func requestResponse(text: String) { spoken.append(text) }
        func cancelResponse() {}

        func setNativeTurnDetection(_ enabled: Bool) {}
    }

    func testComposedWithTheProviderSpeaksNotificationsThroughTheBackend() async {
        let backend = QuietBackend()
        let provider = VoiceBackendCommandProvider(
            backend: backend,
            match: { _ in nil },
            sessionPolicy: .conversation(idleClose: 60))
        let engine = FakeEngine()
        let speech = BackendPreferredSpeech(wrapping: engine,
                                            route: { provider.speakViaBackend($0) })

        provider.start { _ in }
        for _ in 0..<4 { await Task.yield() }

        // A user turn is open: the backend cannot legally answer, so TapQ speaks.
        speech.speak("Claude is waiting.", priority: .notification, onFinish: nil)
        XCTAssertEqual(backend.spoken, [])
        XCTAssertEqual(engine.spoken, [.init(text: "Claude is waiting.",
                                             priority: .notification)])

        // Between windows the session is still open and the backend takes it.
        provider.stop()
        speech.speak("Claude is waiting again.", priority: .notification, onFinish: nil)
        XCTAssertEqual(backend.spoken, ["Claude is waiting again."])
        XCTAssertEqual(engine.spoken.count, 1, "the second utterance never reached the engine")

        // An approval in the same state still goes to the synthesizer, verbatim.
        speech.speak("Claude wants to run tests. Nod yes or shake no.", priority: .approval,
                     onFinish: nil)
        XCTAssertEqual(backend.spoken, ["Claude is waiting again."])
        XCTAssertEqual(engine.spoken.last,
                       .init(text: "Claude wants to run tests. Nod yes or shake no.",
                             priority: .approval))
    }
}
