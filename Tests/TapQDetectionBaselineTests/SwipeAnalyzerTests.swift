import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

final class SwipeAnalyzerTests: XCTestCase {
    private let analyzer = SwipeAnalyzer()
    /// Device-frame gravity for an upright wearer in these tests: straight down -z.
    private let gravityDown = MotionVector(x: 0, y: 0, z: -1)

    /// A drag: quiet lead-in, a sustained gentle acceleration plateau along `direction`,
    /// quiet tail. 20 samples ≈ 0.8 s at 25 Hz.
    private func drag(
        direction: MotionVector, level: Double = 0.2,
        elevated: Int = 7, lead: Int = 6, tail: Int = 7
    ) -> [MotionVector] {
        let quiet = MotionVector(x: 0.01, y: 0, z: 0)
        let norm = direction.magnitude
        let active = MotionVector(
            x: direction.x / norm * level,
            y: direction.y / norm * level,
            z: direction.z / norm * level
        )
        return Array(repeating: quiet, count: lead)
            + Array(repeating: active, count: elevated)
            + Array(repeating: quiet, count: tail)
    }

    private func quietRotation(_ count: Int) -> [Double] {
        Array(repeating: 0.05, count: count)
    }

    private func gravity(_ count: Int) -> [MotionVector] {
        Array(repeating: gravityDown, count: count)
    }

    func testUpwardDragFiresSwipeUp() {
        let accel = drag(direction: MotionVector(x: 0, y: 0, z: 1))
        XCTAssertEqual(
            analyzer.detect(acceleration: accel, gravity: gravity(accel.count),
                            rotation: quietRotation(accel.count)),
            .swipeUp
        )
    }

    func testDownwardDragFiresSwipeDown() {
        let accel = drag(direction: MotionVector(x: 0, y: 0, z: -1))
        XCTAssertEqual(
            analyzer.detect(acceleration: accel, gravity: gravity(accel.count),
                            rotation: quietRotation(accel.count)),
            .swipeDown
        )
    }

    func testHorizontalDragHasNoTrustedDirection() {
        // A drag orthogonal to gravity has no vertical dominance — report nothing
        // rather than guessing.
        let accel = drag(direction: MotionVector(x: 1, y: 0, z: 0))
        XCTAssertNil(
            analyzer.detect(acceleration: accel, gravity: gravity(accel.count),
                            rotation: quietRotation(accel.count))
        )
    }

    func testTapSpikeIsNotASwipe() {
        // Brief and sharp: one strong sample, well over the peak ceiling.
        var accel = Array(repeating: MotionVector(x: 0.01, y: 0, z: 0), count: 19)
        accel[9] = MotionVector(x: 0, y: 0, z: 0.9)
        XCTAssertNil(
            analyzer.detect(acceleration: accel, gravity: gravity(accel.count),
                            rotation: quietRotation(accel.count))
        )
    }

    func testGentleBriefSpikeIsNotASwipe() {
        // Under the tap ceiling but too short an elevated run to be a drag.
        var accel = Array(repeating: MotionVector(x: 0.01, y: 0, z: 0), count: 19)
        accel[9] = MotionVector(x: 0, y: 0, z: 0.2)
        accel[10] = MotionVector(x: 0, y: 0, z: 0.2)
        XCTAssertNil(
            analyzer.detect(acceleration: accel, gravity: gravity(accel.count),
                            rotation: quietRotation(accel.count))
        )
    }

    func testHeadMotionRejectedByRotationGate() {
        let accel = drag(direction: MotionVector(x: 0, y: 0, z: 1))
        let rotation = Array(repeating: 1.2, count: accel.count)
        XCTAssertNil(
            analyzer.detect(acceleration: accel, gravity: gravity(accel.count),
                            rotation: rotation)
        )
    }

    func testSustainedAdjustmentIsNotASwipe() {
        // An earbud adjustment holds elevated acceleration past the drag ceiling.
        let accel = drag(direction: MotionVector(x: 0, y: 0, z: 1),
                         elevated: 16, lead: 2, tail: 2)
        XCTAssertNil(
            analyzer.detect(acceleration: accel, gravity: gravity(accel.count),
                            rotation: quietRotation(accel.count))
        )
    }

    func testOngoingDragDoesNotFireUntilComplete() {
        // Elevated at the window's end: the finger is still moving — wait.
        let accel = drag(direction: MotionVector(x: 0, y: 0, z: 1),
                         elevated: 7, lead: 12, tail: 0)
        XCTAssertNil(
            analyzer.detect(acceleration: accel, gravity: gravity(accel.count),
                            rotation: quietRotation(accel.count))
        )
    }

    func testMissingGravityReportsNothing() {
        let accel = drag(direction: MotionVector(x: 0, y: 0, z: 1))
        XCTAssertNil(
            analyzer.detect(acceleration: accel,
                            gravity: Array(repeating: .zero, count: accel.count),
                            rotation: quietRotation(accel.count))
        )
    }

    func testTooFewSamplesDoesNotFire() {
        let accel = Array(repeating: MotionVector(x: 0.2, y: 0, z: 0), count: 3)
        XCTAssertNil(
            analyzer.detect(acceleration: accel, gravity: gravity(accel.count),
                            rotation: quietRotation(accel.count))
        )
    }
}
