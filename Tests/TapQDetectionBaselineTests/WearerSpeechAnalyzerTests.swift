import XCTest
@testable import TapQDetectionBaseline

/// Builds synthetic 25 Hz motion streams with a controlled jerk envelope, so every test
/// below is hardware-independent and reproducible. `jerk` is the sample-to-sample change
/// in acceleration magnitude the stream is engineered to produce.
private struct StreamBuilder {
    static let rate: TimeInterval = 1.0 / 25.0

    private(set) var samples: [HeadMotionSample] = []
    private var time: TimeInterval = 100
    private var sign: Double = 1
    private var baseline: Double = 0.05

    /// Appends `seconds` of a stream whose consecutive acceleration magnitudes differ by
    /// exactly `jerk`, with a constant rotation magnitude.
    mutating func append(seconds: TimeInterval, jerk: Double, rotation: Double = 0.02) {
        let count = Int((seconds / Self.rate).rounded())
        for _ in 0..<count {
            sign = -sign
            samples.append(HeadMotionSample(
                timestamp: time,
                pitch: 0,
                yaw: 0,
                accelerationMagnitude: baseline + sign * jerk / 2,
                rotationMagnitude: rotation
            ))
            time += Self.rate
        }
    }

    /// Appends one lone high-acceleration sample: the `TapAnalyzer`-shaped impact.
    mutating func appendImpact(_ acceleration: Double, rotation: Double = 0.02) {
        samples.append(HeadMotionSample(
            timestamp: time,
            pitch: 0,
            yaw: 0,
            accelerationMagnitude: acceleration,
            rotationMagnitude: rotation
        ))
        time += Self.rate
    }

    /// Appends per-axis samples whose signed user acceleration flips by `jerk` each step.
    mutating func appendPerAxis(seconds: TimeInterval, jerk: Double, rotation: Double = 0.02) {
        let count = Int((seconds / Self.rate).rounded())
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
            time += Self.rate
        }
    }

    /// Advances the clock without emitting samples — a dropped stretch of stream.
    mutating func skip(seconds: TimeInterval) {
        time += seconds
    }

    /// Returns the samples appended since the last drain and keeps the clock running, so a
    /// test can feed one continuous stream in phases.
    mutating func drain() -> [HeadMotionSample] {
        defer { samples = [] }
        return samples
    }
}

private extension WearerSpeechDetector {
    /// Feeds every sample and returns the final state.
    @discardableResult
    mutating func ingest(all samples: [HeadMotionSample]) -> WearerSpeechState {
        var state = self.state
        for sample in samples { state = ingest(sample) }
        return state
    }

    /// Feeds every sample and returns the transitions observed, in order.
    mutating func transitions(over samples: [HeadMotionSample]) -> [WearerSpeechTransition] {
        samples.compactMap { ingestDetailed($0).transition }
    }
}

final class WearerSpeechAnalyzerTests: XCTestCase {
    // Defaults: enter 0.020, exit 0.012, activeFraction 0.5, minSpeaking 0.3 s,
    // hangover 0.6 s, rotationQuiet 0.8, window 0.6 s, minSamples 6, maxGap 0.5 s.
    private let analyzer = WearerSpeechAnalyzer()

    // MARK: - Pure window analysis

    func testSustainedElevationWithQuietHeadIsDetected() {
        let envelope = [Double](repeating: 0.04, count: 15)
        let rotation = [Double](repeating: 0.02, count: 15)
        XCTAssertTrue(analyzer.detect(envelope: envelope, rotation: rotation,
                                      sustainedSeconds: 0.4, holding: false))
    }

