import XCTest
import AVFoundation
import Speech
import TapQContracts
@testable import TapQAppleAdapters

@MainActor
final class AppleVoiceBackendTests: XCTestCase {
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

    private final class FakeRecognitionTask: VoiceRecognitionTasking {
        private(set) var cancellations = 0
        func cancel() { cancellations += 1 }
    }

    private final class FakeRecognizer: VoiceSpeechRecognizing {
        var isAvailable = true
        var supportsOnDeviceRecognition = true
        var localeIdentifier: String? = "en-US"
        var returnsTask = true
        private(set) var requests: [SFSpeechAudioBufferRecognitionRequest] = []
        private(set) var tasks: [FakeRecognitionTask] = []

        func recognitionTask(
            with request: SFSpeechAudioBufferRecognitionRequest,
            resultHandler: @escaping (SFSpeechRecognitionResult?, (any Error)?) -> Void
        ) -> (any VoiceRecognitionTasking)? {
            requests.append(request)
            guard returnsTask else { return nil }
            let task = FakeRecognitionTask()
            tasks.append(task)
            return task
        }
    }

    private final class FakeAudioSource: VoiceAudioSource {
        var startFailure: (any Error)?
        private(set) var starts = 0
        private(set) var stops = 0
        private var invalidation: (@MainActor (VoiceAudioSourceFailure) -> Void)?

        func start(
            onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
            onInvalidation: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
        ) throws {
            _ = onBuffer
            starts += 1
            invalidation = onInvalidation
            if let startFailure { throw startFailure }
        }

        func stop() { stops += 1 }

        func invalidate(
            _ failure: VoiceAudioSourceFailure = .init(stage: .configurationChanged,
                                                       detail: "test route change")
        ) {
            invalidation?(failure)
        }
    }

    /// Stands in for the host's shared `SpeechEngine`; the completion is held so a test can
    /// finish an utterance on its own schedule.
    @MainActor
    private final class FakeSpeech: SpeechPresenting {
        private(set) var spoken: [(text: String, priority: SpeechPriority)] = []
        private(set) var stopAllCount = 0
        private var pendingFinish: (() -> Void)?

        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append((text, priority))
            pendingFinish = onFinish
        }

        func stopAll() { stopAllCount += 1 }

