import XCTest
import AVFoundation
import Speech
import TapQContracts
@testable import TapQAppleAdapters

/// A mutable cell shared between a test and the closures it injects. The listener's clock
/// seam is deliberately non-isolated, so the state behind it cannot live on the fixture.
private final class Box<Value> {
    var value: Value
    init(_ value: Value) {
        self.value = value
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

    func named(_ name: String) -> [TapQDiagnosticEvent] {
        events.filter { $0.name == name }
    }
}

@MainActor
private final class FakeRecognitionTask: VoiceRecognitionTasking {
    private(set) var cancellations = 0
    func cancel() {
        cancellations += 1
    }
}

@MainActor
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
        _ = resultHandler
        guard returnsTask else { return nil }
        let task = FakeRecognitionTask()
        tasks.append(task)
        return task
    }
}

@MainActor
private final class FakeAudioSource: VoiceAudioSource {
    private(set) var starts = 0
    private(set) var stops = 0
    /// The listener's buffer sink, kept so a test can play audio into the request.
    private(set) var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onInvalidation: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
    ) throws {
        self.onBuffer = onBuffer
        _ = onInvalidation
        starts += 1
    }

    /// One buffer at the given peak, on a 0...1 scale.
    func play(peak: Float) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        buffer.floatChannelData![0][0] = peak
        onBuffer?(buffer, AVAudioTime(hostTime: 0))
    }

    func stop() {
        stops += 1
    }
}

private enum TestFailure: Error {
    case expected
}

/// Everything one listener needs, with the recognizer, the microphone, the back-off wait
/// and the clock all faked, so the restart ladder is exercised in microseconds.
@MainActor
private final class Fixture {
    let recognizer: FakeRecognizer
    let sink: RecordingSink
    let sources: Box<[FakeAudioSource]>
    let sleeps: Box<[TimeInterval]>
    let clock: Box<TimeInterval>
    let wakes = Box<[String]>([])
    let stopped = Box<[String]>([])
    let listener: WakeWordListener

    init(phrase: String = WakeWordListener.defaultPhrase,
         levelReportInterval: TimeInterval = WakeWordListener.defaultLevelReportInterval) {
        let recognizer = FakeRecognizer()
        let sink = RecordingSink()
        let sources = Box<[FakeAudioSource]>([])
        let sleeps = Box<[TimeInterval]>([])
        let clock = Box<TimeInterval>(0)
        self.recognizer = recognizer
        self.sink = sink
        self.sources = sources
        self.sleeps = sleeps
        self.clock = clock
        self.listener = WakeWordListener(
            phrase: phrase,
            recognizer: recognizer,
            makeAudioSource: {
                let source = FakeAudioSource()
                sources.value.append(source)
                return source
            },
            diagnosticSink: sink,
            sleep: { seconds in sleeps.value.append(seconds) },
            monotonicNow: { clock.value },
            levelReportInterval: levelReportInterval
        )
        let stopped = self.stopped
        listener.onStopped = { stopped.value.append($0) }
    }

    func start() {
        let wakes = self.wakes
        listener.start { wakes.value.append($0) }
    }
}

