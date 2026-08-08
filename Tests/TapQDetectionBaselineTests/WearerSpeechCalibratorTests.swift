import XCTest
@testable import TapQDetectionBaseline

final class WearerSpeechCalibratorTests: XCTestCase {
    /// A phase of `count` envelope values alternating narrowly around `level`, which is
    /// what a sustained tremor looks like once differenced. `spread` keeps the median at
    /// `level` while giving the peak somewhere to be.
    private func phase(level: Double, count: Int = 40, spread: Double = 0) -> [Double] {
        (0..<count).map { level + (($0 % 2 == 0) ? -spread : spread) }
    }

    private func samples(
        speaking: [Double],
        resting: [Double] = []
    ) -> WearerSpeechCalibrationSamples {
        WearerSpeechCalibrationSamples(
            restingEnvelope: resting.isEmpty ? phase(level: 0.003) : resting,
            speakingEnvelope: speaking
        )
    }

    // MARK: - Thresholds

    func testEnterThresholdSitsBetweenRestAndSpeech() {
        let config = WearerSpeechCalibrator.suggestedConfig(
            from: samples(speaking: phase(level: 0.030), resting: phase(level: 0.004))
        )
        XCTAssertLessThan(config.envelopeEnterThreshold, 0.030)
        XCTAssertGreaterThan(config.envelopeEnterThreshold, 0.004)
    }

    func testExitThresholdStaysBelowEnterAndAboveRest() {
        let config = WearerSpeechCalibrator.suggestedConfig(
            from: samples(speaking: phase(level: 0.030), resting: phase(level: 0.004))
        )
        XCTAssertLessThan(config.envelopeExitThreshold, config.envelopeEnterThreshold)
        XCTAssertGreaterThan(config.envelopeExitThreshold, 0.004)
    }

    /// The exit floor exists so a noisy-but-quiet baseline cannot hold the detector in
    /// `.speaking` forever: leaving the state requires falling *below* exit.
    func testNoisyRestPushesTheExitThresholdUpWithoutCrossingEnter() {
        let quiet = WearerSpeechCalibrator.suggestedConfig(
            from: samples(speaking: phase(level: 0.060), resting: phase(level: 0.001))
        )
        let noisy = WearerSpeechCalibrator.suggestedConfig(
            from: samples(speaking: phase(level: 0.060), resting: phase(level: 0.020))
        )
        XCTAssertGreaterThan(noisy.envelopeExitThreshold, quiet.envelopeExitThreshold)
        XCTAssertLessThan(noisy.envelopeExitThreshold, noisy.envelopeEnterThreshold)
    }

    /// The speaking statistic is a median, so one syllable-onset spike must not drag the
    /// threshold up — that is the failure mode a peak-based statistic would have.
    func testOneLoudTransientDoesNotDominateTheThreshold() {
        var speaking = phase(level: 0.030)
        let baseline = WearerSpeechCalibrator.suggestedConfig(
            from: samples(speaking: speaking))
        speaking[7] = 0.9
        let spiked = WearerSpeechCalibrator.suggestedConfig(from: samples(speaking: speaking))
        XCTAssertEqual(
            spiked.envelopeEnterThreshold,
            baseline.envelopeEnterThreshold,
            accuracy: 1e-9
        )
    }

    func testQuietSpeechClampsToTheFloor() {
        // 0.001 * 0.6 and the resting headroom both land under the 0.004 floor.
        let config = WearerSpeechCalibrator.suggestedConfig(
            from: samples(speaking: phase(level: 0.001), resting: phase(level: 0.0005))
        )
        XCTAssertEqual(
            config.envelopeEnterThreshold,
            WearerSpeechCalibrator.minThreshold,
            accuracy: 1e-12
        )
    }

    func testEnormousEnvelopeClampsToTheCeiling() {
        let config = WearerSpeechCalibrator.suggestedConfig(
            from: samples(speaking: phase(level: 2.0))
        )
        XCTAssertEqual(
            config.envelopeEnterThreshold,
            WearerSpeechCalibrator.maxThreshold,
            accuracy: 1e-12
        )
        XCTAssertLessThan(config.envelopeExitThreshold, config.envelopeEnterThreshold)
    }

