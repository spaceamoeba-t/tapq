import XCTest
@testable import TapQGestures
import TapQGestureContracts
import TapQDetectionBaseline

@MainActor
final class HeadGestureDetectorTests: XCTestCase {
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

    /// 6 samples, 0.04s apart (25Hz): p2p 0.7, 4 reversals, detection fires on sample 6.
    private static let zigzag: [Double] = [0.0, 0.35, -0.35, 0.35, -0.35, 0.0]
    /// Cross-axis noise small enough to keep dominance ratio >> 2.
    private static let flat: [Double] = [0.0, 0.01, -0.01, 0.01, -0.01, 0.0]

    private func makeDetector(
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) -> (HeadGestureDetector, () -> [HeadGesture]) {
        let detector = HeadGestureDetector(diagnosticSink: diagnosticSink)   // default config: doubleNodWindowSeconds 1.5, minDoubleNodGap 0.3 (sample buffer windowSeconds is 1.2)
        var emitted: [HeadGesture] = []
        detector.setGestureHandlerForTesting { emitted.append($0) }  // registers callback without touching CoreMotion
        return (detector, { emitted })
    }

    /// Feeds one nod burst starting at `t0`; detection fires at `t0 + 0.20`.
    private func feedNod(_ detector: HeadGestureDetector, at t0: TimeInterval) {
        for (i, v) in Self.zigzag.enumerated() {
            detector.ingestGesture(pitch: v, yaw: Self.flat[i], time: t0 + Double(i) * 0.04)
        }
    }

    private func feedShake(_ detector: HeadGestureDetector, at t0: TimeInterval) {
        for (i, v) in Self.zigzag.enumerated() {
            detector.ingestGesture(pitch: Self.flat[i], yaw: v, time: t0 + Double(i) * 0.04)
        }
    }

    func testAnalyzerDetectsTheTestWaveform() {
        // Localizes failures: if this breaks, the fixtures are wrong, not the detector.
        XCTAssertEqual(GestureAnalyzer().detect(pitch: Self.zigzag, yaw: Self.flat), .nod)
        XCTAssertEqual(GestureAnalyzer().detect(pitch: Self.flat, yaw: Self.zigzag), .shake)
    }

    func testDoubleNodWithinWindowEmitsSingleNod() {
        let (detector, emitted) = makeDetector()
        feedNod(detector, at: 0.0)   // detection at t=0.20 -> pending
        feedNod(detector, at: 0.8)   // detection at t=1.00, gap 0.8 in [0.3, 1.5] -> emit
        XCTAssertEqual(emitted(), [.nod])
    }

    func testSingleNodEmitsNothing() {
        let (detector, emitted) = makeDetector()
        feedNod(detector, at: 0.0)
        XCTAssertEqual(emitted(), [])
    }

    func testSecondNodTooSoonIsAbsorbedNotConfirmed() {
        let (detector, emitted) = makeDetector()
        feedNod(detector, at: 0.0)    // detection at t=0.20 -> pending
        feedNod(detector, at: 0.24)   // detection at t=0.44, gap 0.24 < 0.3 -> echo, absorbed
        XCTAssertEqual(emitted(), [])
    }

    func testSecondNodPastWindowDoesNotConfirm() {
        let (detector, emitted) = makeDetector()
        feedNod(detector, at: 0.0)    // detection at t=0.20 -> pending
        feedNod(detector, at: 2.0)    // detection at t=2.20, age 2.0 > 1.5 -> new first nod
        XCTAssertEqual(emitted(), [])
    }

    func testStaleFirstNodThenFreshPairConfirms() {
        let (detector, emitted) = makeDetector()
        feedNod(detector, at: 0.0)    // pending at 0.20, will expire
        feedNod(detector, at: 2.0)    // new first nod, pending at 2.20
        feedNod(detector, at: 2.8)    // detection at 3.00, gap 0.8 -> emit
        XCTAssertEqual(emitted(), [.nod])
    }

    func testDoubleShakeWithinWindowEmitsSingleShake() {
        let (detector, emitted) = makeDetector()
        feedShake(detector, at: 0.0)
        feedShake(detector, at: 0.8)
        XCTAssertEqual(emitted(), [.shake])
    }

