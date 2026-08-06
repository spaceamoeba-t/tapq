import XCTest
@testable import TapQGestures
import TapQCalibrationStore
import TapQDetectionBaseline
import TapQGestureContracts

/// Facade-level tests: the session is composition, so these assert that the wiring reaches
/// the real detector and the real analyzers. Detection behaviour itself is covered by
/// `HeadGestureDetectorTests` and the baseline suites.
@MainActor
final class GestureSessionTests: XCTestCase {
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

    @MainActor
    private final class FakeVolumeSwipeSource: VolumeSwipeProviding {
        private var onSwipe: (@MainActor (VolumeSwipeCommand) -> Void)?
        private(set) var stopCount = 0
        var isListening: Bool { onSwipe != nil }

        func start(onSwipe: @escaping @MainActor (VolumeSwipeCommand) -> Void) {
            self.onSwipe = onSwipe
        }

        func stop() {
            stopCount += 1
            onSwipe = nil
        }

        func emit(_ swipe: VolumeSwipeCommand) { onSwipe?(swipe) }
    }

    private struct StreamFault: Error {}

    /// Same fixtures as `HeadGestureDetectorTests`: 6 samples 0.04 s apart (25 Hz), p2p 0.7,
    /// 4 reversals — one detection fires on sample 6.
    private static let zigzag: [Double] = [0.0, 0.35, -0.35, 0.35, -0.35, 0.0]
    /// Cross-axis noise small enough to keep the dominance ratio well clear of 2.
    private static let flat: [Double] = [0.0, 0.01, -0.01, 0.01, -0.01, 0.0]

    private func sample(
        pitch: Double = 0, yaw: Double = 0, at time: TimeInterval
    ) -> HeadMotionSample {
        HeadMotionSample(timestamp: time, pitch: pitch, yaw: yaw,
                         accelerationMagnitude: 0, rotationMagnitude: 0)
    }

    /// Sends one nod burst starting at `t0`; the detector's detection fires at `t0 + 0.20`.
    private func sendNod(_ source: ScriptedMotionSource, at t0: TimeInterval) {
        for (index, value) in Self.zigzag.enumerated() {
            source.send(sample(pitch: value, yaw: Self.flat[index],
                               at: t0 + Double(index) * 0.04))
        }
    }

    private func waitUntil(
        attempts: Int = 100,
        pollNanoseconds: UInt64 = 5_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return condition()
    }

    // MARK: - Curated tier

    func testScriptedDoubleNodArrivesAsAHeadGestureEvent() async {
        let source = ScriptedMotionSource()
        let session = GestureSession(motionSource: source)
        defer { session.stop() }
        var iterator = session.events().makeAsyncIterator()

        // Two nod bursts 0.8 s apart: inside the 1.5 s pair window, past the 0.3 s echo gap.
        sendNod(source, at: 0.0)
        sendNod(source, at: 0.8)

        let event = await iterator.next()
        XCTAssertEqual(event, .headGesture(.nod))
        XCTAssertEqual(source.startCount, 1, "three start(on…:) calls share one subscription")
    }

    func testSingleNodProducesNoEvent() async {
        let source = ScriptedMotionSource()
        let session = GestureSession(motionSource: source)
        defer { session.stop() }
        var received: [GestureEvent] = []
        session.start { received.append($0) }

        sendNod(source, at: 0.0)

        XCTAssertEqual(received, [], "a lone nod is rejected, not reported")
    }

    func testSustainedMotionFailureReportsMotionLostOnce() async {
        let source = ScriptedMotionSource()
        let session = GestureSession(motionSource: source)
        defer { session.stop() }
        var received: [GestureEvent] = []
        session.start { received.append($0) }
        // A first valid sample disarms the startup watchdog so this test observes the
        // interruption grace and nothing else.
        source.send(sample(pitch: 0.01, at: 0))

        source.fail(StreamFault())
        source.fail(StreamFault())   // faults keep arriving after a disconnect

        // The public session deliberately exposes no timing knobs, so this waits out the
        // detector's real 1.5 s motion-loss grace rather than shortening it.
        let didLoseMotion = await waitUntil(attempts: 600) {
            received.contains(.motionLost(.lostWhileStreaming))
        }
        XCTAssertTrue(didLoseMotion)
        XCTAssertEqual(
            received.filter { $0 == .motionLost(.lostWhileStreaming) }.count, 1,
            "a stream that was delivering samples reports the streaming loss reason once")
    }

    func testValidSampleAfterAnInterruptionReportsRestoredWithoutLoss() {
        let source = ScriptedMotionSource()
        let session = GestureSession(motionSource: source)
        defer { session.stop() }
        var received: [GestureEvent] = []
        session.start { received.append($0) }
        source.send(sample(pitch: 0.01, at: 0))

        source.fail(StreamFault())
        source.send(sample(pitch: 0.01, at: 0.04))   // recovery inside the grace period

        XCTAssertEqual(received, [.motionRestored])
    }