    func testAnalysisExplainsEveryDecisionGate() {
        let quietRotation = [Double](repeating: 0.02, count: 15)

        XCTAssertEqual(
            analyzer.analyze(envelope: [0.04, 0.04], rotation: [0.02, 0.02],
                             sustainedSeconds: 1, holding: false).rejection,
            .insufficientSamples
        )
        XCTAssertEqual(
            analyzer.analyze(envelope: [Double](repeating: 0.004, count: 15),
                             rotation: quietRotation,
                             sustainedSeconds: 1, holding: false).rejection,
            .belowEnvelope
        )
        XCTAssertEqual(
            analyzer.analyze(envelope: [Double](repeating: 0.04, count: 15),
                             rotation: [Double](repeating: 2.5, count: 15),
                             sustainedSeconds: 1, holding: false).rejection,
            .rotationNotQuiet
        )
        // Breadth gate: one big transient in an otherwise quiet window.
        var transient = [Double](repeating: 0.004, count: 14)
        transient.insert(1.19, at: 7)
        XCTAssertEqual(
            analyzer.analyze(envelope: transient, rotation: quietRotation,
                             sustainedSeconds: 1, holding: false).rejection,
            .tooBrief
        )
        // Duration gate: broad elevation that has not lasted long enough yet.
        XCTAssertEqual(
            analyzer.analyze(envelope: [Double](repeating: 0.04, count: 15),
                             rotation: quietRotation,
                             sustainedSeconds: 0.2, holding: false).rejection,
            .tooBrief
        )

        let detected = analyzer.analyze(envelope: [Double](repeating: 0.04, count: 15),
                                        rotation: quietRotation,
                                        sustainedSeconds: 0.4, holding: false)
        XCTAssertNil(detected.rejection)
        XCTAssertTrue(detected.detected)
        XCTAssertEqual(detected.envelopeSamples, 15)
        XCTAssertEqual(detected.rotationSamples, 15)
        XCTAssertEqual(detected.elevatedSamples, 15)
        XCTAssertEqual(detected.activeFraction, 1.0)
        XCTAssertEqual(detected.peakEnvelope, 0.04)
        XCTAssertEqual(detected.threshold, 0.020)
        XCTAssertEqual(detected.sustainedSeconds, 0.4)
    }

    /// The onset duration is served once. Re-serving it on every sample while already
    /// speaking would make the detector unable to stay in state.
    func testDurationGateIsSkippedWhileHolding() {
        let envelope = [Double](repeating: 0.04, count: 15)
        let rotation = [Double](repeating: 0.02, count: 15)
        XCTAssertFalse(analyzer.detect(envelope: envelope, rotation: rotation,
                                       sustainedSeconds: 0, holding: false))
        XCTAssertTrue(analyzer.detect(envelope: envelope, rotation: rotation,
                                      sustainedSeconds: 0, holding: true))
    }

    /// Mid-band level: above the exit threshold, below the enter threshold. It must not be
    /// enough to start speech, and must be enough to sustain it.
    func testHysteresisThresholdSelection() {
        let midBand = [Double](repeating: 0.016, count: 15)
        let rotation = [Double](repeating: 0.02, count: 15)

        let entering = analyzer.analyze(envelope: midBand, rotation: rotation,
                                        sustainedSeconds: 1, holding: false)
        XCTAssertEqual(entering.rejection, .belowEnvelope)
        XCTAssertEqual(entering.threshold, 0.020)

        let holding = analyzer.analyze(envelope: midBand, rotation: rotation,
                                       sustainedSeconds: 1, holding: true)
        XCTAssertTrue(holding.detected)
        XCTAssertEqual(holding.threshold, 0.012)
    }

    func testMinimumSamplesRespectsConfiguredValue() {
        let strict = WearerSpeechAnalyzer(config: WearerSpeechConfig(minSamples: 20))
        XCTAssertEqual(
            strict.analyze(envelope: [Double](repeating: 0.04, count: 15),
                           rotation: [Double](repeating: 0.02, count: 15),
                           sustainedSeconds: 1, holding: false).rejection,
            .insufficientSamples
        )
    }

    // MARK: - Envelope computation

