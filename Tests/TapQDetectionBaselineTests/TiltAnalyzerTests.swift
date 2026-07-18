import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

final class TiltAnalyzerTests: XCTestCase {
    private let analyzer = TiltAnalyzer()

    func testSustainedDownwardTilt() {
        // Pitch decreasing steadily over 0.5s (~25 samples at 50Hz), no reversals
        let pitch = (0..<25).map { Double($0) * -0.01 }  // 0.0 → -0.24 rad
        XCTAssertEqual(analyzer.detect(pitch: pitch), .tiltDown)
    }

    func testSustainedUpwardTilt() {
        let pitch = (0..<25).map { Double($0) * 0.01 }  // 0.0 → +0.24 rad
        XCTAssertEqual(analyzer.detect(pitch: pitch), .tiltUp)
    }

    func testQuickTiltDownAndReturn() {
        // Quick pitch down then return to neutral — peak displacement should fire tiltDown
        let down = (0..<12).map { Double($0) * -0.02 }        // 0.0 → -0.22
        let up = (0..<12).map { -0.22 + Double($0) * 0.02 }   // -0.22 → 0.0
        XCTAssertEqual(analyzer.detect(pitch: down + up), .tiltDown)
    }

    func testBidirectionalMotionDoesNotFire() {
        // Significant displacement in both directions = ambiguous
        let down = (0..<12).map { Double($0) * -0.02 }        // 0.0 → -0.22
        let up = (0..<12).map { -0.22 + Double($0) * 0.04 }   // -0.22 → +0.22
        XCTAssertNil(analyzer.detect(pitch: down + up))
    }

    func testStillBaselineDoesNotFire() {
        let pitch = [0.001, -0.002, 0.001, 0.0, -0.001, 0.002, -0.001, 0.001]
        XCTAssertNil(analyzer.detect(pitch: pitch))
    }

    func testTooFewSamplesDoesNotFire() {
        XCTAssertNil(analyzer.detect(pitch: [-0.1, -0.2]))
    }

    func testSmallTiltBelowThresholdDoesNotFire() {
        // Total displacement below threshold
        let pitch = (0..<25).map { Double($0) * -0.002 }  // only -0.048 rad total
        XCTAssertNil(analyzer.detect(pitch: pitch))
    }
}