    func testVolumeSwipeSourceFansIntoTheEventStream() {
        let volume = FakeVolumeSwipeSource()
        let session = GestureSession(
            motionSource: ScriptedMotionSource(),
            volumeSwipeSource: volume
        )
        defer { session.stop() }
        var received: [GestureEvent] = []
        session.start { received.append($0) }

        volume.emit(.swipeUp)

        XCTAssertEqual(received, [.volumeSwipe(.swipeUp)])
    }

    func testDisabledVolumeSwipesNeverStartTheVolumeSource() {
        var configuration = GestureSession.Configuration()
        configuration.volumeSwipesEnabled = false
        let volume = FakeVolumeSwipeSource()
        let session = GestureSession(
            configuration: configuration,
            motionSource: ScriptedMotionSource(),
            volumeSwipeSource: volume
        )
        defer { session.stop() }

        session.start { _ in }

        XCTAssertFalse(volume.isListening)
    }

    // MARK: - Capabilities

    func testCapabilitiesDescribeTheHostNotTheInjectedSource() {
        let session = GestureSession(motionSource: ScriptedMotionSource(available: false))
        let capabilities = session.capabilities

        // `headphoneMotion` is a live host query, and an XCTest host always answers "no":
        // the real source refuses to touch CoreMotion in an unsigned test process. An
        // injected source is observed through the streams instead (see the raw-tier test).
        XCTAssertEqual(
            capabilities,
            GestureCapabilities(headphoneMotion: false, volumeSwipes: true, motionSwipes: true)
        )
    }

    // MARK: - Configuration

    func testCalibratedConfigurationOverlaysStoredProfiles() {
        var gestureConfig = HeadGestureConfig()
        gestureConfig.amplitudeThreshold = 0.42
        var tapConfig = TapConfig()
        tapConfig.amplitudeThreshold = 0.37
        let store = InMemoryCalibrationStore(
            gesture: TapQGestureCalibrationProfile(
                config: gestureConfig,
                quality: GestureCalibrationQuality(
                    restingSampleCount: 40, nodSampleCount: 30, shakeSampleCount: 30)
            ),
            tap: TapQTapCalibrationProfile(
                config: tapConfig,
                quality: TapCalibrationQuality(
                    restingSampleCount: 40, tapSampleCount: 20,
                    restingAccelerationPeak: 0.02, tapAccelerationPeak: 0.74)
            )
        )

        let configuration = GestureSession.Configuration.calibrated(from: store)

        XCTAssertEqual(configuration.gestures.amplitudeThreshold, 0.42)
        XCTAssertEqual(configuration.taps.amplitudeThreshold, 0.37)
        XCTAssertEqual(configuration.tilts, TiltConfig(), "uncalibrated channels stay default")

        let session = GestureSession(
            configuration: configuration,
            motionSource: ScriptedMotionSource()
        )
        XCTAssertEqual(session.configuration.gestures.amplitudeThreshold, 0.42)
        XCTAssertEqual(session.configuration.taps.amplitudeThreshold, 0.37)
    }

    func testCalibratedConfigurationKeepsDefaultsWhenTheStoreFails() {
        // `exists` says yes and the load throws: a corrupt or schema-rejected profile must
        // degrade to defaults rather than surface as an error at session construction.
        let store = InMemoryCalibrationStore(loadsFail: true)

        let configuration = GestureSession.Configuration.calibrated(from: store)

        XCTAssertEqual(configuration.gestures, HeadGestureConfig())
        XCTAssertEqual(configuration.taps, TapConfig())
    }

    func testCalibratedConfigurationKeepsDefaultsWhenNothingIsStored() {
        let configuration = GestureSession.Configuration.calibrated(
            from: InMemoryCalibrationStore()
        )

        XCTAssertEqual(configuration.gestures, HeadGestureConfig())
        XCTAssertEqual(configuration.taps, TapConfig())
    }

    // MARK: - Raw tier

    func testMotionSamplesYieldsSentSamples() async {
        let source = ScriptedMotionSource()
        let session = GestureSession(motionSource: source)
        defer { session.stop() }
        let first = HeadMotionSample(timestamp: 1.5, pitch: 0.1, yaw: 0.2,
                                     accelerationMagnitude: 0.3, rotationMagnitude: 0.4)
        let second = HeadMotionSample(timestamp: 1.54, pitch: 0.5, yaw: 0.6,
                                      accelerationMagnitude: 0.7, rotationMagnitude: 0.8)
        var iterator = session.motionSamples().makeAsyncIterator()

        source.send(first)
        source.send(second)

        let received = [await iterator.next(), await iterator.next()]
        XCTAssertEqual(received, [first, second])
    }