    func testEnvelopeValueUsesMagnitudesWithoutPerAxisData() {
        let previous = HeadMotionSample(timestamp: 1, pitch: 0, yaw: 0,
                                        accelerationMagnitude: 0.05, rotationMagnitude: 0)
        let current = HeadMotionSample(timestamp: 1.04, pitch: 0, yaw: 0,
                                       accelerationMagnitude: 0.09, rotationMagnitude: 0)
        XCTAssertEqual(
            WearerSpeechAnalyzer.envelopeValue(from: previous, to: current),
            0.04, accuracy: 1e-12
        )
        // Direction of the change is irrelevant; the envelope is a magnitude.
        XCTAssertEqual(
            WearerSpeechAnalyzer.envelopeValue(from: current, to: previous),
            0.04, accuracy: 1e-12
        )
    }

    /// With signed data the vector difference sees a reversal that leaves the magnitude
    /// unchanged — the scalar path would report zero jerk for the same motion.
    func testEnvelopeValueUsesVectorDifferenceWithPerAxisData() {
        let previous = HeadMotionSample(
            timestamp: 1, pitch: 0, yaw: 0, roll: 0,
            userAcceleration: MotionVector(x: 0.03, y: 0, z: 0),
            rotationRate: .zero, gravity: MotionVector(x: 0, y: 0, z: -1)
        )
        let current = HeadMotionSample(
            timestamp: 1.04, pitch: 0, yaw: 0, roll: 0,
            userAcceleration: MotionVector(x: -0.03, y: 0, z: 0),
            rotationRate: .zero, gravity: MotionVector(x: 0, y: 0, z: -1)
        )
        XCTAssertEqual(previous.accelerationMagnitude, current.accelerationMagnitude)
        XCTAssertEqual(
            WearerSpeechAnalyzer.envelopeValue(from: previous, to: current),
            0.06, accuracy: 1e-12
        )
    }

    func testEnvelopeValueFallsBackToMagnitudesWhenEitherSampleLacksPerAxisData() {
        let magnitudeOnly = HeadMotionSample(timestamp: 1, pitch: 0, yaw: 0,
                                             accelerationMagnitude: 0.03, rotationMagnitude: 0)
        let perAxis = HeadMotionSample(
            timestamp: 1.04, pitch: 0, yaw: 0, roll: 0,
            userAcceleration: MotionVector(x: -0.03, y: 0, z: 0),
            rotationRate: .zero, gravity: MotionVector(x: 0, y: 0, z: -1)
        )
        XCTAssertEqual(
            WearerSpeechAnalyzer.envelopeValue(from: magnitudeOnly, to: perAxis),
            0, accuracy: 1e-12
        )
    }

    func testEnvelopeSeriesProducesOneValuePerContiguousPair() {
        var builder = StreamBuilder()
        builder.append(seconds: 0.4, jerk: 0.04)
        let series = WearerSpeechAnalyzer.envelopeSeries(builder.samples)
        XCTAssertEqual(series.count, builder.samples.count - 1)
        for value in series {
            XCTAssertEqual(value, 0.04, accuracy: 1e-12)
        }
    }

    /// The calibrator shares this helper, so its gap policy must match the detector's:
    /// a discontinuity is skipped, never differenced into a fake vibration burst.
    func testEnvelopeSeriesSkipsGapsAndOutOfOrderSamples() {
        var builder = StreamBuilder()
        builder.append(seconds: 0.2, jerk: 0.04)
        let before = builder.samples.count
        builder.skip(seconds: 2.0)
        builder.append(seconds: 0.2, jerk: 0.04)

        let series = WearerSpeechAnalyzer.envelopeSeries(builder.samples)
        XCTAssertEqual(series.count, builder.samples.count - 2)
        XCTAssertEqual(series.max() ?? 0, 0.04, accuracy: 1e-12)

        let repeated = [builder.samples[before - 1], builder.samples[before - 1]]
        XCTAssertTrue(WearerSpeechAnalyzer.envelopeSeries(repeated).isEmpty)
        XCTAssertTrue(WearerSpeechAnalyzer.envelopeSeries([builder.samples[0]]).isEmpty)
        XCTAssertTrue(WearerSpeechAnalyzer.envelopeSeries([]).isEmpty)
    }

