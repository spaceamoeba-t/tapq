import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

@MainActor
final class InputArbiterTests: XCTestCase {
    @MainActor
    final class FakeGestures: HeadGestureProviding {
        var onGesture: (@MainActor (HeadGesture) -> Void)?
        var stopped = false
        func start(onGesture: @escaping @MainActor (HeadGesture) -> Void) { self.onGesture = onGesture }
        func stop() { stopped = true }
        func fire(_ gesture: HeadGesture) { onGesture?(gesture) }
    }

    @MainActor
    final class FakeVoice: VoiceCommandProviding {
        var onCommand: (@MainActor (VoiceCommand) -> Void)?
        var stopped = false
        func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) { self.onCommand = onCommand }
        func stop() { stopped = true }
        func fire(_ command: VoiceCommand) { onCommand?(command) }
    }

    @MainActor
    final class FakeTaps: TapCommandProviding {
        var onTap: (@MainActor (TapCommand) -> Void)?
        var stopped = false
        func start(onTap: @escaping @MainActor (TapCommand) -> Void) { self.onTap = onTap }
        func stop() { stopped = true }
        func fire() { onTap?(.tap) }
    }

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
    }

    private func tick() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    func testNodResolvesAllowAndStopsVoice() async {
        let gestures = FakeGestures()
        let voice = FakeVoice()
        let arbiter = InputArbiter(gestures: gestures, voice: voice)

        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        gestures.fire(.nod)

        let result = await task.value
        XCTAssertEqual(result, .allow)
        XCTAssertTrue(voice.stopped)
        XCTAssertTrue(gestures.stopped)
    }

    func testVoiceNoResolvesDeny() async {
        let gestures = FakeGestures()
        let voice = FakeVoice()
        let arbiter = InputArbiter(gestures: gestures, voice: voice)

        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        voice.fire(.no)

        let result = await task.value
        XCTAssertEqual(result, .deny)
    }

    func testTimeoutResolvesNil() async {
        let gestures = FakeGestures()
        let voice = FakeVoice()
        let arbiter = InputArbiter(gestures: gestures, voice: voice)

        let result = await arbiter.listen(timeout: 0.05)
        XCTAssertNil(result)
        XCTAssertTrue(gestures.stopped)
        XCTAssertTrue(voice.stopped)
    }

    func testFirstInputWins() async {
        let gestures = FakeGestures()
        let voice = FakeVoice()
        let arbiter = InputArbiter(gestures: gestures, voice: voice)

        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        gestures.fire(.nod)
        voice.fire(.no) // ignored — window already resolved

        let result = await task.value
        XCTAssertEqual(result, .allow)
    }

    func testTapResolvesAllowAndStopsOthers() async {
        let gestures = FakeGestures()
        let voice = FakeVoice()
        let taps = FakeTaps()
        let arbiter = InputArbiter(gestures: gestures, voice: voice, taps: taps)

        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        taps.fire()

        let result = await task.value
        XCTAssertEqual(result, .allow)
        XCTAssertTrue(gestures.stopped)
        XCTAssertTrue(voice.stopped)
        XCTAssertTrue(taps.stopped)
    }

    func testFirstInputWinsAcrossTapAndShake() async {
        let gestures = FakeGestures()
        let taps = FakeTaps()
        let arbiter = InputArbiter(gestures: gestures, voice: nil, taps: taps)

        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        taps.fire()
        gestures.fire(.shake) // ignored — tap already resolved the window

        let result = await task.value
        XCTAssertEqual(result, .allow)
    }

    func testOverlappingListenResolvesStaleWindowAsTimeout() async {
        let gestures = FakeGestures()
        let voice = FakeVoice()
        let arbiter = InputArbiter(gestures: gestures, voice: voice)

        let first = Task { await arbiter.listen(timeout: 5) }
        await tick()
        let second = Task { await arbiter.listen(timeout: 5) }
        await tick()

        // The stale window resolved nil (fail-open) instead of hanging/leaking.
        let firstResult = await first.value
        XCTAssertNil(firstResult)

        gestures.fire(.nod)
        let secondResult = await second.value
        XCTAssertEqual(secondResult, .allow)
    }

    func testCancelResolvesPendingListenAsNil() async {
        let gestures = FakeGestures()
        let arbiter = InputArbiter(gestures: gestures, voice: nil)
        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        arbiter.cancel()
        let result = await task.value
        XCTAssertNil(result, "cancelled window resolves as timeout (fail-open)")
        XCTAssertTrue(gestures.stopped)
    }

    func testCancelWithoutPendingListenIsNoOp() async {
        let arbiter = InputArbiter(gestures: nil, voice: nil)
        arbiter.cancel() // must not crash or resume anything
    }

    @MainActor
    final class FakeActivity: SpeechActivitySignaling {
        private(set) var isSpeaking = false
        var onSpeakingChange: (@MainActor (Bool) -> Void)?
        func setSpeaking(_ speaking: Bool) {
            guard speaking != isSpeaking else { return }
            isSpeaking = speaking
            onSpeakingChange?(speaking)
        }
    }

    func testVoiceClosedWhileSpeakingOpensOnIdle() async {
        let gestures = FakeGestures()
        let voice = FakeVoice()
        let activity = FakeActivity()
        activity.setSpeaking(true) // the prompt TTS was enqueued before the window opened
        let arbiter = InputArbiter(
            gestures: gestures, voice: SpeechGatedVoice(wrapping: voice, activity: activity))

        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        XCTAssertNotNil(gestures.onGesture, "motion channel opens immediately (barge-in)")
        XCTAssertNil(voice.onCommand, "mic stays closed while the engine speaks")

        activity.setSpeaking(false)
        await tick()
        XCTAssertNotNil(voice.onCommand, "mic opens once the engine drains")

        voice.fire(.yes)
        let result = await task.value
        XCTAssertEqual(result, .allow)
    }

    func testNotificationMidWindowNeverAnswersTheWindow() async {
        // THE deferred P1 case: a second session's Stop hook speaks "Claude finished.
        // <summary>" while this window's mic is open; summary tokens ("stop", "ok",
        // "two") must not resolve the window.
        let voice = FakeVoice()
        let activity = FakeActivity()
        let arbiter = InputArbiter(
            gestures: nil, voice: SpeechGatedVoice(wrapping: voice, activity: activity))

        let task = Task { await arbiter.listen(timeout: 1) }
        await tick()
        XCTAssertNotNil(voice.onCommand, "mic open while idle")

        activity.setSpeaking(true)
        voice.fire(.no) // "…stop…" matched from the announcement on the recognizer hop
        activity.setSpeaking(false)
        await tick()

        voice.fire(.yes) // the user answers after the announcement finishes
        let result = await task.value
        XCTAssertEqual(result, .allow, "the announcement must not have resolved the window")
    }

    func testGestureWhileSpeakingResolvesAndVoiceNeverOpens() async {
        let gestures = FakeGestures()
        let voice = FakeVoice()
        let activity = FakeActivity()
        activity.setSpeaking(true)
        let arbiter = InputArbiter(
            gestures: gestures, voice: SpeechGatedVoice(wrapping: voice, activity: activity))

        let task = Task { await arbiter.listen(timeout: 5) }
        await tick()
        gestures.fire(.nod) // barge-in: user nods while the prompt is still speaking
        let result = await task.value
        XCTAssertEqual(result, .allow)

        activity.setSpeaking(false) // TTS finishes after the window already resolved
        await tick()
        XCTAssertNil(voice.onCommand, "mic must not open after the window resolved")
    }

    // MARK: - The clock starts when the wearer can be heard (VoiceTurnTiming)

    /// A voice channel that knows when it is listening and whether a sentence is in flight
    /// — the realtime provider's two facts, scripted.
    @MainActor
    final class FakeTimedVoice: VoiceCommandProviding, VoiceTurnTiming {
        var onCommand: (@MainActor (VoiceCommand) -> Void)?
        var isListening = true
        var isWearerTurnUnresolved = false
        func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) { self.onCommand = onCommand }
        func stop() {}
        func fireYes() { onCommand?(.yes) }
    }

    /// A sleep that advances a virtual clock and lets the test script flip the voice
    /// channel's facts at chosen instants, so the arbiter's waits are measured in
    /// microseconds rather than raced against the wall clock.
    @MainActor
    final class VirtualSleep {
        private(set) var elapsed: TimeInterval = 0
        var onAdvance: (@MainActor (TimeInterval) -> Void)?
        func sleep(_ seconds: TimeInterval) async {
            elapsed += seconds
            onAdvance?(elapsed)
            await Task.yield()
        }
    }

    private func timedArbiter(_ voice: FakeTimedVoice, sleep: VirtualSleep,
                              sink: RecordingSink = RecordingSink()) -> InputArbiter {
        InputArbiter(gestures: nil, voice: voice, diagnosticSink: sink,
                     timeoutSleep: { await sleep.sleep($0) })
    }

    func testTheClockWaitsForTheVoiceChannelToStartListening() async {
        let voice = FakeTimedVoice()
        voice.isListening = false
        let sleep = VirtualSleep()
        sleep.onAdvance = { elapsed in if elapsed >= 3 { voice.isListening = true } }
        let sink = RecordingSink()
        let arbiter = timedArbiter(voice, sleep: sleep, sink: sink)

        let result = await arbiter.listen(timeout: 5)

        XCTAssertNil(result)
        XCTAssertEqual(sleep.elapsed, 8, accuracy: InputArbiter.timingPollInterval,
                       "three seconds of pre-roll, then the five the wearer was given")
        XCTAssertEqual(arbiter.lastListenExtension, 3, accuracy: InputArbiter.timingPollInterval)
        XCTAssertTrue(sink.names.contains("listen.preroll_credited"))
    }

    func testAChannelThatNeverListensStillTimesOut() async {
        let voice = FakeTimedVoice()
        voice.isListening = false
        let sleep = VirtualSleep()
        let arbiter = timedArbiter(voice, sleep: sleep)

        let result = await arbiter.listen(timeout: 5)

        XCTAssertNil(result)
        XCTAssertEqual(sleep.elapsed, InputArbiter.maxListenPreRoll + 5,
                       accuracy: InputArbiter.timingPollInterval)
        XCTAssertEqual(arbiter.lastListenExtension, InputArbiter.maxListenPreRoll,
                       accuracy: InputArbiter.timingPollInterval)
    }

    func testASentenceInProgressAtTheDeadlineIsWaitedOut() async {
        let voice = FakeTimedVoice()
        voice.isWearerTurnUnresolved = true
        let sleep = VirtualSleep()
        sleep.onAdvance = { elapsed in if elapsed >= 7 { voice.isWearerTurnUnresolved = false } }
        let sink = RecordingSink()
        let arbiter = timedArbiter(voice, sleep: sleep, sink: sink)

        let result = await arbiter.listen(timeout: 5)

        XCTAssertNil(result, "waiting out the sentence is not resolving the window")
        XCTAssertEqual(sleep.elapsed, 7, accuracy: InputArbiter.timingPollInterval)
        XCTAssertEqual(arbiter.lastListenExtension, 2, accuracy: InputArbiter.timingPollInterval)
        XCTAssertTrue(sink.names.contains("listen.extended_for_turn"))
    }

    func testTheMidSentenceWaitIsBounded() async {
        let voice = FakeTimedVoice()
        voice.isWearerTurnUnresolved = true
        let sleep = VirtualSleep()
        let arbiter = timedArbiter(voice, sleep: sleep)

        _ = await arbiter.listen(timeout: 5)

        XCTAssertEqual(sleep.elapsed, 5 + InputArbiter.maxMidSentenceExtension,
                       accuracy: InputArbiter.timingPollInterval,
                       "a signal stuck on speaking costs one window, not the run")
    }

    func testACommandDuringTheWaitStillResolvesTheWindow() async {
        let voice = FakeTimedVoice()
        voice.isWearerTurnUnresolved = true
        let sleep = VirtualSleep()
        sleep.onAdvance = { elapsed in if elapsed >= 6 { voice.fireYes() } }
        let arbiter = timedArbiter(voice, sleep: sleep)

        let result = await arbiter.listen(timeout: 5)

        XCTAssertEqual(result, .allow, "the sentence the wait was for arrived as a command")
    }

    func testAVoiceWithoutTimingKeepsTheFixedClock() async {
        let voice = FakeVoice()
        let sleep = VirtualSleep()
        let arbiter = InputArbiter(gestures: nil, voice: voice,
                                   timeoutSleep: { await sleep.sleep($0) })

        let result = await arbiter.listen(timeout: 5)

        XCTAssertNil(result)
        XCTAssertEqual(sleep.elapsed, 5)
        XCTAssertEqual(arbiter.lastListenExtension, 0)
    }
}