    func testMotionSamplesFinishesImmediatelyWhileTheCuratedTierIsActive() async {
        let sink = RecordingSink()
        let source = ScriptedMotionSource()
        let session = GestureSession(motionSource: source, diagnostics: sink)
        defer { session.stop() }
        var received: [GestureEvent] = []
        session.start { received.append($0) }

        var count = 0
        for await _ in session.motionSamples() { count += 1 }

        XCTAssertEqual(count, 0, "the raw stream finishes rather than trapping")
        XCTAssertTrue(sink.events.contains {
            $0.name == "raw.unavailable" && $0.fields["reason"] == "curated_detection_active"
        })
        // The refusal must leave the running curated tier untouched.
        sendNod(source, at: 0.0)
        sendNod(source, at: 0.8)
        XCTAssertEqual(received, [.headGesture(.nod)])
        XCTAssertEqual(source.stopCount, 0)
    }

    func testEventsFinishesImmediatelyWhileTheRawTierIsActive() async {
        let sink = RecordingSink()
        let source = ScriptedMotionSource()
        let session = GestureSession(motionSource: source, diagnostics: sink)
        defer { session.stop() }
        var iterator = session.motionSamples().makeAsyncIterator()

        var count = 0
        for await _ in session.events() { count += 1 }

        XCTAssertEqual(count, 0)
        XCTAssertTrue(sink.events.contains {
            $0.name == "curated.unavailable" && $0.fields["reason"] == "raw_capture_active"
        })
        // The live capture survives the refusal.
        let sample = HeadMotionSample(timestamp: 2, pitch: 0.1, yaw: 0.2,
                                      accelerationMagnitude: 0.3, rotationMagnitude: 0.4)
        source.send(sample)
        let received = await iterator.next()
        XCTAssertEqual(received, sample)
    }

    func testMotionSamplesFinishesImmediatelyWhenTheSourceIsUnavailable() async {
        let sink = RecordingSink()
        let source = ScriptedMotionSource(available: false)
        let session = GestureSession(motionSource: source, diagnostics: sink)
        defer { session.stop() }

        var count = 0
        for await _ in session.motionSamples() { count += 1 }

        XCTAssertEqual(count, 0)
        XCTAssertEqual(source.startCount, 0, "an unavailable source is never subscribed to")
        XCTAssertTrue(sink.events.contains {
            $0.name == "raw.unavailable"
                && $0.fields["reason"] == "headphone_motion_unavailable"
        })
    }

    // MARK: - Lifecycle

    func testEventStreamTerminationStopsTheSession() async {
        let source = ScriptedMotionSource()
        let volume = FakeVolumeSwipeSource()
        let session = GestureSession(motionSource: source, volumeSwipeSource: volume)
        let consumer = Task { @MainActor in
            for await _ in session.events() {}
        }

        let didStart = await waitUntil { source.startCount == 1 }
        XCTAssertTrue(didStart)
        consumer.cancel()

        let didStop = await waitUntil { source.stopCount == 1 }
        XCTAssertTrue(didStop, "ending consumption must release the motion subscription")
        XCTAssertEqual(volume.stopCount, 1)
    }

    func testStopFinishesTheEventStream() async {
        let source = ScriptedMotionSource()
        let session = GestureSession(motionSource: source)
        let stream = session.events()

        session.stop()

        var received = 0
        for await _ in stream { received += 1 }
        XCTAssertEqual(received, 0, "stop() must not strand a consumer awaiting events")
        XCTAssertEqual(source.stopCount, 1)
    }

    func testStopIsIdempotent() {
        let source = ScriptedMotionSource()
        let session = GestureSession(motionSource: source)
        session.start { _ in }

        session.stop()
        session.stop()

        XCTAssertEqual(source.stopCount, 1)
    }

    // MARK: - Scripted source

    func testScriptedPlaybackDeliversEverySampleInOrder() async {
        let source = ScriptedMotionSource()
        let session = GestureSession(motionSource: source)
        defer { session.stop() }
        let samples = (0..<6).map { index in
            HeadMotionSample(timestamp: Double(index) * 0.04,
                             pitch: Self.zigzag[index], yaw: Self.flat[index],
                             accelerationMagnitude: 0, rotationMagnitude: 0)
        }
        var iterator = session.motionSamples().makeAsyncIterator()

        // 100x speed keeps the test fast while still exercising the timestamp pacing.
        await source.play(samples, rate: 100)

        var received: [HeadMotionSample] = []
        for _ in samples {
            guard let sample = await iterator.next() else { break }
            received.append(sample)
        }
        XCTAssertEqual(received, samples)
    }
}
