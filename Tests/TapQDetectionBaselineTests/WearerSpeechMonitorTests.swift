import XCTest
@testable import TapQDetectionBaseline

/// Builds synthetic 25 Hz motion streams with a controlled jerk envelope, matching the
/// existing `WearerSpeechAnalyzerTests` builder. Speech detection fires after sustained
/// elevation, so the stream must exceed the onset + window duration.
private struct StreamBuilder {
    static let rate: TimeInterval = 1.0 / 25.0

    private(set) var samples: [HeadMotionSample] = []
    private var time: TimeInterval = 100
    private var sign: Double = 1
    private var baseline: Double = 0.05

    mutating func append(seconds: TimeInterval, jerk: Double, rotation: Double = 0.02) {
        let count = Int((seconds / StreamBuilder.rate).rounded())
        for _ in 0..<count {
            sign = -sign
            samples.append(HeadMotionSample(
                timestamp: time,
                pitch: 0,
                yaw: 0,
                accelerationMagnitude: baseline + sign * jerk / 2,
                rotationMagnitude: rotation
            ))
            time += StreamBuilder.rate
        }
    }

    mutating func appendPerAxis(seconds: TimeInterval, jerk: Double, rotation: Double = 0.02) {
        let count = Int((seconds / StreamBuilder.rate).rounded())
        for _ in 0..<count {
            sign = -sign
            samples.append(HeadMotionSample(
                timestamp: time,
                pitch: 0,
                yaw: 0,
                roll: 0,
                userAcceleration: MotionVector(x: sign * jerk / 2, y: 0, z: 0),
                rotationRate: MotionVector(x: 0, y: rotation, z: 0),
                gravity: MotionVector(x: 0, y: 0, z: -1)
            ))
            time += StreamBuilder.rate
        }
    }

    mutating func skip(seconds: TimeInterval) {
        time += seconds
    }

    mutating func drain() -> [HeadMotionSample] {
        defer { samples = [] }
        return samples
    }
}

final class WearerSpeechMonitorTests: XCTestCase {
    // Defaults: enter 0.020, exit 0.012, activeFraction 0.5, minSpeaking 0.3 s,
    // hangover 0.6 s, rotationQuiet 0.8, window 0.6 s, minSamples 6, maxGap 0.5 s.

    private final class Clock {
        var now: TimeInterval = 100
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private func makeMonitor(
        config: WearerSpeechConfig = .init(),
        stalenessHorizon: TimeInterval? = nil,
        clock: Clock = Clock()
    ) -> (WearerSpeechMonitor, Clock) {
        let monitor = WearerSpeechMonitor(
            config: config,
            stalenessHorizon: stalenessHorizon,
            monotonicNow: { clock.now }
        )
        return (monitor, clock)
    }

    // MARK: - Basic speech detection mirrors WearerSpeechDetector

    func testSustainedVibrationTransitionsToSpeaking() {
        let (monitor, clock) = makeMonitor()
        var transitions: [WearerSpeechTransition] = []
        monitor.onTransition = { transitions.append($0) }

        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }

        XCTAssertEqual(monitor.state, .speaking)
        XCTAssertEqual(transitions, [.startedSpeaking])
    }

    func testSpeechOnsetAndOffsetProduceExactlyOneTransitionEach() {
        let (monitor, clock) = makeMonitor()
        var transitions: [WearerSpeechTransition] = []
        monitor.onTransition = { transitions.append($0) }

        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        builder.append(seconds: 2.5, jerk: 0.004)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }

        XCTAssertEqual(transitions, [.startedSpeaking, .stoppedSpeaking])
        XCTAssertEqual(monitor.state, .quiet)
    }

    func testRestingJitterNeverTransitions() {
        let (monitor, clock) = makeMonitor()
        var transitions: [WearerSpeechTransition] = []
        monitor.onTransition = { transitions.append($0) }

        var builder = StreamBuilder()
        builder.append(seconds: 5.0, jerk: 0.004)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }

        XCTAssertTrue(transitions.isEmpty)
        XCTAssertEqual(monitor.state, .quiet)
    }

    func testHangoverHoldsSpeakingThroughShortPause() {
        let (monitor, clock) = makeMonitor()
        var transitions: [WearerSpeechTransition] = []
        monitor.onTransition = { transitions.append($0) }

        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        builder.append(seconds: 0.4, jerk: 0.004)
        builder.append(seconds: 1.0, jerk: 0.04)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }

        XCTAssertEqual(transitions, [.startedSpeaking])
        XCTAssertEqual(monitor.state, .speaking)
    }

    // MARK: - Staleness

    func testIsFreshAfterRecentSample() {
        let (monitor, clock) = makeMonitor()
        var builder = StreamBuilder()
        builder.append(seconds: 0.2, jerk: 0.004)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }

        XCTAssertTrue(monitor.isFresh())
        XCTAssertNotNil(monitor.lastSampleAt)
    }

    func testIsNotFreshBeforeAnySample() {
        let (monitor, _) = makeMonitor()
        XCTAssertFalse(monitor.isFresh())
        XCTAssertNil(monitor.lastSampleAt)
    }

    func testGoesStaleAfterHorizon() {
        let clock = Clock()
        let config = WearerSpeechConfig()
        let (monitor, _) = makeMonitor(config: config, clock: clock)

        var builder = StreamBuilder()
        builder.append(seconds: 0.2, jerk: 0.004)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }
        XCTAssertTrue(monitor.isFresh())

        // Advance beyond the staleness horizon (defaults to maxSampleGapSeconds = 0.5)
        clock.advance(config.maxSampleGapSeconds + 0.1)
        XCTAssertFalse(monitor.isFresh())
    }

    func testCustomStalenessHorizon() {
        let clock = Clock()
        let (monitor, _) = makeMonitor(stalenessHorizon: 1.0, clock: clock)

        var builder = StreamBuilder()
        builder.append(seconds: 0.2, jerk: 0.004)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }
        XCTAssertTrue(monitor.isFresh())

        clock.advance(0.8)
        XCTAssertTrue(monitor.isFresh(), "within custom horizon")

        clock.advance(0.3)
        XCTAssertFalse(monitor.isFresh(), "beyond custom horizon")
    }

    func testIsFreshWithExplicitNow() {
        let (monitor, clock) = makeMonitor()
        var builder = StreamBuilder()
        builder.append(seconds: 0.2, jerk: 0.004)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }

        // Explicit now within horizon
        XCTAssertTrue(monitor.isFresh(now: clock.now + 0.1))
        // Explicit now beyond horizon
        XCTAssertFalse(monitor.isFresh(now: clock.now + 1.0))
    }

    // MARK: - streamInterrupted

    func testStreamInterruptedResetsToQuietAndStale() {
        let (monitor, clock) = makeMonitor()
        var transitions: [WearerSpeechTransition] = []
        monitor.onTransition = { transitions.append($0) }

        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }
        XCTAssertEqual(monitor.state, .speaking)
        XCTAssertTrue(monitor.isFresh())

        monitor.streamInterrupted()

        XCTAssertEqual(monitor.state, .quiet)
        XCTAssertFalse(monitor.isFresh())
        XCTAssertTrue(monitor.interrupted)
        XCTAssertEqual(transitions, [.startedSpeaking, .stoppedSpeaking])
    }

    func testStreamInterruptedWhileQuietDoesNotFireTransition() {
        let (monitor, clock) = makeMonitor()
        var transitions: [WearerSpeechTransition] = []
        monitor.onTransition = { transitions.append($0) }

        var builder = StreamBuilder()
        builder.append(seconds: 0.2, jerk: 0.004)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }
        XCTAssertEqual(monitor.state, .quiet)

        monitor.streamInterrupted()
        XCTAssertEqual(monitor.state, .quiet)
        XCTAssertTrue(transitions.isEmpty, "no transition because state was already quiet")
    }

    func testStreamInterruptedIdempotent() {
        let (monitor, clock) = makeMonitor()
        var transitions: [WearerSpeechTransition] = []
        monitor.onTransition = { transitions.append($0) }

        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }
        monitor.streamInterrupted()
        monitor.streamInterrupted()

        XCTAssertEqual(transitions, [.startedSpeaking, .stoppedSpeaking],
                       "second streamInterrupted must not fire a duplicate transition")
    }

    func testInterruptedClearsOnNextIngest() {
        let (monitor, clock) = makeMonitor()
        monitor.streamInterrupted()
        XCTAssertTrue(monitor.interrupted)

        var builder = StreamBuilder()
        builder.append(seconds: 0.2, jerk: 0.004)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }
        XCTAssertFalse(monitor.interrupted)
        XCTAssertTrue(monitor.isFresh())
    }

    // MARK: - Per-axis data tracking

    func testLastSampleHadPerAxisDataTracksCorrectly() {
        let (monitor, clock) = makeMonitor()

        // Magnitude-only sample
        let magnitudeOnly = HeadMotionSample(
            timestamp: 100, pitch: 0, yaw: 0,
            accelerationMagnitude: 0.05, rotationMagnitude: 0.02
        )
        clock.advance(StreamBuilder.rate)
        monitor.ingest(magnitudeOnly)
        XCTAssertFalse(monitor.lastSampleHadPerAxisData)

        // Per-axis sample
        let perAxis = HeadMotionSample(
            timestamp: 100.04, pitch: 0, yaw: 0, roll: 0,
            userAcceleration: MotionVector(x: 0.03, y: 0, z: 0),
            rotationRate: MotionVector(x: 0, y: 0.02, z: 0),
            gravity: MotionVector(x: 0, y: 0, z: -1)
        )
        clock.advance(StreamBuilder.rate)
        monitor.ingest(perAxis)
        XCTAssertTrue(monitor.lastSampleHadPerAxisData)
    }

    func testMagnitudeOnlyStreamReportsCorrectly() {
        let (monitor, clock) = makeMonitor()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        for sample in builder.samples {
            XCTAssertFalse(sample.hasPerAxisData)
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }
        XCTAssertFalse(monitor.lastSampleHadPerAxisData)
    }

    // MARK: - Return value

    func testIngestReturnsTheDetectorUpdate() {
        let (monitor, clock) = makeMonitor()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        var lastUpdate: WearerSpeechUpdate?
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            lastUpdate = monitor.ingest(sample)
        }
        XCTAssertEqual(lastUpdate?.state, .speaking)
    }

    // MARK: - Gap handling (inherited from detector)

    func testTimestampGapResetsDetectorState() {
        let (monitor, clock) = makeMonitor()
        var transitions: [WearerSpeechTransition] = []
        monitor.onTransition = { transitions.append($0) }

        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        for sample in builder.drain() {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }
        XCTAssertEqual(monitor.state, .speaking)

        // Skip beyond maxSampleGapSeconds (0.5 s default)
        builder.skip(seconds: 3.0)
        builder.append(seconds: 0.2, jerk: 0.04)
        for sample in builder.drain() {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }
        // The gap causes the detector to reset, so speaking -> quiet transition fires
        XCTAssertTrue(transitions.contains(.stoppedSpeaking))
    }

    // MARK: - Detector reset on stream interrupted + re-establish

    func testSpeechCanBeReEstablishedAfterInterruption() {
        let (monitor, clock) = makeMonitor()
        var transitions: [WearerSpeechTransition] = []
        monitor.onTransition = { transitions.append($0) }

        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        for sample in builder.drain() {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }
        XCTAssertEqual(monitor.state, .speaking)

        monitor.streamInterrupted()
        XCTAssertEqual(monitor.state, .quiet)

        // New stream from scratch
        var newBuilder = StreamBuilder()
        newBuilder.append(seconds: 1.5, jerk: 0.04)
        for sample in newBuilder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }
        XCTAssertEqual(monitor.state, .speaking)
        XCTAssertEqual(transitions,
                       [.startedSpeaking, .stoppedSpeaking, .startedSpeaking])
    }

    // MARK: - Per-axis streams also detect

    func testPerAxisStreamDetects() {
        let (monitor, clock) = makeMonitor()
        var transitions: [WearerSpeechTransition] = []
        monitor.onTransition = { transitions.append($0) }

        var builder = StreamBuilder()
        builder.appendPerAxis(seconds: 1.5, jerk: 0.04)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }

        XCTAssertEqual(monitor.state, .speaking)
        XCTAssertEqual(transitions, [.startedSpeaking])
        XCTAssertTrue(monitor.lastSampleHadPerAxisData)
    }

    // MARK: - Config pass-through

    func testMonitorUsesInjectedConfig() {
        let strictConfig = WearerSpeechConfig(
            envelopeEnterThreshold: 5.0,
            envelopeExitThreshold: 4.0
        )
        let (monitor, clock) = makeMonitor(config: strictConfig)

        var builder = StreamBuilder()
        builder.append(seconds: 2.0, jerk: 0.04)
        for sample in builder.samples {
            clock.advance(StreamBuilder.rate)
            monitor.ingest(sample)
        }

        XCTAssertEqual(monitor.state, .quiet,
                       "with impossibly high thresholds, nothing should be detected")
    }

    func testStalenessHorizonDefaultsToMaxSampleGapSeconds() {
        let config = WearerSpeechConfig(maxSampleGapSeconds: 0.7)
        let (monitor, _) = makeMonitor(config: config)
        XCTAssertEqual(monitor.stalenessHorizon, 0.7)
    }
}