    func testSingleShakeEmitsNothing() {
        let (detector, emitted) = makeDetector()
        feedShake(detector, at: 0.0)
        XCTAssertEqual(emitted(), [])
    }

    func testFirstShakeCancelsPendingFirstNod() {
        let (detector, emitted) = makeDetector()
        feedNod(detector, at: 0.0)     // pending at t=0.20
        feedShake(detector, at: 0.4)   // pending shake at t=0.60, pending nod cleared
        feedShake(detector, at: 1.2)   // confirmed shake at t=1.40
        XCTAssertEqual(emitted(), [.shake])
    }

    func testDebounceBlocksReemissionAfterConfirmedNod() {
        let (detector, emitted) = makeDetector()
        feedNod(detector, at: 0.0)
        feedNod(detector, at: 0.8)    // confirmed at t=1.00, lastEmit=1.00
        feedNod(detector, at: 1.2)    // detection at t=1.40 blocked by debounce (0.40 < 1.0)
        XCTAssertEqual(emitted(), [.nod])
    }

    func testMotionLossFiresCallbackOncePerSession() {
        let detector = HeadGestureDetector()
        var lost = 0
        detector.onMotionLost = { _ in lost += 1 }
        detector.beginListeningForTesting()
        detector.handleMotionLoss()
        detector.handleMotionLoss() // nil samples keep arriving after a disconnect
        XCTAssertEqual(lost, 1, "loss is signalled once per listening session")
    }

    func testMotionLossIgnoredWhenNotListening() {
        let detector = HeadGestureDetector()
        var lost = 0
        detector.onMotionLost = { _ in lost += 1 }
        detector.handleMotionLoss()
        XCTAssertEqual(lost, 0, "no window open — nothing to rescue")
    }

    func testMotionLossSignalsAgainOnNextSession() {
        let detector = HeadGestureDetector()
        var lost = 0
        detector.onMotionLost = { _ in lost += 1 }
        detector.beginListeningForTesting()
        detector.handleMotionLoss()
        detector.stop()
        detector.beginListeningForTesting()
        detector.handleMotionLoss()
        XCTAssertEqual(lost, 2)
    }

    // MARK: - Motion source seam

    @MainActor
    final class FakeMotionSource: HeadphoneMotionSource {
        typealias Handler = @MainActor (HeadMotionSample?, Error?) -> Void

        var available = true
        var availabilitySequence: [Bool] = []
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private var handler: Handler?
        private var subscriptions: [Handler] = []
        var onStart: (@MainActor (Int) -> Void)?
        var isDeviceMotionAvailable: Bool {
            guard !availabilitySequence.isEmpty else { return available }
            return availabilitySequence.removeFirst()
        }
        func startUpdates(_ handler: @escaping Handler) {
            startCount += 1
            self.handler = handler
            subscriptions.append(handler)
            onStart?(startCount)
        }
        func stopUpdates() {
            stopCount += 1
            handler = nil
        }
        func emit(pitch: Double, yaw: Double, at time: TimeInterval) {
            emit(HeadMotionSample(timestamp: time, pitch: pitch, yaw: yaw,
                                  accelerationMagnitude: 0, rotationMagnitude: 0))
        }
        func emit(_ sample: HeadMotionSample) { handler?(sample, nil) }
        func fail(_ error: Error? = nil) { handler?(nil, error) }
        func emit(_ sample: HeadMotionSample, fromSubscription index: Int) {
            subscriptions[index](sample, nil)
        }
        func fail(_ error: Error? = nil, fromSubscription index: Int) {
            subscriptions[index](nil, error)
        }
    }

    private func waitUntil(
        attempts: Int = 300,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    func testStartStreamsGesturesFromInjectedSource() {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)
        var emitted: [HeadGesture] = []
        detector.start { emitted.append($0) }
        // Two nod bursts 0.8s apart = double-nod, same waveform as feedNod.
        for t0 in [0.0, 0.8] {
            for (i, v) in Self.zigzag.enumerated() {
                source.emit(pitch: v, yaw: Self.flat[i], at: t0 + Double(i) * 0.04)
            }
        }
        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(emitted, [.nod])
    }

