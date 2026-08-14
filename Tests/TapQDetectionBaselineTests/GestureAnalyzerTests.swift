import XCTest
@testable import TapQDetectionBaseline
import TapQGestureContracts

final class GestureAnalyzerTests: XCTestCase {
    private func oscillation(amplitude: Double, cycles: Double, count: Int) -> [Double] {
        (0..<count).map { amplitude * sin(2 * .pi * cycles * Double($0) / Double(count)) }
    }

    private func jitter(_ count: Int, _ magnitude: Double = 0.01) -> [Double] {
        (0..<count).map { _ in Double.random(in: -magnitude...magnitude) }
    }

    func testNodDetectedFromPitchOscillation() {
        let analyzer = GestureAnalyzer()
        let pitch = oscillation(amplitude: 0.4, cycles: 1.5, count: 30)
        let yaw = jitter(30)
        XCTAssertEqual(analyzer.detect(pitch: pitch, yaw: yaw), .nod)
    }

    func testShakeDetectedFromYawOscillation() {
        let analyzer = GestureAnalyzer()
        let yaw = oscillation(amplitude: 0.4, cycles: 1.5, count: 30)
        let pitch = jitter(30)
        XCTAssertEqual(analyzer.detect(pitch: pitch, yaw: yaw), .shake)
    }

    func testFlatSignalDetectsNothing() {
        let analyzer = GestureAnalyzer()
        XCTAssertNil(analyzer.detect(pitch: jitter(30, 0.02), yaw: jitter(30, 0.02)))
    }

    func testTooFewSamplesDetectsNothing() {
        let analyzer = GestureAnalyzer()
        let pitch = oscillation(amplitude: 0.4, cycles: 1.0, count: 4)
        XCTAssertNil(analyzer.detect(pitch: pitch, yaw: jitter(4)))
    }
}
