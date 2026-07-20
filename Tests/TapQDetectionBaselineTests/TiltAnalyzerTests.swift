import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

final class TiltAnalyzerTests: XCTestCase {
    private let analyzer = TiltAnalyzer()

    /// A deliberate lateral tilt: roll leaves neutral, peaks well past the amplitude
    /// threshold, and returns. 24 samples ≈ 1 s at 25 Hz.
    private func tiltExcursion(peak: Double, samples: Int = 24) -> [Double] {
        (0..<samples).map { index in
            let phase = Double(index) / Double(samples - 1)
            return peak * sin(phase * .pi)
        }
    }

    private func quiet(_ count: Int) -> [Double] {
        Array(repeating: 0.0, count: count)
    }

    func testRightTiltAndReturnFires() {
        let roll = tiltExcursion(peak: 0.25)
        XCTAssertEqual(
            analyzer.detect(roll: roll, pitch: quiet(roll.count), yaw: quiet(roll.count)),
            .tiltRight
        )
    }

    func testLeftTiltAndReturnFires() {
        let roll = tiltExcursion(peak: -0.25)
        XCTAssertEqual(
            analyzer.detect(roll: roll, pitch: quiet(roll.count), yaw: quiet(roll.count)),
            .tiltLeft
        )
    }

    func testHeadParkedSidewaysDoesNotFire() {
        // Roll ramps out and stays there — the gesture never completes, so firing now
        // would trigger on someone resting their head, not gesturing.
        let roll = (0..<24).map { min(0.25, Double($0) * 0.02) }
        XCTAssertNil(
            analyzer.detect(roll: roll, pitch: quiet(roll.count), yaw: quiet(roll.count))
        )
    }

    func testBidirectionalWobbleDoesNotFire() {
        let right = tiltExcursion(peak: 0.25, samples: 12)
        let left = tiltExcursion(peak: -0.25, samples: 12)
        let roll = right + left
        XCTAssertNil(
            analyzer.detect(roll: roll, pitch: quiet(roll.count), yaw: quiet(roll.count))
        )
    }

    func testNodCrosstalkIntoRollDoesNotFire() {
        // A vigorous nod leaks some roll, but pitch swings harder — dominance gate.
        let pitch = tiltExcursion(peak: 0.4)
        let roll = tiltExcursion(peak: 0.2)
        XCTAssertNil(
            analyzer.detect(roll: roll, pitch: pitch, yaw: quiet(roll.count))
        )
    }

    func testShakeCrosstalkIntoRollDoesNotFire() {
        let yaw = tiltExcursion(peak: 0.4)
        let roll = tiltExcursion(peak: 0.2)
        XCTAssertNil(
            analyzer.detect(roll: roll, pitch: quiet(roll.count), yaw: yaw)
        )
    }

    func testStillBaselineDoesNotFire() {
        let roll = [0.001, -0.002, 0.001, 0.0, -0.001, 0.002, -0.001, 0.001]
        XCTAssertNil(
            analyzer.detect(roll: roll, pitch: quiet(roll.count), yaw: quiet(roll.count))
        )
    }

    func testSmallTiltBelowThresholdDoesNotFire() {
        let roll = tiltExcursion(peak: 0.08)
        XCTAssertNil(
            analyzer.detect(roll: roll, pitch: quiet(roll.count), yaw: quiet(roll.count))
        )
    }

    func testTooFewSamplesDoesNotFire() {
        XCTAssertNil(analyzer.detect(roll: [0.0, 0.25, 0.0], pitch: [0, 0, 0], yaw: [0, 0, 0]))
    }

    func testDriftedBaselineStillDetectsRelativeExcursion() {
        // The wearer's neutral roll is rarely exactly zero; detection is relative to the
        // window's starting posture, not absolute zero.
        let roll = tiltExcursion(peak: 0.25).map { $0 + 0.3 }
        XCTAssertEqual(
            analyzer.detect(roll: roll, pitch: quiet(roll.count), yaw: quiet(roll.count)),
            .tiltRight
        )
    }
}