    func testSilentDetectionStreamRestartsOnceAndProcessesRecoveredSample() async {
        let source = FakeMotionSource()
        let sink = RecordingSink()
        let detector = HeadGestureDetector(
            source: source,
            firstSampleTimeout: 0.01,
            startupRestartBackoff: 0.005,
            diagnosticSink: sink
        )
        var lost = 0
        detector.onMotionLost = { _ in lost += 1 }
        source.onStart = { [weak source] attempt in
            guard attempt == 2 else { return }
            source?.emit(pitch: 0.1, yaw: 0.1, at: 1)
        }
        detector.start { (_: HeadGesture) in }

        let didRecover = await waitUntil {
            source.startCount == 2
                && sink.events.contains { $0.name == "motion.first_sample" }
        }
        XCTAssertTrue(didRecover)

        XCTAssertEqual(source.startCount, 2)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(lost, 0)
        XCTAssertEqual(sink.events.filter { $0.name == "motion.start_requested" }.count, 2)
        XCTAssertEqual(sink.events.filter { $0.name == "motion.start_timeout" }.count, 1)
        XCTAssertEqual(sink.events.filter { $0.name == "motion.restart_requested" }.count, 1)
        XCTAssertEqual(sink.events.filter { $0.name == "motion.first_sample" }.count, 1)
        XCTAssertNotNil(
            sink.events.first { $0.name == "motion.first_sample" }?.fields["latency_ms"]
        )
        detector.stop()
    }

    func testTwoSilentStartupAttemptsSignalMotionLossExactlyOnce() async {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(
            source: source,
            firstSampleTimeout: 0.01,
            startupRestartBackoff: 0.005
        )
        var losses: [MotionLossReason] = []
        detector.onMotionLost = { losses.append($0) }
        detector.start { (_: HeadGesture) in }

        let didFailThrough = await waitUntil { losses.count == 1 }
        XCTAssertTrue(didFailThrough)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(source.startCount, 2, "startup recovery is bounded to one restart")
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(losses, [.silentStream],
                       "a device that accepted the subscription and stayed mute is present, not absent")
        detector.stop()
    }

    func testSilentStartupRestartFindsDeviceGoneSignalsSilentStream() async {
        let source = FakeMotionSource()
        // The headphones go away while the mute subscription is open, so the restart's
        // post-backoff availability check finds nothing to resubscribe to. Flipping the
        // flag from `onStart` rather than scripting `availabilitySequence` keeps the test
        // independent of how many times the detector happens to probe availability —
        // `isDeviceMotionAvailable` consumes a scripted entry per read, including the one
        // the start-timeout diagnostic makes.
        source.onStart = { [weak source] _ in source?.available = false }
        let detector = HeadGestureDetector(
            source: source,
            firstSampleTimeout: 0.01,
            startupRestartBackoff: 0.005
        )
        var losses: [MotionLossReason] = []
        detector.onMotionLost = { losses.append($0) }
        detector.start { (_: HeadGesture) in }

        let didFailThrough = await waitUntil { losses.count == 1 }

        XCTAssertTrue(didFailThrough)
        XCTAssertEqual(source.startCount, 1, "the restart gave up before resubscribing")
        XCTAssertEqual(losses, [.silentStream],
                       "the window opened on a device that was there, so this is a loss, not an absence")
        detector.stop()
    }