        func finishUtterance() {
            let finish = pendingFinish
            pendingFinish = nil
            finish?()
        }
    }

    private enum TestFailure: Error { case expected }

    private struct Fixture {
        let backend: AppleVoiceBackend
        let recognizer: FakeRecognizer
        let source: FakeAudioSource
        let speech: FakeSpeech
        let sink: RecordingSink
    }

    private func makeFixture(sources: [FakeAudioSource]? = nil) -> Fixture {
        let recognizer = FakeRecognizer()
        let source = sources?.first ?? FakeAudioSource()
        let all = sources ?? [source]
        var index = 0
        let speech = FakeSpeech()
        let sink = RecordingSink()
        let backend = AppleVoiceBackend(
            recognizer: recognizer,
            makeAudioSource: {
                defer { index += 1 }
                return all[min(index, all.count - 1)]
            },
            speech: speech,
            diagnosticSink: sink
        )
        return Fixture(backend: backend, recognizer: recognizer, source: source,
                       speech: speech, sink: sink)
    }

    private func openWindow(_ fixture: Fixture,
                            collecting events: EventLog) async throws {
        try await fixture.backend.open { events.append($0) }
    }

    /// Reference box so a test can keep collecting events after the backend tears itself
    /// down mid-callback.
    @MainActor
    private final class EventLog {
        private(set) var events: [VoiceBackendEvent] = []
        func append(_ event: VoiceBackendEvent) { events.append(event) }
    }

    // MARK: - Session lifecycle

    func testCapabilitiesAreTranscriptOnly() {
        let fixture = makeFixture()
        XCTAssertEqual(fixture.backend.capabilities, .transcriptOnly)
        XCTAssertFalse(fixture.backend.capabilities.producesAudio)
        XCTAssertFalse(fixture.backend.capabilities.supportsBargeIn)
        XCTAssertFalse(fixture.backend.capabilities.duplex)
    }

    func testOpenDoesNotTouchTheMicrophone() async throws {
        let fixture = makeFixture()
        let log = EventLog()

        try await openWindow(fixture, collecting: log)

        XCTAssertEqual(fixture.source.starts, 0,
                       "the mic opens per turn, never for the length of a session")
        XCTAssertEqual(fixture.recognizer.requests.count, 0)
        XCTAssertEqual(fixture.backend.turnStateForTesting, .open)
        XCTAssertTrue(fixture.sink.names.contains("session.opened"))
    }

    func testOpenWithUnavailableRecognizerThrowsAndCreatesNoTask() async {
        let fixture = makeFixture()
        fixture.recognizer.isAvailable = false

        do {
            try await fixture.backend.open { _ in XCTFail("no session, no events") }
            XCTFail("an unavailable recognizer must fail the open")
        } catch let failure as VoiceBackendFailure {
            guard case .authorization(let detail) = failure else {
                return XCTFail("expected an authorization failure, got \(failure)")
            }
            XCTAssertTrue(detail.contains("en-US"))
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertEqual(fixture.recognizer.requests.count, 0)
        XCTAssertEqual(fixture.source.starts, 0)
        XCTAssertEqual(fixture.backend.turnStateForTesting, .idle)
        XCTAssertEqual(fixture.sink.events.last { $0.name == "open.failed" }?.fields["reason"],
                       "recognizer_unavailable")
    }

    func testSecondOpenIsAProtocolViolation() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)

        do {
            try await fixture.backend.open { _ in }
            XCTFail("double open must throw")
        } catch let failure as VoiceBackendFailure {
            guard case .protocolViolation = failure else {
                return XCTFail("expected a protocol violation, got \(failure)")
            }
        }
        XCTAssertEqual(fixture.backend.turnStateForTesting, .open,
                       "the live session survives a rejected second open")
    }

    func testCloseIsIdempotentAndStopsTheMicrophone() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        fixture.backend.close()
        fixture.backend.close()
        fixture.backend.close()

        XCTAssertEqual(fixture.source.stops, 1)
        XCTAssertEqual(fixture.recognizer.tasks[0].cancellations, 1)
        XCTAssertEqual(fixture.backend.turnStateForTesting, .idle)
        XCTAssertEqual(log.events, [], "teardown is not a failure")
    }

    func testSessionReopensAfterClose() async throws {
        let first = FakeAudioSource()
        let second = FakeAudioSource()
        let fixture = makeFixture(sources: [first, second])
        let log = EventLog()

        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()
        fixture.backend.close()

        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        XCTAssertEqual(first.starts, 1)
        XCTAssertEqual(second.starts, 1, "each turn gets a fresh audio source")
        XCTAssertEqual(fixture.recognizer.requests.count, 2)
    }

    // MARK: - Turn lifecycle

    func testBeginUserTurnOpensTheMicrophoneAndAnOnDeviceRequest() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)

        fixture.backend.beginUserTurn()

        XCTAssertEqual(fixture.source.starts, 1)
        XCTAssertEqual(fixture.recognizer.requests.count, 1)
        XCTAssertTrue(fixture.recognizer.requests[0].shouldReportPartialResults)
        XCTAssertTrue(fixture.recognizer.requests[0].requiresOnDeviceRecognition)
        XCTAssertEqual(fixture.backend.turnStateForTesting, .userTurn)
        XCTAssertTrue(fixture.sink.names.contains("turn.began"))
    }

    func testOffDeviceRecognitionWhenTheRecognizerCannotStayLocal() async throws {
        let fixture = makeFixture()
        fixture.recognizer.supportsOnDeviceRecognition = false
        let log = EventLog()
        try await openWindow(fixture, collecting: log)

        fixture.backend.beginUserTurn()

        XCTAssertFalse(fixture.recognizer.requests[0].requiresOnDeviceRecognition)
    }

    func testEndUserTurnClosesTheMicrophoneButKeepsRecognizing() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        fixture.backend.endUserTurn(expectingResponse: true)

        XCTAssertEqual(fixture.source.stops, 1, "the mic closes the instant the turn commits")
        XCTAssertEqual(fixture.recognizer.tasks[0].cancellations, 0,
                       "the settled transcript is still owed to the caller")
        XCTAssertEqual(fixture.backend.turnStateForTesting, .committed)
    }

    func testBeginUserTurnBeforeOpenIsRejectedWithoutTouchingHardware() {
        let fixture = makeFixture()

        fixture.backend.beginUserTurn()

        XCTAssertEqual(fixture.source.starts, 0)
        XCTAssertEqual(fixture.recognizer.requests.count, 0)
        XCTAssertEqual(fixture.backend.turnStateForTesting, .idle)
        XCTAssertTrue(fixture.sink.names.contains("session.failed"))
    }

    func testDoubleBeginUserTurnFailsTheSession() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        fixture.backend.beginUserTurn()

        XCTAssertEqual(log.events.count, 1)
        guard case .sessionFailed(.protocolViolation) = log.events[0] else {
            return XCTFail("expected a protocol violation, got \(log.events)")
        }
        XCTAssertEqual(fixture.backend.turnStateForTesting, .idle)
        XCTAssertEqual(fixture.source.stops, 1, "a failed session never leaves the mic open")
    }

    func testEndUserTurnWithNoTurnOpenFailsTheSession() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)

        fixture.backend.endUserTurn(expectingResponse: true)

        guard case .sessionFailed(.protocolViolation) = log.events.first else {
            return XCTFail("expected a protocol violation, got \(log.events)")
        }
    }

    func testSendAudioIsIgnoredByAMicrophoneOwningBackend() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        fixture.backend.sendAudio(VoiceAudioChunk(data: Data(repeating: 3, count: 320),
                                                  format: .pcm16Mono16k, timestamp: 1))

        XCTAssertEqual(log.events, [], "pushed audio is dropped, never a session failure")
        XCTAssertEqual(fixture.backend.turnStateForTesting, .userTurn)
        let ignored = fixture.sink.events.last { $0.name == "audio.ignored" }
        XCTAssertEqual(ignored?.fields["reason"], "backend_owns_microphone")
        XCTAssertEqual(ignored?.fields["bytes"], "320")
    }

    // MARK: - Transcripts

    func testPartialAndFinalTranscriptsReachTheCaller() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        fixture.backend.deliverRecognitionForTesting(transcript: "yes")
        fixture.backend.endUserTurn(expectingResponse: true)
        fixture.backend.deliverRecognitionForTesting(transcript: "yes please", isFinal: true)

        XCTAssertEqual(log.events, [.transcriptPartial("yes"),
                                    .transcriptFinal("yes please"),
                                    .responseCompleted])
        XCTAssertEqual(fixture.backend.turnStateForTesting, .open)
        XCTAssertEqual(fixture.recognizer.tasks[0].cancellations, 1,
                       "recognition resources are released once the turn is settled")
    }

    func testEmptyTranscriptsAreNotForwarded() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        fixture.backend.deliverRecognitionForTesting(transcript: "")
        fixture.backend.deliverRecognitionForTesting(transcript: nil)

        XCTAssertEqual(log.events, [])
    }

    func testRecognizerFinalDuringAUserTurnNeverEndsTheTurn() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        // SFSpeechRecognizer's own silence heuristic declaring the utterance over.
        fixture.backend.deliverRecognitionForTesting(transcript: "maybe", isFinal: true)

        XCTAssertEqual(log.events, [.transcriptFinal("maybe")],
                       "the transcript is data; the turn boundary is TapQ's alone")
        XCTAssertEqual(fixture.backend.turnStateForTesting, .userTurn)
        XCTAssertEqual(fixture.source.stops, 0, "the mic stays open until TapQ commits")
        XCTAssertEqual(
            fixture.sink.events.last { $0.name == "transcript.final_during_turn" }?
                .fields["reason"],
            "recognizer_vad_ignored")
    }

    func testCallerClosingFromInsideATranscriptEventIsSafe() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        // The real consumer resolves its window on a matched partial and tears the backend
        // down from inside the event callback.
        try await fixture.backend.open { [weak backend = fixture.backend] event in
            log.append(event)
            if case .transcriptPartial = event { backend?.close() }
        }
        fixture.backend.beginUserTurn()

        fixture.backend.deliverRecognitionForTesting(transcript: "yes")

        XCTAssertEqual(log.events, [.transcriptPartial("yes")])
        XCTAssertEqual(fixture.backend.turnStateForTesting, .idle)
        XCTAssertEqual(fixture.source.stops, 1)
    }

    func testRecognitionErrorFailsTheSession() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        fixture.backend.deliverRecognitionForTesting(error: TestFailure.expected)

        guard case .sessionFailed(.network(let detail)) = log.events.first else {
            return XCTFail("expected a network failure, got \(log.events)")
        }
        XCTAssertTrue(detail.contains("recognition failed"))
        XCTAssertEqual(fixture.source.stops, 1)
        XCTAssertEqual(fixture.backend.turnStateForTesting, .idle)
    }

    func testStaleRecognitionCallbacksAreIgnored() async throws {
        let first = FakeAudioSource()
        let second = FakeAudioSource()
        let fixture = makeFixture(sources: [first, second])
        let log = EventLog()

        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()
        let staleGeneration = fixture.backend.sessionGenerationForTesting
        fixture.backend.close()

        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        fixture.backend.deliverRecognitionForTesting(transcript: "yes",
                                                     generation: staleGeneration)
        fixture.backend.deliverRecognitionForTesting(error: TestFailure.expected,
                                                     generation: staleGeneration)

        XCTAssertEqual(log.events, [],
                       "a callback from the previous session must not reach this one")
        XCTAssertEqual(fixture.backend.turnStateForTesting, .userTurn)
        XCTAssertEqual(second.stops, 0)
    }

    // MARK: - Route and capture failures

    func testRouteChangeSurfacesSessionFailed() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        fixture.source.invalidate()

        guard case .sessionFailed(.network(let detail)) = log.events.first else {
            return XCTFail("expected a network failure, got \(log.events)")
        }
        XCTAssertTrue(detail.contains("configuration_changed"))
        XCTAssertTrue(detail.contains("test route change"))
        XCTAssertEqual(fixture.backend.turnStateForTesting, .idle)
        XCTAssertEqual(fixture.source.stops, 1)
    }

    func testStaleRouteCallbackDoesNotFailTheLiveSession() async throws {
        let first = FakeAudioSource()
        let second = FakeAudioSource()
        let fixture = makeFixture(sources: [first, second])
        let log = EventLog()

        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()
        fixture.backend.close()
        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        first.invalidate()

        XCTAssertEqual(log.events, [])
        XCTAssertEqual(fixture.backend.turnStateForTesting, .userTurn)
    }

    func testMicrophoneStartFailureFailsTheSessionBeforeRecognition() async throws {
        let fixture = makeFixture()
        fixture.source.startFailure = VoiceAudioSourceFailure(
            stage: .engineStart, detail: "input device disappeared")
        let log = EventLog()
        try await openWindow(fixture, collecting: log)

        fixture.backend.beginUserTurn()

        guard case .sessionFailed(.network(let detail)) = log.events.first else {
            return XCTFail("expected a network failure, got \(log.events)")
        }
        XCTAssertTrue(detail.contains("engine_start"))
        XCTAssertTrue(detail.contains("input device disappeared"))
        XCTAssertEqual(fixture.recognizer.requests.count, 0,
                       "no recognition task for a window with no microphone")
        XCTAssertEqual(fixture.backend.turnStateForTesting, .idle)
    }

    func testMissingRecognitionTaskFailsTheSession() async throws {
        let fixture = makeFixture()
        fixture.recognizer.returnsTask = false
        let log = EventLog()
        try await openWindow(fixture, collecting: log)

        fixture.backend.beginUserTurn()

        guard case .sessionFailed(.network(let detail)) = log.events.first else {
            return XCTFail("expected a network failure, got \(log.events)")
        }
        XCTAssertTrue(detail.contains("no task"))
        XCTAssertEqual(fixture.source.stops, 1)
        XCTAssertEqual(fixture.backend.turnStateForTesting, .idle)
    }

    // MARK: - Responses

    func testRequestResponseReachesTheInjectedSpeechPresenter() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)

        fixture.backend.requestResponse(text: "Deploying to staging.")

        XCTAssertEqual(fixture.speech.spoken.count, 1)
        XCTAssertEqual(fixture.speech.spoken[0].text, "Deploying to staging.")
        XCTAssertEqual(fixture.speech.spoken[0].priority, .notification)
        XCTAssertEqual(fixture.backend.turnStateForTesting, .responding)

        fixture.speech.finishUtterance()
        await Task.yield()
        XCTAssertEqual(log.events, [.responseCompleted])
        XCTAssertEqual(fixture.backend.turnStateForTesting, .open)
    }

    func testRequestResponseDuringAUserTurnIsRejectedHalfDuplex() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)
        fixture.backend.beginUserTurn()

        fixture.backend.requestResponse(text: "talking over the wearer")

        XCTAssertEqual(fixture.speech.spoken.count, 0, "nothing is spoken into an open mic")
        guard case .sessionFailed(.protocolViolation(let detail)) = log.events.first else {
            return XCTFail("expected a protocol violation, got \(log.events)")
        }
        XCTAssertTrue(detail.contains("half-duplex"))
    }

    func testLateSynthesizerCompletionAfterCloseIsIgnored() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)
        fixture.backend.requestResponse(text: "status")

        fixture.backend.close()
        fixture.speech.finishUtterance()
        await Task.yield()

        XCTAssertEqual(log.events, [])
        XCTAssertEqual(fixture.backend.turnStateForTesting, .idle)
    }

    func testCancelResponseIsRejectedWhenBargeInIsUnsupported() async throws {
        let fixture = makeFixture()
        let log = EventLog()
        try await openWindow(fixture, collecting: log)
        fixture.backend.requestResponse(text: "status")

        fixture.backend.cancelResponse()

        guard case .sessionFailed(.protocolViolation(let detail)) = log.events.first else {
            return XCTFail("expected a protocol violation, got \(log.events)")
        }
        XCTAssertTrue(detail.contains("barge-in"))
        XCTAssertEqual(fixture.speech.stopAllCount, 0,
                       "an unsupported cancel must not half-succeed")
    }
}
