import XCTest
@testable import TapQDetectionBaseline
import TapQGestureContracts

final class TapCalibratorTests: XCTestCase {
    private func samples(tap: [Double], resting: [Double] = [0.004, 0.006, 0.005]) -> GestureCalibrationSamples {
        GestureCalibrationSamples(nodPitch: [], shakeYaw: [], restingAccel: resting, tapAccel: tap)
    }

    func testThresholdSitsBetweenRestAndTap() {
        let s = samples(tap: [0.02, 0.03, 1.24, 0.04])
        let config = TapCalibrator.suggestedTapConfig(from: s)
        XCTAssertLessThan(config.amplitudeThreshold, 1.24)      // below the user's real tap
        XCTAssertGreaterThan(config.amplitudeThreshold, 0.006)  // above resting jitter
    }

    func testNonAmplitudeFieldsPreserved() {
        let base = TapConfig(amplitudeThreshold: 0.99, rotationQuiet: 0.4,
                             windowSeconds: 0.3, debounceSeconds: 1.1,
                             minSamples: 6, maxSpikeSamples: 2)
        let config = TapCalibrator.suggestedTapConfig(from: samples(tap: [1.2]), base: base)
        XCTAssertNotEqual(config.amplitudeThreshold, base.amplitudeThreshold)
        XCTAssertEqual(config.rotationQuiet, base.rotationQuiet)
        XCTAssertEqual(config.windowSeconds, base.windowSeconds)
        XCTAssertEqual(config.debounceSeconds, base.debounceSeconds)
        XCTAssertEqual(config.minSamples, base.minSamples)
        XCTAssertEqual(config.maxSpikeSamples, base.maxSpikeSamples)
    }

    func testLowAmplitudeSeparatedTapClampsToSafeFloor() {
        // 0.07 * 0.5 = 0.035 and rest headroom is lower, so the 0.05 floor wins.
        let config = TapCalibrator.suggestedTapConfig(
            from: samples(tap: [0.07], resting: [0.01])
        )
        XCTAssertEqual(config.amplitudeThreshold, TapCalibrator.minThreshold, accuracy: 1e-9)
    }

    func testHugeTapClampsToCeiling() {
        let config = TapCalibrator.suggestedTapConfig(from: samples(tap: [3.0]))
        XCTAssertEqual(config.amplitudeThreshold, TapCalibrator.maxThreshold, accuracy: 1e-9)
    }

    func testEmptyTapReturnsBaseUnchanged() {
        let base = TapConfig(amplitudeThreshold: 0.42)
        let config = TapCalibrator.suggestedTapConfig(from: samples(tap: []), base: base)
        XCTAssertEqual(config, base)
    }

    func testStrongTapIsUsable() {
        XCTAssertTrue(TapCalibrator.isTapUsable(samples(tap: [0.02, 1.24, 0.03])))
    }

    func testWeakTapIsNotUsable() {
        XCTAssertFalse(TapCalibrator.isTapUsable(samples(tap: [0.02, 0.04, 0.03])))
    }

    func testTapBuriedInRestingIsNotUsable() {
        // Tap peak 0.4 is not >= 3x the resting noise 0.2.
        XCTAssertFalse(TapCalibrator.isTapUsable(samples(tap: [0.4], resting: [0.2])))
    }

    func testAssessmentExplainsRequiredPeak() {
        let assessment = TapCalibrator.assessment(
            of: samples(tap: [0.08, 0.1], resting: [0.01, 0.04])
        )
        XCTAssertEqual(assessment.tapPeak, 0.1, accuracy: 1e-9)
        XCTAssertEqual(assessment.restingPeak, 0.04, accuracy: 1e-9)
        XCTAssertEqual(assessment.requiredPeak, 0.16, accuracy: 1e-9)
        XCTAssertFalse(assessment.isUsable)
    }

    func testObservedAirPodsSignalIsUsableByRelativeSeparation() {
        let captured = samples(
            tap: [0.018, 0.0715, 0.02],
            resting: [0.012, 0.0164, 0.011]
        )

        let assessment = TapCalibrator.assessment(of: captured)
        let config = TapCalibrator.suggestedTapConfig(from: captured)

        XCTAssertTrue(assessment.isUsable)
        XCTAssertEqual(assessment.requiredPeak, 0.0656, accuracy: 1e-9)
        XCTAssertEqual(config.amplitudeThreshold, 0.05, accuracy: 1e-9)
    }

    func testConfigCodableRoundTrip() throws {
        let config = TapConfig(amplitudeThreshold: 0.52, rotationQuiet: 0.55,
                               windowSeconds: 0.22, debounceSeconds: 0.9,
                               minSamples: 5, maxSpikeSamples: 3)
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(TapConfig.self, from: data), config)
    }
}