    func testFirstSampleCancelsStartupWatchdog() async {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(
            source: source,
            firstSampleTimeout: 0.01,
            startupRestartBackoff: 0.005
        )
        var lost = 0
        detector.onMotionLost = { _ in lost += 1 }
        detector.start { (_: HeadGesture) in }
        source.emit(pitch: 0.1, yaw: 0.1, at: 1)

        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.stopCount, 0)
        XCTAssertEqual(lost, 0)
        detector.stop()
    }

    func testInterruptionGraceDoesNotDisarmSilentStartupRecovery() async {
        let source = FakeMotionSource()
        // This test covers the independent startup watchdog, not grace expiry. Keep the
        // grace far beyond the 10 ms watchdog and 5 ms backoff: on a loaded CI runner all
        // three tasks can resume after 200 ms, at which point a short grace correctly wins
        // the race and says nothing about whether the watchdog remained armed.
        let detector = HeadGestureDetector(
            source: source,
            motionLossGrace: 10,
            firstSampleTimeout: 0.01,
            startupRestartBackoff: 0.005
        )
        var lost = 0
        detector.onMotionLost = { _ in lost += 1 }
        // Deliver recovery from inside the second subscription. Waiting for the test task
        // to resume before emitting would race that task against the new 10 ms watchdog.
        source.onStart = { [weak source] attempt in
            guard attempt == 2 else { return }
            source?.emit(pitch: 0.1, yaw: 0.1, at: 1)
        }
        detector.start { (_: HeadGesture) in }
        source.fail()

        let didRestart = await waitUntil { source.startCount == 2 }
        XCTAssertTrue(didRestart, "the interruption timer must not replace the startup watchdog")
        // Exceed the watchdog deadline to prove the synchronous recovery cancelled it.
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(lost, 0)
        detector.stop()
    }

    func testStopDuringStartupBackoffCancelsRestart() async {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(
            source: source,
            firstSampleTimeout: 0.01,
            startupRestartBackoff: 0.05
        )
        detector.start { (_: HeadGesture) in }

        let didEnterBackoff = await waitUntil { source.stopCount == 1 }
        XCTAssertTrue(didEnterBackoff)
        detector.stop()
        try? await Task.sleep(nanoseconds: 70_000_000)

        XCTAssertEqual(source.startCount, 1, "a closed interaction must not reopen motion")
        XCTAssertEqual(source.stopCount, 1)
    }

    func testCaptureUsesSameSilentStartupRecovery() async {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(
            source: source,
            firstSampleTimeout: 0.01,
            startupRestartBackoff: 0.005
        )
        let expected = HeadMotionSample(
            timestamp: 1.5,
            pitch: 0.1,
            yaw: 0.2,
            accelerationMagnitude: 0.3,
            rotationMagnitude: 0.4
        )
        var samples: [HeadMotionSample] = []
        var lost = 0
        detector.onMotionLost = { _ in lost += 1 }
        // Deliver recovery from inside the second subscription. Waiting for the test task
        // to resume before emitting would race that task against the new 10 ms watchdog.
        source.onStart = { [weak source] attempt in
            guard attempt == 2 else { return }
            source?.emit(expected)
        }
        XCTAssertTrue(detector.startCapture { samples.append($0) })

        let didRestart = await waitUntil { source.startCount == 2 }
        XCTAssertTrue(didRestart)
        // Exceed the watchdog deadline to prove the synchronous recovery cancelled it.
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(samples, [expected])
        XCTAssertEqual(lost, 0)
        detector.stopCapture()
    }

    func testLateCallbackFromPreviousSessionIsIgnored() {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)
        let stale = HeadMotionSample(
            timestamp: 1,
            pitch: 0.1,
            yaw: 0.2,
            accelerationMagnitude: 0.3,
            rotationMagnitude: 0.4
        )
        let current = HeadMotionSample(
            timestamp: 2,
            pitch: 0.5,
            yaw: 0.6,
            accelerationMagnitude: 0.7,
            rotationMagnitude: 0.8
        )
        var firstSession: [HeadMotionSample] = []
        var secondSession: [HeadMotionSample] = []

        XCTAssertTrue(detector.startCapture { firstSession.append($0) })
        detector.stopCapture()
        XCTAssertTrue(detector.startCapture { secondSession.append($0) })

        source.emit(stale, fromSubscription: 0)
        source.emit(current, fromSubscription: 1)

        XCTAssertEqual(firstSession, [])
        XCTAssertEqual(secondSession, [current])
        detector.stopCapture()
    }

    func testLateErrorFromPreviousSessionDoesNotInterruptCurrentSession() async {
        struct StaleSubscriptionError: Error {}

        let source = FakeMotionSource()
        let detector = HeadGestureDetector(
            source: source,
            motionLossGrace: 0.01,
            firstSampleTimeout: 0.1
        )
        var lost = 0
        detector.onMotionLost = { _ in lost += 1 }

        XCTAssertTrue(detector.startCapture { (_: HeadMotionSample) in })
        detector.stopCapture()
        XCTAssertTrue(detector.startCapture { (_: HeadMotionSample) in })
        source.emit(pitch: 0.1, yaw: 0.1, at: 1)

        source.fail(StaleSubscriptionError(), fromSubscription: 0)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(lost, 0, "an old subscription must not interrupt the new window")
        detector.stopCapture()
    }

    func testPersistentNilSampleSignalsMotionLossOnceAfterGrace() async {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source, motionLossGrace: 0.01)
        defer { detector.stop() }
        var losses: [MotionLossReason] = []
        detector.onMotionLost = { losses.append($0) }
        detector.start { (_: HeadGesture) in }
        source.fail()
        source.fail()   // nil samples keep arriving after a disconnect
        let didLoseMotion = await waitUntil { losses.count == 1 }
        XCTAssertTrue(didLoseMotion)
        XCTAssertEqual(losses, [.lostWhileStreaming])
    }

    func testValidSampleInsideGraceSuppressesFalseMotionLoss() async {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source, motionLossGrace: 0.02)
        defer { detector.stop() }
        var lost = 0
        detector.onMotionLost = { _ in lost += 1 }
        detector.start { (_: HeadGesture) in }

        source.fail()
        source.emit(pitch: 0.1, yaw: 0.1, at: 1)
        try? await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(lost, 0, "a recovered transient must not cancel the interaction")
    }

    func testValidSampleRearmsAfterConfirmedMotionLoss() async {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source, motionLossGrace: 0.01)
        defer { detector.stopCapture() }
        var losses: [MotionLossReason] = []
        detector.onMotionLost = { losses.append($0) }
        XCTAssertTrue(detector.startCapture { (_: HeadMotionSample) in })

        source.fail()
        source.fail()
        let didLoseMotion = await waitUntil { losses.count == 1 }
        XCTAssertTrue(didLoseMotion)
        XCTAssertEqual(losses, [.lostWhileStreaming], "one outage is signaled only once")

        source.emit(pitch: 0.1, yaw: 0.1, at: 1)
        source.fail()
        let didLoseMotionAgain = await waitUntil { losses.count == 2 }
        XCTAssertTrue(didLoseMotionAgain)
        XCTAssertEqual(losses, [.lostWhileStreaming, .lostWhileStreaming],
                       "a valid sample proves recovery and rearms loss signaling")
    }

    func testUnavailableStartWaitsBrieflyAndRecovers() async {
        let source = FakeMotionSource()
        source.available = false
        // The grace is deliberately far longer than the retry period. This test is about
        // recovery, not about which of the two timers wins: pairing an 80 ms grace with a
        // fixed 30 ms wait for a 10 ms retry lost that race on a loaded CI runner and
        // reported a failure that said nothing about the detector. Grace expiry is covered
        // by `testUnavailableStartFailsAfterBoundedGrace`.
        let detector = HeadGestureDetector(
            source: source,
            motionLossGrace: 10,
            availabilityRetry: 0.01
        )
        var lost = 0
        detector.onMotionLost = { _ in lost += 1 }
        detector.start { (_: HeadGesture) in }

        // Safe as a fixed wait: it only lets retry ticks accumulate, and overrunning it
        // cannot change the expected value while the source is still unavailable.
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(source.startCount, 0, "an unavailable source is never started")

        source.available = true
        let didRecover = await waitUntil { source.startCount == 1 }

        XCTAssertTrue(didRecover, "the retry must start the source once it becomes available")
        XCTAssertEqual(lost, 0, "recovering inside the grace must not signal motion loss")
        detector.stop()
    }

    func testUnavailableStartFailsAfterBoundedGrace() async {
        let source = FakeMotionSource()
        source.available = false
        let detector = HeadGestureDetector(
            source: source,
            motionLossGrace: 0.02,
            availabilityRetry: 0.005
        )
        defer { detector.stop() }
        var losses: [MotionLossReason] = []
        detector.onMotionLost = { losses.append($0) }
        detector.start { (_: HeadGesture) in }

        let didFailThrough = await waitUntil { losses.count == 1 }

        XCTAssertTrue(didFailThrough, "an unavailable channel must fail through after its bounded grace")
        XCTAssertEqual(source.startCount, 0)
        XCTAssertEqual(losses, [.neverStreamed],
                       "no device was ever there, so the host must not be told one disconnected")
    }

    func testAvailabilityDropBetweenPollAndActualStartFailsImmediately() async {
        let source = FakeMotionSource()
        source.available = false
        // Initial start sees unavailable; the poller then sees available, but the
        // actual start check observes the connection has disappeared again.
        source.availabilitySequence = [false, true, false]
        let detector = HeadGestureDetector(
            source: source,
            motionLossGrace: 0.1,
            availabilityRetry: 0.005
        )
        var losses: [MotionLossReason] = []
        detector.onMotionLost = { losses.append($0) }
        detector.start { (_: HeadGesture) in }

        let didFailThrough = await waitUntil { losses.count == 1 }

        XCTAssertTrue(didFailThrough)
        XCTAssertEqual(source.startCount, 0)
        XCTAssertEqual(losses, [.neverStreamed], "nothing was ever subscribed to")
        detector.stop()
    }

    func testStopStopsInjectedSource() {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)
        detector.start { (_: HeadGesture) in }
        detector.stop()
        XCTAssertEqual(source.stopCount, 1)
    }

    func testUnavailableSourceIsNeverStartedOrStopped() {
        let source = FakeMotionSource()
        source.available = false
        let detector = HeadGestureDetector(source: source)
        detector.start { (_: HeadGesture) in }
        detector.stop()
        XCTAssertEqual(source.startCount, 0)
        XCTAssertEqual(source.stopCount, 0)
    }

    func testStartCaptureStreamsRawSamplesFromInjectedSource() {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)
        var samples: [(pitch: Double, yaw: Double, accel: Double)] = []
        XCTAssertTrue(detector.startCapture { samples.append(($0, $1, $2)) })
        source.emit(pitch: 0.1, yaw: 0.2, at: 0)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].pitch, 0.1)
        XCTAssertEqual(samples[0].yaw, 0.2)
    }

    func testStartCaptureStreamsCompletePortableSamples() {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)
        let expected = HeadMotionSample(timestamp: 1.5, pitch: 0.1, yaw: 0.2,
                                        accelerationMagnitude: 0.3, rotationMagnitude: 0.4)
        var samples: [HeadMotionSample] = []
        XCTAssertTrue(detector.startCapture { (sample: HeadMotionSample) in
            samples.append(sample)
        })
        source.emit(expected)
        XCTAssertEqual(samples, [expected])
    }

    func testStartCaptureReturnsFalseWhenUnavailable() {
        let source = FakeMotionSource()
        source.available = false
        let detector = HeadGestureDetector(source: source)
        XCTAssertFalse(detector.startCapture { _, _, _ in })
        XCTAssertEqual(source.startCount, 0)
    }

    /// The real adapter must be inert inside a test host: CoreMotion's TCC check aborts
    /// unsigned xctest processes on AirPods-paired machines (even `stop` on a never-started
    /// manager), so under XCTest it reports unavailable and never touches the manager.
    func testRealMotionSourceIsInertInTestProcess() {
        let source = HeadphoneMotionManagerSource()
        XCTAssertFalse(source.isDeviceMotionAvailable,
                       "a test process must see motion as unavailable regardless of pairing")
        source.startUpdates { _, _ in }   // would SIGABRT without the guard when paired
        source.stopUpdates()
    }

    /// The production `start()` path must be safe to call from a test host — the canary
    /// for the seam above: without it, this aborts the suite on an AirPods-paired machine.
    func testDefaultDetectorStartIsSafeInTestProcess() {
        let detector = HeadGestureDetector()
        detector.start { (_: HeadGesture) in }   // would SIGABRT without the guard when paired
        detector.stop()
    }

    func testStopPreservesMotionLostWiring() {
        let detector = HeadGestureDetector()
        detector.onMotionLost = { _ in }
        detector.beginListeningForTesting()
        detector.stop()
        XCTAssertNotNil(detector.onMotionLost, "app-level wiring must survive window close")
    }

    // MARK: - Capture vs. detection ownership

    func testStopCaptureIsNoOpWhileDetectionWindowIsOpen() {
        // Calibration sheet opened and closed while a broker window is listening: its
        // capture never started, so its teardown must not kill the window's channels.
        let (detector, emitted) = makeDetector()
        detector.beginListeningForTesting()
        detector.stopCapture()
        feedNod(detector, at: 0.0)
        feedNod(detector, at: 0.8)
        XCTAssertEqual(emitted(), [.nod], "window must survive a no-capture stopCapture")
    }

    func testStopCaptureEndsCaptureSession() {
        let detector = HeadGestureDetector()
        var lost = 0
        detector.onMotionLost = { _ in lost += 1 }
        detector.beginCaptureForTesting()
        detector.stopCapture()
        detector.handleMotionLoss()
        XCTAssertEqual(lost, 0, "capture session must actually end when it did start")
    }

    func testDetectionStopDuringCaptureReleasesOnlyTheWindow() {
        // A broker window that overlapped a calibration finishes: its stop() must release
        // the window's callbacks without tearing down the live capture session.
        let (detector, emitted) = makeDetector()
        var lost = 0
        detector.onMotionLost = { _ in lost += 1 }
        detector.beginCaptureForTesting()
        detector.stop()
        feedNod(detector, at: 0.0)
        feedNod(detector, at: 0.8)
        XCTAssertEqual(emitted(), [], "the finished window's gesture callback is released")
        detector.handleMotionLoss()
        XCTAssertEqual(lost, 1, "capture session stays live through a detection stop")
    }

    // MARK: - Diagnostics

    @MainActor
    func testGestureEmitsGenericDiagnosticEvent() {
        let sink = RecordingSink()
        let (detector, emitted) = makeDetector(diagnosticSink: sink)
        feedNod(detector, at: 0.0)   // pending at t=0.20
        feedNod(detector, at: 0.8)   // confirmed at t=1.00 -> gesture.detected
        XCTAssertEqual(emitted(), [.nod])
        let event = sink.events.first { $0.name == "gesture.detected" }
        XCTAssertEqual(event?.fields["gesture"], "nod")
        XCTAssertNotNil(event?.fields["p2p_pitch"])
    }

    // MARK: - MotionSampleObserving hook

    @MainActor
    final class RecordingMotionObserver: MotionSampleObserving {
        var samples: [HeadMotionSample] = []
        var interruptedCount = 0

        func ingest(_ sample: HeadMotionSample) {
            samples.append(sample)
        }
        func streamInterrupted() {
            interruptedCount += 1
        }
    }

    func testObserverReceivesSamplesFromInjectedSource() {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)
        let observer = RecordingMotionObserver()
        detector.setMotionSampleObserver(observer)

        detector.start { (_: HeadGesture) in }
        let sample1 = HeadMotionSample(
            timestamp: 1.0, pitch: 0.1, yaw: 0.2, roll: 0,
            userAcceleration: MotionVector(x: 0.01, y: 0, z: 0),
            rotationRate: .zero,
            gravity: MotionVector(x: 0, y: 0, z: -1)
        )
        let sample2 = HeadMotionSample(
            timestamp: 1.04, pitch: 0.15, yaw: 0.25, roll: 0,
            userAcceleration: MotionVector(x: 0.02, y: 0, z: 0),
            rotationRate: .zero,
            gravity: MotionVector(x: 0, y: 0, z: -1)
        )
        source.emit(sample1)
        source.emit(sample2)

        XCTAssertEqual(observer.samples, [sample1, sample2])
        detector.stop()
    }

    func testObserverStreamInterruptedOnStop() {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)
        let observer = RecordingMotionObserver()
        detector.setMotionSampleObserver(observer)

        detector.start { (_: HeadGesture) in }
        // start -> resetSession -> streamInterrupted (1)
        let afterStart = observer.interruptedCount
        source.emit(pitch: 0.1, yaw: 0.1, at: 1)
        detector.stop()
        // stop -> teardown -> streamInterrupted (+1)

        XCTAssertEqual(observer.interruptedCount, afterStart + 1,
                       "teardown must notify the observer")
    }

    func testObserverStreamInterruptedOnStopCapture() {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)
        let observer = RecordingMotionObserver()
        detector.setMotionSampleObserver(observer)

        XCTAssertTrue(detector.startCapture { (_: HeadMotionSample) in })
        // startCapture -> resetSession -> streamInterrupted (1)
        let afterStart = observer.interruptedCount
        source.emit(pitch: 0.1, yaw: 0.1, at: 1)
        detector.stopCapture()
        // stopCapture -> teardown -> streamInterrupted (+1)

        XCTAssertEqual(observer.interruptedCount, afterStart + 1,
                       "teardown must notify the observer")
    }

    func testObserverStreamInterruptedOnMotionLoss() async {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source, motionLossGrace: 0.01)
        let observer = RecordingMotionObserver()
        detector.setMotionSampleObserver(observer)

        detector.start { (_: HeadGesture) in }
        source.fail()

        let didInterrupt = await waitUntil { observer.interruptedCount >= 1 }
        XCTAssertTrue(didInterrupt)
        XCTAssertEqual(observer.interruptedCount, 1)
        detector.stop()
    }

    func testNoObserverZeroBehaviorChange() {
        // Without an observer, all existing behavior is unchanged
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)
        // Do NOT attach any observer
        var emitted: [HeadGesture] = []
        detector.start { emitted.append($0) }
        for t0 in [0.0, 0.8] {
            for (i, v) in Self.zigzag.enumerated() {
                source.emit(pitch: v, yaw: Self.flat[i], at: t0 + Double(i) * 0.04)
            }
        }
        XCTAssertEqual(emitted, [.nod], "gesture detection unchanged without observer")
        detector.stop()
    }

    func testObserverDoesNotReceiveCaptureModeSamples() {
        // In capture mode, samples go to onSample, not to ingest(), so the observer
        // should NOT receive them (capture mode bypasses the detection pipeline).
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)
        let observer = RecordingMotionObserver()
        detector.setMotionSampleObserver(observer)

        var capturedSamples: [HeadMotionSample] = []
        XCTAssertTrue(detector.startCapture { capturedSamples.append($0) })
        source.emit(pitch: 0.1, yaw: 0.1, at: 1)

        XCTAssertEqual(capturedSamples.count, 1,
                       "capture callback receives the sample")
        XCTAssertEqual(observer.samples.count, 0,
                       "observer does not receive capture-mode samples")
        detector.stopCapture()
    }

    func testObserverWeakReferenceDoesNotRetain() {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)

        var observer: RecordingMotionObserver? = RecordingMotionObserver()
        weak var weakObserver = observer
        detector.setMotionSampleObserver(observer)
        observer = nil

        // The observer should have been deallocated since it's held weakly
        XCTAssertNil(weakObserver, "observer should not be retained by the detector")

        // Should not crash with a nil observer
        detector.start { (_: HeadGesture) in }
        source.emit(pitch: 0.1, yaw: 0.1, at: 1)
        detector.stop()
    }

    func testDetachObserverBySettingNil() {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)
        let observer = RecordingMotionObserver()
        detector.setMotionSampleObserver(observer)
        detector.setMotionSampleObserver(nil)

        detector.start { (_: HeadGesture) in }
        source.emit(pitch: 0.1, yaw: 0.1, at: 1)
        detector.stop()

        XCTAssertEqual(observer.samples.count, 0)
        XCTAssertEqual(observer.interruptedCount, 0)
    }

    func testObserverStreamInterruptedOnNewSession() {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source)
        let observer = RecordingMotionObserver()
        detector.setMotionSampleObserver(observer)

        detector.start { (_: HeadGesture) in }
        // start -> resetSession -> streamInterrupted (1)
        source.emit(pitch: 0.1, yaw: 0.1, at: 1)
        detector.stop()
        // stop -> teardown -> streamInterrupted (2)
        let afterFirstStop = observer.interruptedCount

        // Starting a new session resets, which calls streamInterrupted again
        detector.start { (_: HeadGesture) in }
        // start -> resetSession -> streamInterrupted (afterFirstStop + 1)
        XCTAssertEqual(observer.interruptedCount, afterFirstStop + 1,
                       "resetSession on new start notifies observer")
        source.emit(pitch: 0.2, yaw: 0.2, at: 2)
        XCTAssertEqual(observer.samples.count, 2)
        detector.stop()
    }
}