    // MARK: - Detector

    func testSustainedVibrationIsDetectedAsSpeaking() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)

        XCTAssertEqual(detector.ingest(all: builder.samples), .speaking)
        XCTAssertEqual(detector.state, .speaking)
    }

    func testSpeechIsNotDeclaredBeforeTheOnsetDurationElapses() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 0.28, jerk: 0.04)

        XCTAssertEqual(detector.ingest(all: builder.samples), .quiet)
    }

    func testStartAndStopProduceExactlyOneTransitionEach() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        builder.append(seconds: 2.5, jerk: 0.004)

        XCTAssertEqual(detector.transitions(over: builder.samples),
                       [.startedSpeaking, .stoppedSpeaking])
        XCTAssertEqual(detector.state, .quiet)
    }

    func testRestingJitterIsNeverDetected() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 20, jerk: 0.004)

        for sample in builder.samples {
            XCTAssertEqual(detector.ingestDetailed(sample).state, .quiet)
        }
    }

    /// A `TapAnalyzer`-shaped impact — one lone 1.24 g sample in a quiet stream — is a
    /// transient, not speech. It clears the level gate and dies on the breadth gate.
    func testSingleImpactSpikeIsRejectedAsTooBrief() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 0.6, jerk: 0.004)
        builder.appendImpact(1.24)
        builder.append(seconds: 0.6, jerk: 0.004)

        var sawImpactWindow = false
        for sample in builder.samples {
            let update = detector.ingestDetailed(sample)
            XCTAssertEqual(update.state, .quiet)
            if update.envelope > 1 {
                XCTAssertEqual(update.analysis.rejection, .tooBrief)
                XCTAssertGreaterThan(update.analysis.peakEnvelope,
                                     update.analysis.threshold)
                sawImpactWindow = true
            }
        }
        XCTAssertTrue(sawImpactWindow, "the synthetic impact never reached the detector")
    }

    /// A nod/shake carries a speech-sized envelope; only the rotation gate separates them.
    func testHeadGestureStreamIsRejectedByTheRotationGate() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.10, rotation: 2.5)

        var sawRotationRejection = false
        for sample in builder.samples {
            let update = detector.ingestDetailed(sample)
            XCTAssertEqual(update.state, .quiet)
            if update.analysis.rejection == .rotationNotQuiet { sawRotationRejection = true }
        }
        XCTAssertTrue(sawRotationRejection)

        // Same envelope, still head: now it is speech. The rotation was the only difference.
        var still = WearerSpeechDetector()
        var quietBuilder = StreamBuilder()
        quietBuilder.append(seconds: 1.5, jerk: 0.10, rotation: 0.02)
        XCTAssertEqual(still.ingest(all: quietBuilder.samples), .speaking)
    }

    /// Mid-band chatter guard: a stream parked between the exit and enter thresholds must
    /// settle in whichever state it is already in, in both directions.
    func testMidBandStreamDoesNotChatter() {
        var fromQuiet = WearerSpeechDetector()
        var quietBuilder = StreamBuilder()
        quietBuilder.append(seconds: 4, jerk: 0.016)
        XCTAssertTrue(fromQuiet.transitions(over: quietBuilder.samples).isEmpty)
        XCTAssertEqual(fromQuiet.state, .quiet)

        var fromSpeech = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        XCTAssertEqual(fromSpeech.ingest(all: builder.drain()), .speaking)

        builder.append(seconds: 4, jerk: 0.016)
        XCTAssertTrue(fromSpeech.transitions(over: builder.drain()).isEmpty)
        XCTAssertEqual(fromSpeech.state, .speaking)
    }

    /// One utterance must not fragment into many at every inter-word pause.
    func testHangoverHoldsSpeakingThroughAShortPause() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        builder.append(seconds: 0.4, jerk: 0.004)   // inter-word pause
        builder.append(seconds: 1.0, jerk: 0.04)
        builder.append(seconds: 0.4, jerk: 0.004)

        XCTAssertEqual(detector.transitions(over: builder.samples), [.startedSpeaking])
        XCTAssertEqual(detector.state, .speaking)
    }

    func testHangoverExpiresAfterALongPause() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        XCTAssertEqual(detector.ingest(all: builder.drain()), .speaking)

        builder.append(seconds: 2.0, jerk: 0.004)
        XCTAssertEqual(detector.transitions(over: builder.drain()), [.stoppedSpeaking])
        XCTAssertEqual(detector.state, .quiet)
    }

    func testHangoverIsReportedWhileItHoldsTheState() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        detector.ingest(all: builder.drain())

        builder.append(seconds: 0.5, jerk: 0.004)
        let updates = builder.drain().map { detector.ingestDetailed($0) }
        XCTAssertTrue(updates.contains { $0.inHangover })
        XCTAssertTrue(updates.allSatisfy { $0.state == .speaking })
    }

    /// A dropped stretch of stream must not be differenced across: the jump would read as
    /// one enormous jerk, and the retained window no longer adjoins the new sample.
    func testTimestampGapResetsTheDetector() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        XCTAssertEqual(detector.ingest(all: builder.drain()), .speaking)

        builder.skip(seconds: 3.0)
        builder.append(seconds: 0.2, jerk: 0.04)

        let resumed = builder.drain()
        let updates = resumed.map { detector.ingestDetailed($0) }
        XCTAssertEqual(updates.first?.transition, .stoppedSpeaking)
        XCTAssertEqual(updates.first?.envelope, 0)
        XCTAssertEqual(updates.first?.analysis.rejection, .insufficientSamples)
        XCTAssertTrue(updates.allSatisfy { $0.state == .quiet })
        // The window was cleared, so speech has to be re-established from scratch.
        XCTAssertEqual(updates.last?.analysis.envelopeSamples, resumed.count - 1)
    }

    func testNonMonotonicTimestampResetsTheDetector() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        detector.ingest(all: builder.drain())

        let rewound = HeadMotionSample(timestamp: 0, pitch: 0, yaw: 0,
                                       accelerationMagnitude: 0.05, rotationMagnitude: 0.02)
        let update = detector.ingestDetailed(rewound)
        XCTAssertEqual(update.state, .quiet)
        XCTAssertEqual(update.transition, .stoppedSpeaking)
    }

    func testGapShorterThanTheConfiguredMaximumDoesNotReset() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        detector.ingest(all: builder.drain())

        builder.skip(seconds: 0.2)   // under the 0.5 s gap limit
        builder.append(seconds: 0.2, jerk: 0.04)
        XCTAssertEqual(detector.ingest(all: builder.drain()), .speaking)
    }

    /// Magnitude-only adapters (and every capture recorded before per-axis data existed)
    /// must still drive the detector.
    func testMagnitudeOnlyAndPerAxisStreamsBothDetect() {
        var magnitudeOnly = WearerSpeechDetector()
        var magnitudeBuilder = StreamBuilder()
        magnitudeBuilder.append(seconds: 1.5, jerk: 0.04)
        XCTAssertFalse(magnitudeBuilder.samples[0].hasPerAxisData)
        XCTAssertEqual(magnitudeOnly.ingest(all: magnitudeBuilder.samples), .speaking)

        var perAxis = WearerSpeechDetector()
        var perAxisBuilder = StreamBuilder()
        perAxisBuilder.appendPerAxis(seconds: 1.5, jerk: 0.04)
        XCTAssertTrue(perAxisBuilder.samples[0].hasPerAxisData)
        XCTAssertEqual(perAxis.ingest(all: perAxisBuilder.samples), .speaking)
    }

    func testResetClearsStateAndWindows() {
        var detector = WearerSpeechDetector()
        var builder = StreamBuilder()
        builder.append(seconds: 1.5, jerk: 0.04)
        detector.ingest(all: builder.drain())
        XCTAssertEqual(detector.state, .speaking)

        detector.reset()
        XCTAssertEqual(detector.state, .quiet)

        builder.append(seconds: 0.2, jerk: 0.04)
        let short = builder.drain()
        let updates = short.map { detector.ingestDetailed($0) }
        XCTAssertEqual(updates.first?.envelope, 0)
        XCTAssertEqual(updates.last?.analysis.envelopeSamples, short.count - 1)
        XCTAssertTrue(updates.allSatisfy { $0.state == .quiet })
    }

    func testReconfiguringTheDetectorRebuildsTheAnalyzer() {
        var detector = WearerSpeechDetector()
        detector.config = WearerSpeechConfig(envelopeEnterThreshold: 5,
                                             envelopeExitThreshold: 4)
        var speech = StreamBuilder()
        speech.append(seconds: 2.0, jerk: 0.04)
        XCTAssertEqual(detector.ingest(all: speech.samples), .quiet)
    }

    // MARK: - Config

    func testConfigRoundTripsThroughJSON() throws {
        let config = WearerSpeechConfig(
            envelopeEnterThreshold: 0.031,
            envelopeExitThreshold: 0.019,
            minimumActiveFraction: 0.6,
            minimumSpeakingSeconds: 0.4,
            hangoverSeconds: 0.8,
            rotationQuiet: 0.7,
            windowSeconds: 0.8,
            minSamples: 9,
            maxSampleGapSeconds: 0.32
        )
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(WearerSpeechConfig.self, from: data), config)
    }

    /// Tolerant decoding, per `HeadGestureConfig`: a profile written before a shape knob
    /// existed still loads, with that knob at its default.
    func testConfigDecodesWithOnlyTheCalibratedThresholds() throws {
        let json = Data("""
        {"envelopeEnterThreshold": 0.031, "envelopeExitThreshold": 0.019}
        """.utf8)
        let decoded = try JSONDecoder().decode(WearerSpeechConfig.self, from: json)
        let defaults = WearerSpeechConfig()

        XCTAssertEqual(decoded.envelopeEnterThreshold, 0.031)
        XCTAssertEqual(decoded.envelopeExitThreshold, 0.019)
        XCTAssertEqual(decoded.minimumActiveFraction, defaults.minimumActiveFraction)
        XCTAssertEqual(decoded.minimumSpeakingSeconds, defaults.minimumSpeakingSeconds)
        XCTAssertEqual(decoded.hangoverSeconds, defaults.hangoverSeconds)
        XCTAssertEqual(decoded.rotationQuiet, defaults.rotationQuiet)
        XCTAssertEqual(decoded.windowSeconds, defaults.windowSeconds)
        XCTAssertEqual(decoded.minSamples, defaults.minSamples)
        XCTAssertEqual(decoded.maxSampleGapSeconds, defaults.maxSampleGapSeconds)
    }

    func testConfigIgnoresUnknownKeysButRequiresTheThresholds() {
        let extra = Data("""
        {"envelopeEnterThreshold": 0.03, "envelopeExitThreshold": 0.02, "futureKnob": 7}
        """.utf8)
        XCTAssertNoThrow(try JSONDecoder().decode(WearerSpeechConfig.self, from: extra))

        let missing = Data(#"{"envelopeEnterThreshold": 0.03}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WearerSpeechConfig.self, from: missing))
    }

    func testDefaultConfigKeepsHysteresisOrdered() {
        let defaults = WearerSpeechConfig()
        XCTAssertLessThan(defaults.envelopeExitThreshold, defaults.envelopeEnterThreshold)
        XCTAssertEqual(defaults.maxSampleGapSeconds,
                       WearerSpeechConfig.defaultMaximumSampleGapSeconds)
    }
}
