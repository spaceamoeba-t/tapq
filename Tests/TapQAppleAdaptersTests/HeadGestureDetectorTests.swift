import XCTest
@testable import TapQAppleAdapters
import TapQContracts
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

    func testShakeEmitsImmediately() {
        let (detector, emitted) = makeDetector()
        feedShake(detector, at: 0.0)
        XCTAssertEqual(emitted(), [.shake])
    }

    func testShakeCancelsPendingFirstNod() {
        let (detector, emitted) = makeDetector()
        feedNod(detector, at: 0.0)     // pending at t=0.20
        feedShake(detector, at: 0.4)   // detection at t=0.60 -> .shake emitted immediately, pending nod cleared
        // The fresh pair below then proves state is clean: it pairs and confirms normally,
        // which it couldn't if the cleared pending nod (or its samples) had lingered.
        feedNod(detector, at: 1.64)    // detection at t=1.84 -> new first nod
        feedNod(detector, at: 2.44)    // detection at t=2.64, gap 0.8 -> emit
        XCTAssertEqual(emitted(), [.shake, .nod])
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
        detector.onMotionLost = { lost += 1 }
        detector.beginListeningForTesting()
        detector.handleMotionLoss()
        detector.handleMotionLoss() // nil samples keep arriving after a disconnect
        XCTAssertEqual(lost, 1, "loss is signalled once per listening session")
    }

    func testMotionLossIgnoredWhenNotListening() {
        let detector = HeadGestureDetector()
        var lost = 0
        detector.onMotionLost = { lost += 1 }
        detector.handleMotionLoss()
        XCTAssertEqual(lost, 0, "no window open — nothing to rescue")
    }

    func testMotionLossSignalsAgainOnNextSession() {
        let detector = HeadGestureDetector()
        var lost = 0
        detector.onMotionLost = { lost += 1 }
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
        var isDeviceMotionAvailable: Bool {
            guard !availabilitySequence.isEmpty else { return available }
            return availabilitySequence.removeFirst()
        }
        func startUpdates(_ handler: @escaping Handler) {
            startCount += 1
            self.handler = handler
            subscriptions.append(handler)
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
        detector.onMotionLost = { lost += 1 }
        detector.start { (_: HeadGesture) in }

        let didRestart = await waitUntil { source.startCount == 2 }
        XCTAssertTrue(didRestart)
        source.emit(pitch: 0.1, yaw: 0.1, at: 1)
        try? await Task.sleep(nanoseconds: 20_000_000)

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
        var lost = 0
        detector.onMotionLost = { lost += 1 }
        detector.start { (_: HeadGesture) in }

        let didFailThrough = await waitUntil { lost == 1 }
        XCTAssertTrue(didFailThrough)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(source.startCount, 2, "startup recovery is bounded to one restart")
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(lost, 1)
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
        detector.onMotionLost = { lost += 1 }
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
        let detector = HeadGestureDetector(
            source: source,
            motionLossGrace: 0.2,
            firstSampleTimeout: 0.01,
            startupRestartBackoff: 0.005
        )
        var lost = 0
        detector.onMotionLost = { lost += 1 }
        detector.start { (_: HeadGesture) in }
        source.fail()

        let didRestart = await waitUntil { source.startCount == 2 }
        XCTAssertTrue(didRestart, "the interruption timer must not replace the startup watchdog")
        source.emit(pitch: 0.1, yaw: 0.1, at: 1)
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
        detector.onMotionLost = { lost += 1 }
        XCTAssertTrue(detector.startCapture { samples.append($0) })

        let didRestart = await waitUntil { source.startCount == 2 }
        XCTAssertTrue(didRestart)
        source.emit(expected)
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
        detector.onMotionLost = { lost += 1 }

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
        var lost = 0
        detector.onMotionLost = { lost += 1 }
        detector.start { (_: HeadGesture) in }
        source.fail()
        source.fail()   // nil samples keep arriving after a disconnect
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(lost, 1)
    }

    func testValidSampleInsideGraceSuppressesFalseMotionLoss() async {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source, motionLossGrace: 0.02)
        var lost = 0
        detector.onMotionLost = { lost += 1 }
        detector.start { (_: HeadGesture) in }

        source.fail()
        source.emit(pitch: 0.1, yaw: 0.1, at: 1)
        try? await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(lost, 0, "a recovered transient must not cancel the interaction")
    }

    func testValidSampleRearmsAfterConfirmedMotionLoss() async {
        let source = FakeMotionSource()
        let detector = HeadGestureDetector(source: source, motionLossGrace: 0.01)
        var lost = 0
        detector.onMotionLost = { lost += 1 }
        XCTAssertTrue(detector.startCapture { (_: HeadMotionSample) in })

        source.fail()
        source.fail()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(lost, 1, "one outage is signaled only once")

        source.emit(pitch: 0.1, yaw: 0.1, at: 1)
        source.fail()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(lost, 2, "a valid sample proves recovery and rearms loss signaling")
    }

    func testUnavailableStartWaitsBrieflyAndRecovers() async {
        let source = FakeMotionSource()
        source.available = false
        let detector = HeadGestureDetector(
            source: source,
            motionLossGrace: 0.08,
            availabilityRetry: 0.01
        )
        var lost = 0
        detector.onMotionLost = { lost += 1 }
        detector.start { (_: HeadGesture) in }

        try? await Task.sleep(nanoseconds: 20_000_000)
        source.available = true
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(lost, 0)
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
        var lost = 0
        detector.onMotionLost = { lost += 1 }
        detector.start { (_: HeadGesture) in }

        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(source.startCount, 0)
        XCTAssertEqual(lost, 1, "an unavailable channel must not leave the prompt silently waiting")
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
        var lost = 0
        detector.onMotionLost = { lost += 1 }
        detector.start { (_: HeadGesture) in }

        let didFailThrough = await waitUntil { lost == 1 }

        XCTAssertTrue(didFailThrough)
        XCTAssertEqual(source.startCount, 0)
        XCTAssertEqual(lost, 1)
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
        detector.onMotionLost = {}
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
        detector.onMotionLost = { lost += 1 }
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
        detector.onMotionLost = { lost += 1 }
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
}
