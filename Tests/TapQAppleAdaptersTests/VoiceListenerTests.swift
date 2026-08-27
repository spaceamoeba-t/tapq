import XCTest
import AVFoundation
import Speech
import TapQAudioCaptureBridge
import TapQAudioCaptureBridgeTestSupport
import TapQContracts
import TapQInteractionBaseline
@testable import TapQAppleAdapters

@MainActor
final class VoiceListenerTests: XCTestCase {
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
    }

    private final class FakeRecognitionTask: VoiceRecognitionTasking {
        private(set) var cancellations = 0
        func cancel() {
            cancellations += 1
        }
    }

    private final class FakeRecognizer: VoiceSpeechRecognizing {
        var isAvailable = true
        var supportsOnDeviceRecognition = true
        var localeIdentifier: String? = "en-US"
        var returnsTask = true
        private(set) var requests: [SFSpeechAudioBufferRecognitionRequest] = []
        private(set) var handlers: [
            (SFSpeechRecognitionResult?, (any Error)?) -> Void
        ] = []
        private(set) var tasks: [FakeRecognitionTask] = []

        func recognitionTask(
            with request: SFSpeechAudioBufferRecognitionRequest,
            resultHandler: @escaping (SFSpeechRecognitionResult?, (any Error)?) -> Void
        ) -> (any VoiceRecognitionTasking)? {
            requests.append(request)
            handlers.append(resultHandler)
            guard returnsTask else { return nil }
            let task = FakeRecognitionTask()
            tasks.append(task)
            return task
        }

        func fail(call index: Int) {
            handlers[index](nil, TestFailure.expected)
        }
    }

    private final class FakeAudioSource: VoiceAudioSource {
        var startFailure: (any Error)?
        var synchronousInvalidation: VoiceAudioSourceFailure?
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
            if let synchronousInvalidation {
                onInvalidation(synchronousInvalidation)
            }
            if let startFailure {
                throw startFailure
            }
        }

        func stop() {
            stops += 1
        }

        func invalidate(
            _ failure: VoiceAudioSourceFailure = .init(
                stage: .configurationChanged,
                detail: "test route change"
            )
        ) {
            invalidation?(failure)
        }
    }

    private final class FakeActivity: SpeechActivitySignaling {
        private(set) var isSpeaking = false
        var onSpeakingChange: (@MainActor (Bool) -> Void)?

        func setSpeaking(_ speaking: Bool) {
            guard speaking != isSpeaking else { return }
            isSpeaking = speaking
            onSpeakingChange?(speaking)
        }
    }

    private enum TestFailure: Error {
        case expected
    }

    func testRecognizerPinnedToGrammarLocale() async throws {
        XCTAssertEqual(VoiceListener.grammarLocale.identifier, "en-US")
        let listener = VoiceListener()
        guard let localeID = listener.recognizerLocaleForTesting else {
            throw XCTSkip("SFSpeechRecognizer unavailable for en-US on this machine")
        }
        XCTAssertEqual(localeID.replacingOccurrences(of: "_", with: "-"), "en-US")
    }

    func testHardwareFormatValidationRejectsUnavailableInput() {
        XCTAssertFalse(TapQAudioInputFormatIsUsable(0, 1))
        XCTAssertFalse(TapQAudioInputFormatIsUsable(48_000, 0))
        XCTAssertFalse(TapQAudioInputFormatIsUsable(.nan, 1))
        XCTAssertTrue(TapQAudioInputFormatIsUsable(24_000, 1))
        XCTAssertTrue(TapQAudioInputFormatIsUsable(48_000, 2))
    }

    func testObjectiveCBridgeContainsStartAndTeardownExceptions() {
        let capture = TapQThrowingAudioCaptureEngine()
        var startError: NSError?
        let started = TapQAudioCaptureEngineStart(
            capture,
            1024,
            { _, _ in XCTFail("failed capture must not deliver audio") },
            &startError
        )

        XCTAssertFalse(started)
        XCTAssertEqual(
            startError?.userInfo[TapQAudioCaptureFailureStageKey] as? String,
            "audio_setup"
        )
        XCTAssertTrue(
            startError?.localizedDescription.contains("simulated input-node") == true
        )
        XCTAssertEqual(capture.inputNodeCallCount, 1)

        var stopError: NSError?
        XCTAssertFalse(TapQAudioCaptureEngineStop(capture, &stopError))
        XCTAssertEqual(
            stopError?.userInfo[TapQAudioCaptureFailureStageKey] as? String,
            "audio_teardown"
        )
        XCTAssertTrue(stopError?.localizedDescription.contains("engine-running") == true)
        XCTAssertEqual(capture.runningCallCount, 1)
        XCTAssertEqual(
            capture.resetCallCount,
            1,
            "reset still runs after the independent stop exception is caught"
        )
    }

    func testAudioSourceControllerUsesFreshSourceOnRestartAndIsIdempotent() {
        let first = FakeAudioSource()
        let second = FakeAudioSource()
        let sources = [first, second]
        var factoryCalls = 0
        let controller = VoiceAudioSourceController {
            defer { factoryCalls += 1 }
            return sources[factoryCalls]
        }

        guard case .started = controller.start(onBuffer: { _, _ in }, onInvalidation: { _ in })
        else { return XCTFail("first source should start") }
        guard case .alreadyRunning = controller.start(
            onBuffer: { _, _ in },
            onInvalidation: { _ in }
        ) else { return XCTFail("duplicate start should be idempotent") }
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(first.starts, 1)

        controller.stop()
        controller.stop()
        XCTAssertEqual(first.stops, 1)

        guard case .started = controller.start(onBuffer: { _, _ in }, onInvalidation: { _ in })
        else { return XCTFail("restart should use a fresh source") }
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(second.starts, 1)
    }

    func testAudioSourceControllerFailsClosedAndCanRetryFresh() {
        let failure = VoiceAudioSourceFailure(
            stage: .inputFormat,
            detail: "unavailable input (sample_rate=0, channels=1)"
        )
        let rejected = FakeAudioSource()
        rejected.startFailure = failure
        let recovered = FakeAudioSource()
        let sources = [rejected, recovered]
        var factoryCalls = 0
        let controller = VoiceAudioSourceController {
            defer { factoryCalls += 1 }
            return sources[factoryCalls]
        }

        guard case .failed(let error) = controller.start(
            onBuffer: { _, _ in },
            onInvalidation: { _ in }
        ) else { return XCTFail("invalid input must fail") }
        XCTAssertEqual(error as? VoiceAudioSourceFailure, failure)
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(rejected.stops, 1)

        guard case .started = controller.start(onBuffer: { _, _ in }, onInvalidation: { _ in })
        else { return XCTFail("later route should get a fresh source") }
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(factoryCalls, 2)
    }

    func testConfigurationChangeInvalidatesOnlyItsOwnSourceGeneration() {
        let first = FakeAudioSource()
        let second = FakeAudioSource()
        let sources = [first, second]
        var factoryCalls = 0
        var invalidations: [VoiceAudioSourceFailure] = []
        let controller = VoiceAudioSourceController {
            defer { factoryCalls += 1 }
            return sources[factoryCalls]
        }
        let invalidationHandler: @MainActor (VoiceAudioSourceFailure) -> Void = {
            invalidations.append($0)
        }

        guard case .started = controller.start(
            onBuffer: { _, _ in },
            onInvalidation: invalidationHandler
        ) else { return XCTFail("first source should start") }
        first.invalidate()
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(invalidations.count, 1)

        guard case .started = controller.start(
            onBuffer: { _, _ in },
            onInvalidation: invalidationHandler
        ) else { return XCTFail("second source should start") }
        first.invalidate()
        XCTAssertTrue(controller.isRunning, "stale route callback must not stop new input")
        XCTAssertEqual(second.stops, 0)
        XCTAssertEqual(invalidations.count, 1)

        second.invalidate()
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(second.stops, 1)
        XCTAssertEqual(invalidations.count, 2)
    }

    func testConfigurationChangeDuringStartFailsClosed() {
        let source = FakeAudioSource()
        let failure = VoiceAudioSourceFailure(
            stage: .configurationChanged,
            detail: "route changed during start"
        )
        source.synchronousInvalidation = failure
        var invalidations: [VoiceAudioSourceFailure] = []
        let controller = VoiceAudioSourceController { source }

        guard case .failed(let error) = controller.start(
            onBuffer: { _, _ in },
            onInvalidation: { invalidations.append($0) }
        ) else { return XCTFail("route change during start must fail the source") }

        XCTAssertEqual(error as? VoiceAudioSourceFailure, failure)
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(invalidations, [failure])
    }

    func testTTSCompletionReopenFailsClosedWithoutStartingRecognition() {
        let recognizer = FakeRecognizer()
        let source = FakeAudioSource()
        source.startFailure = VoiceAudioSourceFailure(
            stage: .audioSetup,
            detail: "NSInternalInconsistencyException: format mismatch"
        )
        let sink = RecordingSink()
        let listener = VoiceListener(
            recognizer: recognizer,
            makeAudioSource: { source },
            diagnosticSink: sink
        )
        let activity = FakeActivity()
        let gated = SpeechGatedVoice(wrapping: listener, activity: activity)

        activity.setSpeaking(true)
        gated.start { _ in XCTFail("failed voice source cannot emit a command") }
        XCTAssertEqual(source.starts, 0)
        activity.setSpeaking(false)

        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(source.stops, 1)
        XCTAssertFalse(listener.isRunningForTesting)
        XCTAssertEqual(recognizer.requests.count, 0)
        let failure = sink.events.last { $0.name == "capture.start_failed" }
        XCTAssertEqual(failure?.level, .warning)
        XCTAssertEqual(failure?.fields["stage"], "audio_setup")
        XCTAssertTrue(failure?.fields["error"]?.contains("format mismatch") == true)

        // Voice failure is local to the source; ordinary window teardown remains safe.
        gated.stop()
        XCTAssertEqual(source.stops, 1)
    }

    func testListenerRestartIgnoresLateRecognitionAndRouteCallbacks() async {
        let recognizer = FakeRecognizer()
        let first = FakeAudioSource()
        let second = FakeAudioSource()
        let sources = [first, second]
        var factoryCalls = 0
        let listener = VoiceListener(
            recognizer: recognizer,
            makeAudioSource: {
                defer { factoryCalls += 1 }
                return sources[factoryCalls]
            }
        )

        listener.start { _ in }
        listener.start { _ in XCTFail("duplicate start must not replace the session") }
        XCTAssertTrue(listener.isRunningForTesting)
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(recognizer.requests.count, 1)
        XCTAssertTrue(recognizer.requests[0].requiresOnDeviceRecognition)

        listener.stop()
        listener.stop()
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(recognizer.tasks[0].cancellations, 1)

        listener.start { _ in }
        XCTAssertTrue(listener.isRunningForTesting)
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(recognizer.requests.count, 2)

        recognizer.fail(call: 0)
        await Task.yield()
        XCTAssertTrue(
            listener.isRunningForTesting,
            "late error from generation 1 must not tear down generation 2"
        )
        XCTAssertEqual(second.stops, 0)

        first.invalidate()
        XCTAssertTrue(
            listener.isRunningForTesting,
            "late route callback from generation 1 must not tear down generation 2"
        )
        XCTAssertEqual(second.stops, 0)

        second.invalidate()
        XCTAssertFalse(listener.isRunningForTesting)
        XCTAssertEqual(second.stops, 1)
        XCTAssertEqual(recognizer.tasks[1].cancellations, 1)
    }

    func testNilRecognitionTaskTearsDownCapture() {
        let recognizer = FakeRecognizer()
        recognizer.returnsTask = false
        let source = FakeAudioSource()
        let sink = RecordingSink()
        let listener = VoiceListener(
            recognizer: recognizer,
            makeAudioSource: { source },
            diagnosticSink: sink
        )

        listener.start { _ in }

        XCTAssertFalse(listener.isRunningForTesting)
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(
            sink.events.last { $0.name == "recognition.start_failed" }?.fields["reason"],
            "task_unavailable"
        )
    }

    // MARK: - Partial transcripts must not fire commands that decide something

    /// The live failure, twice on hardware, 2026-08-27. The wearer says "ok, skip the
    /// command"; the recognizer's first partial is "OK"; the grammar reads that fragment as
    /// an approval — correctly, for that text — and the listener used to fire it and tear
    /// the recognizer down before the word "skip" existed. The wearer meant skip; the
    /// runtime approved.
    func testPartialOKThenFinalSkipDefersTheRequestAndNeverApprovesIt() async {
        let recognizer = FakeRecognizer()
        let source = FakeAudioSource()
        let listener = VoiceListener(recognizer: recognizer, makeAudioSource: { source })
        var commands: [VoiceCommand] = []
        listener.start { commands.append($0) }

        listener.deliverRecognitionForTesting(transcript: "OK")
        XCTAssertEqual(commands, [], "an approval matched on a fragment is not an approval")
        XCTAssertTrue(
            listener.isRunningForTesting,
            "the recognizer must still be listening, or the rest of the sentence is lost"
        )

        listener.deliverRecognitionForTesting(
            transcript: "ok skip the command",
            isFinal: true
        )
        XCTAssertEqual(commands, [.skip])
        XCTAssertFalse(listener.isRunningForTesting)
    }

    func testApprovalOnAPartialIsHeldAndTheSameTextAsFinalApproves() async {
        let recognizer = FakeRecognizer()
        let source = FakeAudioSource()
        let sink = RecordingSink()
        let listener = VoiceListener(
            recognizer: recognizer,
            makeAudioSource: { source },
            diagnosticSink: sink
        )
        var commands: [VoiceCommand] = []
        listener.start { commands.append($0) }

        listener.deliverRecognitionForTesting(transcript: "yes")
        XCTAssertEqual(commands, [])
        let deferred = sink.events.last { $0.name == "command.deferred" }
        XCTAssertEqual(deferred?.fields["reason"], "awaiting_stable_transcript",
                       "the one delay a wearer can feel has to be in the log file")

        listener.deliverRecognitionForTesting(transcript: "yes", isFinal: true)
        XCTAssertEqual(commands, [.yes])
    }

    /// The stability release. `SFSpeechRecognizer` fed from a live buffer does not reliably
    /// flag anything final before the audio is closed, so an approval that waited for
    /// finality alone would never resolve its window at all: text that has stopped changing
    /// has to be enough.
    func testApprovalFiresOnceThePartialTranscriptStopsChanging() async {
        let recognizer = FakeRecognizer()
        let source = FakeAudioSource()
        let listener = VoiceListener(
            recognizer: recognizer,
            makeAudioSource: { source },
            stabilityWindow: 0.02
        )
        var commands: [VoiceCommand] = []
        listener.start { commands.append($0) }

        listener.deliverRecognitionForTesting(transcript: "yes")
        XCTAssertEqual(commands, [], "not before the window has elapsed")

        // Polling rather than an expectation: the re-check lands on a later main-actor
        // turn, and the house rule is no `XCTestExpectation` for actor hops.
        var attempts = 400
        while commands.isEmpty, attempts > 0 {
            attempts -= 1
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(commands, [.yes])
        XCTAssertFalse(listener.isRunningForTesting)
        XCTAssertEqual(source.stops, 1)
    }

    /// Informational commands resolve nothing and leave the window open, so a fragment that
    /// triggers one costs a re-read at worst — and answering instantly is most of what
    /// makes the channel feel alive.
    func testInformationalCommandsStillFireOnTheFirstPartial() async {
        for (transcript, expected) in [("details", VoiceCommand.details),
                                       ("repeat that", .repeatRequest),
                                       ("status", .status),
                                       ("what did you just do", .whatChanged)] {
            let recognizer = FakeRecognizer()
            let source = FakeAudioSource()
            let listener = VoiceListener(recognizer: recognizer, makeAudioSource: { source })
            var commands: [VoiceCommand] = []
            listener.start { commands.append($0) }

            listener.deliverRecognitionForTesting(transcript: transcript)
            XCTAssertEqual(commands, [expected], "'\(transcript)' mutates nothing")
        }
    }

    /// One settled transcript and nothing else — the shape a backend that transcribes
    /// server-side produces. Unchanged by the gate: it fires on arrival.
    func testASingleFinalTranscriptResolvesTheWindowImmediately() async {
        let recognizer = FakeRecognizer()
        let source = FakeAudioSource()
        let listener = VoiceListener(recognizer: recognizer, makeAudioSource: { source })
        var commands: [VoiceCommand] = []
        listener.start { commands.append($0) }

        listener.deliverRecognitionForTesting(transcript: "yes please", isFinal: true)
        XCTAssertEqual(commands, [.yes])
    }

    /// A command still waiting for its transcript to settle when the window closes is one
    /// the wearer never got a decision out of. It is dropped, not flushed — the request goes
    /// back to the on-screen prompt, which is what TapQ does with every unanswered window.
    func testAHeldCommandIsDroppedWhenTheWindowCloses() async {
        let recognizer = FakeRecognizer()
        let source = FakeAudioSource()
        let listener = VoiceListener(
            recognizer: recognizer,
            makeAudioSource: { source },
            stabilityWindow: 0.02
        )
        var commands: [VoiceCommand] = []
        listener.start { commands.append($0) }

        listener.deliverRecognitionForTesting(transcript: "yes")
        listener.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(commands, [], "a closed window must not be resolved by its own timer")
    }

    func testEngineStartFailureLogsStageAndTearsDownCapture() {
        let recognizer = FakeRecognizer()
        let source = FakeAudioSource()
        source.startFailure = VoiceAudioSourceFailure(
            stage: .engineStart,
            detail: "input device disappeared"
        )
        let sink = RecordingSink()
        let listener = VoiceListener(
            recognizer: recognizer,
            makeAudioSource: { source },
            diagnosticSink: sink
        )

        listener.start { _ in }

        XCTAssertFalse(listener.isRunningForTesting)
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(recognizer.requests.count, 0)
        let failure = sink.events.last { $0.name == "capture.start_failed" }
        XCTAssertEqual(failure?.fields["stage"], "engine_start")
        XCTAssertEqual(failure?.fields["error"], "input device disappeared")
    }
}