    func testNonThresholdFieldsPreserved() {
        let base = WearerSpeechConfig(
            envelopeEnterThreshold: 0.99,
            envelopeExitThreshold: 0.98,
            minimumActiveFraction: 0.75,
            minimumSpeakingSeconds: 0.42,
            hangoverSeconds: 1.25,
            rotationQuiet: 0.33,
            windowSeconds: 0.9,
            minSamples: 11,
            maxSampleGapSeconds: 0.25
        )
        let config = WearerSpeechCalibrator.suggestedConfig(
            from: samples(speaking: phase(level: 0.030)), base: base)

        XCTAssertNotEqual(config.envelopeEnterThreshold, base.envelopeEnterThreshold)
        XCTAssertNotEqual(config.envelopeExitThreshold, base.envelopeExitThreshold)
        XCTAssertEqual(config.minimumActiveFraction, base.minimumActiveFraction)
        XCTAssertEqual(config.minimumSpeakingSeconds, base.minimumSpeakingSeconds)
        XCTAssertEqual(config.hangoverSeconds, base.hangoverSeconds)
        XCTAssertEqual(config.rotationQuiet, base.rotationQuiet)
        XCTAssertEqual(config.windowSeconds, base.windowSeconds)
        XCTAssertEqual(config.minSamples, base.minSamples)
        XCTAssertEqual(config.maxSampleGapSeconds, base.maxSampleGapSeconds)
    }

    func testEmptySpeakingPhaseReturnsBaseUnchanged() {
        let base = WearerSpeechConfig(
            envelopeEnterThreshold: 0.042, envelopeExitThreshold: 0.021)
        let config = WearerSpeechCalibrator.suggestedConfig(
            from: samples(speaking: []), base: base)
        XCTAssertEqual(config, base)
    }

    // MARK: - Usability

    func testSustainedSpeechClearOfRestIsUsable() {
        XCTAssertTrue(WearerSpeechCalibrator.isSpeechUsable(
            samples(speaking: phase(level: 0.030), resting: phase(level: 0.004))
        ))
    }

    func testSpeechBuriedInRestingNoiseIsNotUsable() {
        // 0.010 is not >= 3x the 0.008 resting peak.
        XCTAssertFalse(WearerSpeechCalibrator.isSpeechUsable(
            samples(speaking: phase(level: 0.010), resting: phase(level: 0.008))
        ))
    }

    func testSpeechBelowTheAbsoluteFloorIsNotUsableEvenAgainstSilence() {
        let assessment = WearerSpeechCalibrator.assessment(
            of: samplesWithSilentRest(speaking: phase(level: 0.004)))
        XCTAssertEqual(assessment.restingEnvelopePeak, 0, accuracy: 1e-12)
        XCTAssertEqual(
            assessment.requiredLevel,
            WearerSpeechCalibrator.minUsableSpeaking,
            accuracy: 1e-12
        )
        XCTAssertFalse(assessment.isUsable)
    }

    func testShortPhasesAreRejectedSeparatelyFromWeakSeparation() {
        let assessment = WearerSpeechCalibrator.assessment(of: samples(
            speaking: phase(level: 0.030, count: 4), resting: phase(level: 0.004)
        ))
        XCTAssertFalse(assessment.hasEnoughSamples)
        XCTAssertFalse(assessment.isUsable)
        XCTAssertGreaterThanOrEqual(
            assessment.speakingEnvelopeLevel, assessment.requiredLevel,
            "separation is fine here; only the sample count fails"
        )
        XCTAssertEqual(assessment.speakingSampleCount, 4)
        XCTAssertEqual(assessment.requiredSampleCount, 12)
    }

    func testAssessmentReportsMedianSpeechAgainstPeakRest() {
        let assessment = WearerSpeechCalibrator.assessment(of: samples(
            speaking: phase(level: 0.030, spread: 0.010),
            resting: phase(level: 0.004, spread: 0.002)
        ))
        XCTAssertEqual(assessment.speakingEnvelopeLevel, 0.020, accuracy: 1e-9)
        XCTAssertEqual(assessment.restingEnvelopePeak, 0.006, accuracy: 1e-9)
        XCTAssertEqual(assessment.restingSampleCount, 40)
        XCTAssertEqual(assessment.speakingSampleCount, 40)
    }

    // MARK: - Envelope derivation