@MainActor
final class WakeWordListenerTests: XCTestCase {
    func testStartOpensOnePartialOnDeviceRequest() async {
        let fixture = Fixture()
        fixture.start()

        XCTAssertTrue(fixture.listener.isSpotting)
        XCTAssertEqual(fixture.recognizer.requests.count, 1)
        XCTAssertEqual(fixture.sources.value.count, 1)
        XCTAssertEqual(fixture.sources.value[0].starts, 1)

        let request = fixture.recognizer.requests[0]
        XCTAssertTrue(request.shouldReportPartialResults)
        XCTAssertTrue(request.requiresOnDeviceRecognition)

        let started = fixture.sink.named("listening.started")
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.fields["locale"], "en-US")
        XCTAssertEqual(started.first?.fields["on_device"], "true")
        XCTAssertEqual(started.first?.category, "WakeWord")
    }

    func testOffDeviceRecognizerIsRecordedAndStillListens() async {
        let fixture = Fixture()
        fixture.recognizer.supportsOnDeviceRecognition = false
        fixture.start()

        XCTAssertFalse(fixture.recognizer.requests[0].requiresOnDeviceRecognition)
        XCTAssertEqual(
            fixture.sink.named("listening.started").first?.fields["on_device"],
            "false"
        )
    }

    func testFiresOnceForAPartialContainingThePhraseThenRestarts() async {
        let fixture = Fixture()
        fixture.start()
        let generation = fixture.listener.generationForTesting

        let heard = "Hey, Tap Q — set up a Swift package"
        fixture.listener.deliverRecognitionForTesting(transcript: heard)
        XCTAssertEqual(fixture.wakes.value, [heard])

        // A second callback from the same request cannot fire the word again: the request
        // that carried the phrase was ended by the hit.
        fixture.listener.deliverRecognitionForTesting(
            transcript: "Hey tap q, and again", generation: generation)
        XCTAssertEqual(fixture.wakes.value.count, 1)
        XCTAssertTrue(fixture.listener.isSpotting, "a hit is not a stop")

        await fixture.listener.awaitPendingRestartForTesting()
        XCTAssertEqual(fixture.recognizer.requests.count, 2,
                       "the sentence after the phrase belongs to a new request")
        XCTAssertEqual(fixture.sources.value.count, 2)
        XCTAssertEqual(fixture.sources.value[0].stops, 1)
        XCTAssertEqual(fixture.recognizer.tasks[0].cancellations, 1)
        XCTAssertEqual(fixture.sleeps.value, [], "a hit restarts without back-off")
    }

    func testWakeDiagnosticKeepsTheTranscriptOutOfInfoLevel() async {
        let fixture = Fixture()
        fixture.start()
        let heard = "hey tapq"
        fixture.listener.deliverRecognitionForTesting(transcript: heard)

        let fired = fixture.sink.named("wake.fired")
        XCTAssertEqual(fired.count, 1)
        guard let firedEvent = fired.first else { return XCTFail("no wake.fired event") }
        XCTAssertEqual(firedEvent.level, .info)
        XCTAssertEqual(firedEvent.fields["transcript_length"], "\(heard.count)")
        XCTAssertNil(firedEvent.fields["transcript"],
                     "an info-level wake event never carries what was heard")

        let debugged = fixture.sink.named("wake.transcript")
        XCTAssertEqual(debugged.first?.level, .debug)
        XCTAssertEqual(debugged.first?.fields["transcript"], heard)
    }

    func testDoesNotFireOnTapTheQueue() async {
        let fixture = Fixture()
        fixture.start()

        fixture.listener.deliverRecognitionForTesting(
            transcript: "hey, tap the queue for me")
        XCTAssertTrue(fixture.wakes.value.isEmpty)
        XCTAssertTrue(fixture.listener.isSpotting)
        XCTAssertEqual(fixture.recognizer.requests.count, 1,
                       "an unmatched transcript does not disturb the request")
    }

    func testRestartsWhenTheRecognizerEndsALongLivedRequest() async {
        let fixture = Fixture()
        fixture.start()

        // On-device requests expire after about a minute. That is health, not failure.
        fixture.clock.value = 62
        fixture.listener.deliverRecognitionForTesting(transcript: "nothing", isFinal: true)
        await fixture.listener.awaitPendingRestartForTesting()

        XCTAssertTrue(fixture.listener.isSpotting)
        XCTAssertEqual(fixture.recognizer.requests.count, 2)
        XCTAssertEqual(fixture.sleeps.value, [], "a healthy request restarts immediately")
        let restarts = fixture.sink.named("restart")
        XCTAssertEqual(restarts.count, 1)
        XCTAssertEqual(restarts.first?.level, .debug)
        XCTAssertEqual(restarts.first?.fields["reason"], "request_ended")
        XCTAssertEqual(restarts.first?.fields["attempt"], "0")
    }

    // MARK: - The deaf-recognizer watchdog

    /// Plays speech-level audio into the current request across `reports` level reports.
    private func speak(into fixture: Fixture, reports: Int) async {
        for _ in 0..<reports {
            fixture.sources.value.last?.play(peak: 0.5)  // -6 dB
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Five seconds of speech into the listener's first request, with nothing answered,
    /// reopens it as a healthy restart: no back-off, no failure counted. Seen live
    /// 2026-09-04 with buffers reaching Apple's recognition client and no callback ever
    /// coming back — and the reopened request heard at once.
    func testSpeechLevelAudioWithNoCallbackReopensTheFirstRequest() async {
        let fixture = Fixture(levelReportInterval: 0.01)
        fixture.start()

        await speak(into: fixture, reports: WakeWordListener.firstRequestDeafReportLimit)
        await fixture.listener.awaitPendingRestartForTesting()

        XCTAssertTrue(fixture.listener.isSpotting)
        XCTAssertEqual(fixture.recognizer.requests.count, 2, "one reopen")
        XCTAssertEqual(fixture.sleeps.value, [], "a deaf request restarts at once")
        let deaf = fixture.sink.named("recognizer.deaf")
        XCTAssertEqual(deaf.count, 1)
        XCTAssertEqual(deaf.first?.level, .warning)
        XCTAssertEqual(deaf.first?.fields["restarts"], "1")
        XCTAssertEqual(fixture.sink.named("restart").last?.fields["reason"], "recognizer_deaf")
        XCTAssertFalse(fixture.sink.named("audio.level").isEmpty, "the level line is still logged")
        XCTAssertEqual(fixture.stopped.value, [])
    }

    /// A later request gets the full fifteen seconds: it is not the suspect one, and a
    /// wearer who starts talking the moment a window closes deserves the benefit.
    func testALaterRequestIsJudgedOnThreeReports() async {
        let fixture = Fixture(levelReportInterval: 0.01)
        fixture.start()
        await speak(into: fixture, reports: WakeWordListener.firstRequestDeafReportLimit)
        await fixture.listener.awaitPendingRestartForTesting()
        XCTAssertEqual(fixture.recognizer.requests.count, 2)

        await speak(into: fixture, reports: WakeWordListener.deafReportLimit - 1)
        XCTAssertEqual(fixture.recognizer.requests.count, 2, "two reports are not enough")
        await speak(into: fixture, reports: 1)
        await fixture.listener.awaitPendingRestartForTesting()
        XCTAssertEqual(fixture.recognizer.requests.count, 3)
        XCTAssertEqual(fixture.sink.named("recognizer.deaf").last?.fields["restarts"], "2")
    }

    /// The recognizer is told the product name in the spellings the matcher folds.
    func testTheRequestCarriesThePhraseAsContextualStrings() async {
        let fixture = Fixture()
        fixture.start()
        let strings = fixture.recognizer.requests.first?.contextualStrings ?? []
        XCTAssertTrue(strings.contains("hey tapq"), "\(strings)")
        XCTAssertTrue(strings.contains("hey tap Q"), "\(strings)")
        XCTAssertTrue(strings.contains("TapQ"), "\(strings)")
        XCTAssertEqual(WakeWordListener.contextualStrings(for: "ok computer"), ["ok computer"])
    }

    /// A request that has called back once is being heard, however loud the room: only
    /// silence from the recognizer counts, never silence from the wearer.
    func testACallbackDisarmsTheWatchdogForThatRequest() async {
        let fixture = Fixture(levelReportInterval: 0.01)
        fixture.start()
        fixture.listener.deliverRecognitionForTesting(transcript: "nothing yet")

        await speak(into: fixture, reports: WakeWordListener.deafReportLimit + 2)

        XCTAssertEqual(fixture.recognizer.requests.count, 1)
        XCTAssertTrue(fixture.sink.named("recognizer.deaf").isEmpty)
    }

    /// Quiet audio never trips it: a room with nobody speaking is not a deaf recognizer.
    func testQuietAudioWithNoCallbackIsNotDeafness() async {
        let fixture = Fixture(levelReportInterval: 0.01)
        fixture.start()
        for _ in 0..<(WakeWordListener.deafReportLimit + 2) {
            fixture.sources.value.last?.play(peak: 0.05)  // -26 dB, the room
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(fixture.recognizer.requests.count, 1)
        XCTAssertTrue(fixture.sink.named("recognizer.deaf").isEmpty)
    }

    /// Three deaf requests in a row, nothing heard between them, and the listener stops
    /// and says why — the honest outcome for a process whose recognizer will not answer.
    func testThreeDeafRequestsInARowGiveUp() async {
        let fixture = Fixture(levelReportInterval: 0.01)
        fixture.start()

        await speak(into: fixture, reports: WakeWordListener.firstRequestDeafReportLimit)
        await fixture.listener.awaitPendingRestartForTesting()
        for _ in 1..<WakeWordListener.deafRestartLimit {
            await speak(into: fixture, reports: WakeWordListener.deafReportLimit)
            await fixture.listener.awaitPendingRestartForTesting()
        }

        XCTAssertFalse(fixture.listener.isSpotting)
        XCTAssertEqual(fixture.stopped.value, ["recognizer_deaf"])
        XCTAssertEqual(fixture.recognizer.requests.count, WakeWordListener.deafRestartLimit)
        XCTAssertEqual(fixture.sink.named("stopped").first?.fields["reason"], "recognizer_deaf")
    }

    func testBacksOffAndGivesUpAfterTenConsecutiveFailures() async {
        let fixture = Fixture()
        fixture.start()

        for _ in 0..<9 {
            fixture.listener.deliverRecognitionForTesting(error: TestFailure.expected)
            await fixture.listener.awaitPendingRestartForTesting()
        }
        XCTAssertTrue(fixture.listener.isSpotting)
        XCTAssertEqual(fixture.recognizer.requests.count, 10)
        XCTAssertEqual(fixture.sleeps.value, [0.5, 1, 2, 4, 8, 8, 8, 8, 8])
        XCTAssertTrue(fixture.stopped.value.isEmpty)

        fixture.listener.deliverRecognitionForTesting(error: TestFailure.expected)
        XCTAssertFalse(fixture.listener.isSpotting)
        XCTAssertEqual(fixture.stopped.value, ["recognition_error"],
                       "onStopped fires exactly once")

        await fixture.listener.awaitPendingRestartForTesting()
        XCTAssertEqual(fixture.recognizer.requests.count, 10, "no eleventh attempt")
        XCTAssertEqual(fixture.sources.value.last?.stops, 1, "the microphone is released")

        let stopped = fixture.sink.named("stopped")
        XCTAssertEqual(stopped.count, 1)
        XCTAssertEqual(stopped.first?.level, .warning)
        XCTAssertEqual(stopped.first?.fields["reason"], "recognition_error")
    }

    func testALongLivedRequestResetsTheBackOff() async {
        let fixture = Fixture()
        fixture.start()

        for _ in 0..<3 {
            fixture.listener.deliverRecognitionForTesting(error: TestFailure.expected)
            await fixture.listener.awaitPendingRestartForTesting()
        }
        XCTAssertEqual(fixture.sleeps.value, [0.5, 1, 2])

        fixture.clock.value += 30
        fixture.listener.deliverRecognitionForTesting(transcript: "nothing", isFinal: true)
        await fixture.listener.awaitPendingRestartForTesting()

        fixture.listener.deliverRecognitionForTesting(error: TestFailure.expected)
        await fixture.listener.awaitPendingRestartForTesting()
        XCTAssertEqual(fixture.sleeps.value, [0.5, 1, 2, 0.5],
                       "a request that lived past the threshold clears the ladder")
        XCTAssertTrue(fixture.listener.isSpotting)
    }

    func testStopSuppressesALateCallbackAndIsIdempotent() async {
        let fixture = Fixture()
        fixture.start()
        let generation = fixture.listener.generationForTesting

        fixture.listener.stop()
        XCTAssertFalse(fixture.listener.isSpotting)
        XCTAssertEqual(fixture.sources.value[0].stops, 1)
        XCTAssertEqual(fixture.recognizer.tasks[0].cancellations, 1)

        fixture.listener.deliverRecognitionForTesting(
            transcript: "hey tapq", generation: generation)
        XCTAssertTrue(fixture.wakes.value.isEmpty, "a stopped listener never wakes")
        XCTAssertEqual(fixture.recognizer.requests.count, 1)

        fixture.listener.stop()
        XCTAssertEqual(fixture.sources.value.count, 1)
        XCTAssertEqual(fixture.sources.value[0].stops, 1)
        XCTAssertTrue(fixture.stopped.value.isEmpty,
                      "a caller's stop is not the spotter giving up")
    }

    func testStartWhileSpottingIsANoOp() async {
        let fixture = Fixture()
        fixture.start()
        fixture.start()

        XCTAssertEqual(fixture.recognizer.requests.count, 1)
        XCTAssertEqual(fixture.sources.value.count, 1)
        let skipped = fixture.sink.named("start.skipped")
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped.first?.fields["reason"], "already_running")
    }

    func testUnavailableRecognizerStopsBeforeListening() async {
        let fixture = Fixture()
        fixture.recognizer.isAvailable = false
        fixture.start()

        XCTAssertFalse(fixture.listener.isSpotting)
        XCTAssertTrue(fixture.recognizer.requests.isEmpty)
        XCTAssertTrue(fixture.sources.value.isEmpty, "the microphone is never opened")
        XCTAssertEqual(fixture.stopped.value, ["recognizer_unavailable"])
        let skipped = fixture.sink.named("start.skipped")
        XCTAssertEqual(skipped.first?.level, .warning)
        XCTAssertEqual(skipped.first?.fields["reason"], "recognizer_unavailable")
    }

    func testUnavailableRecognitionTaskCountsAsAFailedRequest() async {
        let fixture = Fixture()
        fixture.recognizer.returnsTask = false
        fixture.start()

        XCTAssertTrue(fixture.listener.isSpotting,
                      "a missing task is a restart, not a stop")
        XCTAssertEqual(fixture.sink.named("recognition.start_failed").count, 1)
        XCTAssertEqual(fixture.sources.value[0].stops, 1)
        // The wait itself happens inside the restart task; what is decided synchronously
        // is that there will be one, and how long it is.
        let restart = fixture.sink.named("restart").first
        XCTAssertEqual(restart?.fields["reason"], "task_unavailable")
        XCTAssertEqual(restart?.fields["attempt"], "1")
        XCTAssertEqual(restart?.fields["delay_ms"], "500")
    }

    func testMatcherAcceptsTheSpellingsTheRecognizerProduces() async {
        let phrase = WakeWordListener.defaultPhrase
        let heard = [
            "hey tapq",
            "Hey TapQ",
            "Hey, TapQ!",
            "hey tap q",
            "hey tap queue",
            "hey tap cue",
            "hey tap-q",
            "hey   tap    q",
            "ok hey tapq set up the parser",
            "so I said hey tap queue.",
        ]
        for transcript in heard {
            XCTAssertTrue(WakeWordListener.matches(transcript, phrase: phrase),
                          "\(transcript) should wake")
        }
    }

    func testMatcherRejectsNearMisses() async {
        let phrase = WakeWordListener.defaultPhrase
        let ignored = [
            "",
            "hey",
            "tapq",
            "hey tap the queue",
            "hey, tap it and queue it",
            "they tapq",
            "hey tapqueue",
            "hey q",
            "tapq hey",
        ]
        for transcript in ignored {
            XCTAssertFalse(WakeWordListener.matches(transcript, phrase: phrase),
                           "\(transcript) should not wake")
        }
    }

    func testMatcherNormalizesThePhraseTheSameWayAsTheTranscript() async {
        XCTAssertTrue(WakeWordListener.matches("hey tapq", phrase: "Hey, Tap-Q!"))
        XCTAssertTrue(
            WakeWordListener.matches("computer wake up", phrase: "computer wake up"))
        XCTAssertFalse(WakeWordListener.matches("hey tapq", phrase: ""))
        XCTAssertEqual(WakeWordListener.normalizedWords("Hey, Tap Queue!"), ["hey", "tapq"])
    }
}
