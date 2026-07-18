import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

final class GestureCalibratorTests: XCTestCase {
    private func oscillation(amplitude: Double, cycles: Double = 1.5, count: Int = 30) -> [Double] {
        (0..<count).map { amplitude * sin(2 * .pi * cycles * Double($0) / Double(count)) }
    }

    private func jitter(_ count: Int = 30, _ magnitude: Double = 0.01) -> [Double] {
        (0..<count).map { _ in Double.random(in: -magnitude...magnitude) }
    }

    private func strongSamples() -> GestureCalibrationSamples {
        GestureCalibrationSamples(
            restingPitch: jitter(), restingYaw: jitter(),
            nodPitch: oscillation(amplitude: 0.4), shakeYaw: oscillation(amplitude: 0.4))
    }

    func testThresholdSitsBetweenRestAndGesture() {
        let samples = strongSamples()
        let config = GestureCalibrator.suggestedConfig(from: samples)

        let nodPP = GestureAnalyzer.stats(samples.nodPitch).peakToPeak
        let restPP = max(GestureAnalyzer.stats(samples.restingPitch).peakToPeak,
                         GestureAnalyzer.stats(samples.restingYaw).peakToPeak)
        XCTAssertLessThan(config.amplitudeThreshold, nodPP)
        XCTAssertGreaterThan(config.amplitudeThreshold, restPP)
    }

    func testCalibratedConfigStillDetectsTheCalibratedGesture() {
        let samples = strongSamples()
        let config = GestureCalibrator.suggestedConfig(from: samples)
        let analyzer = GestureAnalyzer(config: config)

        XCTAssertEqual(analyzer.detect(pitch: samples.nodPitch, yaw: jitter()), .nod)
        XCTAssertEqual(analyzer.detect(pitch: jitter(), yaw: samples.shakeYaw), .shake)
    }

    func testNonAmplitudeFieldsPreserved() {
        let base = HeadGestureConfig(amplitudeThreshold: 0.99, dominanceRatio: 3.3,
                                     windowSeconds: 2.2, minReversals: 4,
                                     debounceSeconds: 0.7, minSamples: 9)
        let config = GestureCalibrator.suggestedConfig(from: strongSamples(), base: base)

        XCTAssertNotEqual(config.amplitudeThreshold, base.amplitudeThreshold)
        XCTAssertEqual(config.dominanceRatio, base.dominanceRatio)
        XCTAssertEqual(config.windowSeconds, base.windowSeconds)
        XCTAssertEqual(config.minReversals, base.minReversals)
        XCTAssertEqual(config.debounceSeconds, base.debounceSeconds)
        XCTAssertEqual(config.minSamples, base.minSamples)
    }

    func testDegenerateCaptureClampsToFloor() {
        let samples = GestureCalibrationSamples(nodPitch: [0, 0, 0, 0, 0, 0], shakeYaw: [0, 0, 0, 0, 0, 0])
        let config = GestureCalibrator.suggestedConfig(from: samples)
        XCTAssertEqual(config.amplitudeThreshold, GestureCalibrator.minThreshold, accuracy: 1e-9)
    }

    func testHugeGestureClampsToCeiling() {
        let samples = GestureCalibrationSamples(
            nodPitch: oscillation(amplitude: 5.0), shakeYaw: oscillation(amplitude: 5.0))
        let config = GestureCalibrator.suggestedConfig(from: samples)
        XCTAssertEqual(config.amplitudeThreshold, GestureCalibrator.maxThreshold, accuracy: 1e-9)
    }

    func testStrongGesturesAreUsable() {
        XCTAssertTrue(GestureCalibrator.isUsable(strongSamples()))
    }

    func testWeakGesturesAreNotUsable() {
        let samples = GestureCalibrationSamples(
            restingPitch: jitter(), restingYaw: jitter(),
            nodPitch: oscillation(amplitude: 0.03), shakeYaw: oscillation(amplitude: 0.03))
        XCTAssertFalse(GestureCalibrator.isUsable(samples))
    }

    func testGesturesBuriedInRestingNoiseAreNotUsable() {
        let samples = GestureCalibrationSamples(
            restingPitch: oscillation(amplitude: 0.5), restingYaw: oscillation(amplitude: 0.5),
            nodPitch: oscillation(amplitude: 0.4), shakeYaw: oscillation(amplitude: 0.4))
        XCTAssertFalse(GestureCalibrator.isUsable(samples))
    }

    func testConfigCodableRoundTrip() throws {
        let config = HeadGestureConfig(amplitudeThreshold: 0.27, dominanceRatio: 2.5,
                                       windowSeconds: 1.4, minReversals: 3,
                                       debounceSeconds: 0.9, minSamples: 7)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(HeadGestureConfig.self, from: data)
        XCTAssertEqual(config, decoded)
    }
}
