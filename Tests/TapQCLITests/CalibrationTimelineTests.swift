import XCTest
@testable import TapQCLI

final class CalibrationTimelineTests: XCTestCase {
    func testPhasesAreSeparatedByDiscardedWarmupAndTransitions() {
        let timeline = CalibrationTimeline(options: CalibrationRunOptions(
            restDuration: 3,
            nodDuration: 4,
            shakeDuration: 4,
            tapDuration: 4
        ))

        XCTAssertNil(timeline.phase(at: 0.5))
        XCTAssertEqual(timeline.phase(at: 1.0), .resting)
        XCTAssertNil(timeline.phase(at: 4.5))
        XCTAssertEqual(timeline.phase(at: 5.0), .nod)
        XCTAssertNil(timeline.phase(at: 9.5))
        XCTAssertEqual(timeline.phase(at: 10.0), .shake)
        XCTAssertNil(timeline.phase(at: 14.5))
        XCTAssertEqual(timeline.phase(at: 15.0), .tap)
        XCTAssertNil(timeline.phase(at: 19.0))
        XCTAssertEqual(timeline.totalDuration, 19)
    }

    func testGestureOnlyTimelineDoesNotRepeatTap() {
        var options = CalibrationRunOptions(target: .gesture)
        options.restDuration = 3
        options.nodDuration = 4
        options.shakeDuration = 4
        let timeline = CalibrationTimeline(options: options)

        XCTAssertEqual(timeline.totalDuration, 14)
        XCTAssertFalse(timeline.stages.contains { $0.phase == .tap })
    }

    func testTapOnlyTimelineCapturesFreshRestingBaseline() {
        var options = CalibrationRunOptions(target: .tap)
        options.restDuration = 3
        options.tapDuration = 4
        let timeline = CalibrationTimeline(options: options)

        XCTAssertEqual(timeline.totalDuration, 9)
        XCTAssertEqual(timeline.phase(at: 1), .resting)
        XCTAssertNil(timeline.phase(at: 4.5))
        XCTAssertEqual(timeline.phase(at: 5), .tap)
        XCTAssertFalse(timeline.stages.contains { $0.phase == .nod || $0.phase == .shake })
    }
}