    /// The calibrator must measure with the detector's own envelope function, or a profile
    /// would tune a quantity the detector never computes.
    func testSamplesAreDifferencedWithTheDetectorsEnvelope() {
        var time: TimeInterval = 100
        func stream(jerk: Double, count: Int) -> [HeadMotionSample] {
            var result: [HeadMotionSample] = []
            var sign = 1.0
            for _ in 0..<count {
                sign = -sign
                result.append(HeadMotionSample(
                    timestamp: time, pitch: 0, yaw: 0,
                    accelerationMagnitude: 0.05 + sign * jerk / 2,
                    rotationMagnitude: 0.02
                ))
                time += 1.0 / 25.0
            }
            return result
        }

        let derived = WearerSpeechCalibrationSamples(
            resting: stream(jerk: 0.004, count: 30),
            speaking: stream(jerk: 0.030, count: 30)
        )
        XCTAssertEqual(derived.restingEnvelope.count, 29)
        XCTAssertEqual(derived.speakingEnvelope.count, 29)
        XCTAssertEqual(WearerSpeechCalibrator.median(derived.speakingEnvelope),
                       0.030, accuracy: 1e-9)
        XCTAssertEqual(derived.restingEnvelope.max() ?? 0, 0.004, accuracy: 1e-9)
    }

    /// A stream gap is a discontinuity, not a vibration burst; the calibrator drops the
    /// straddling pair exactly as the live detector resets across one.
    func testStreamGapsAreNotDifferencedIntoTheEnvelope() {
        let samples = [
            HeadMotionSample(timestamp: 100, pitch: 0, yaw: 0,
                             accelerationMagnitude: 0.05, rotationMagnitude: 0),
            HeadMotionSample(timestamp: 100.04, pitch: 0, yaw: 0,
                             accelerationMagnitude: 0.06, rotationMagnitude: 0),
            // 9 s later, and 1 g away: a differenced jump here would swamp everything.
            HeadMotionSample(timestamp: 109, pitch: 0, yaw: 0,
                             accelerationMagnitude: 1.06, rotationMagnitude: 0),
        ]
        let derived = WearerSpeechCalibrationSamples(resting: [], speaking: samples)
        XCTAssertEqual(derived.speakingEnvelope.count, 1)
        XCTAssertEqual(derived.speakingEnvelope[0], 0.01, accuracy: 1e-9)
    }

    // MARK: - Round trip through the detector

    /// End to end: a calibrated profile must make the stream it was calibrated on detect.
    func testCalibratedProfileDetectsTheStreamItWasCalibratedOn() {
        var time: TimeInterval = 100
        var sign = 1.0
        func append(_ result: inout [HeadMotionSample], seconds: Double, jerk: Double) {
            for _ in 0..<Int((seconds * 25).rounded()) {
                sign = -sign
                result.append(HeadMotionSample(
                    timestamp: time, pitch: 0, yaw: 0,
                    accelerationMagnitude: 0.05 + sign * jerk / 2,
                    rotationMagnitude: 0.02
                ))
                time += 1.0 / 25.0
            }
        }
        var resting: [HeadMotionSample] = []
        append(&resting, seconds: 3, jerk: 0.002)
        var speaking: [HeadMotionSample] = []
        append(&speaking, seconds: 4, jerk: 0.014)

        let derived = WearerSpeechCalibrationSamples(resting: resting, speaking: speaking)
        XCTAssertTrue(WearerSpeechCalibrator.isSpeechUsable(derived))
        let config = WearerSpeechCalibrator.suggestedConfig(from: derived)

        // The uncalibrated default sits above this quiet wearer's envelope entirely.
        var uncalibrated = WearerSpeechDetector()
        for sample in speaking { uncalibrated.ingest(sample) }
        XCTAssertEqual(uncalibrated.state, .quiet)

        var detector = WearerSpeechDetector(config: config)
        for sample in speaking { detector.ingest(sample) }
        XCTAssertEqual(detector.state, .speaking)

        var atRest = WearerSpeechDetector(config: config)
        for sample in resting { atRest.ingest(sample) }
        XCTAssertEqual(atRest.state, .quiet)
    }

    private func samplesWithSilentRest(
        speaking: [Double]
    ) -> WearerSpeechCalibrationSamples {
        WearerSpeechCalibrationSamples(
            restingEnvelope: Array(repeating: 0, count: 40),
            speakingEnvelope: speaking
        )
    }
}
