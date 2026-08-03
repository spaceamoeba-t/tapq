import XCTest
@testable import TapQCLI

final class CalibrationTimelineTests: XCTestCase {
    func testPhasesAreSeparatedByDiscardedWarmupAndTransitions() {
        let timeline = CalibrationTimeline(options: CalibrationRunOptions(
            restDuration: 3,
            nodDuration: 4,
            shakeDuration: 4,
            tapDuration: 4,
            speakDuration: 6
        ))

        XCTAssertNil(timeline.phase(at: 0.5))
        XCTAssertEqual(timeline.phase(at: 1.0), .resting)
        XCTAssertNil(timeline.phase(at: 4.5))
        XCTAssertEqual(timeline.phase(at: 5.0), .nod)
        XCTAssertNil(timeline.phase(at: 9.5))
        XCTAssertEqual(timeline.phase(at: 10.0), .shake)
        XCTAssertNil(timeline.phase(at: 14.5))
        XCTAssertEqual(timeline.phase(at: 15.0), .tap)
        XCTAssertNil(timeline.phase(at: 19.5))
        XCTAssertEqual(timeline.phase(at: 20.0), .speak)
        XCTAssertNil(timeline.phase(at: 26.0))
        XCTAssertEqual(timeline.totalDuration, 26)
    }

    /// The speak phase follows the tap phase across a discarded transition: the two share
    /// the acceleration channel, and a fingertip still on the earbud would read as speech.
    func testSpeakPhaseComesLastAndAfterADiscardedTransition() {
        let timeline = CalibrationTimeline(options: CalibrationRunOptions(
            restDuration: 3, nodDuration: 4, shakeDuration: 4,
            tapDuration: 4, speakDuration: 6
        ))
        XCTAssertEqual(timeline.stages.last?.phase, .speak)
        let phases = timeline.stages.map(\.phase)
        guard let speakIndex = phases.firstIndex(of: .speak) else {
            return XCTFail("expected a speak stage")
        }
        XCTAssertNil(phases[speakIndex - 1], "the stage before speak must be discarded")
        XCTAssertEqual(phases[speakIndex - 2], .tap)
    }

    func testWearerSpeechOnlyTimelineCapturesFreshRestingBaselineAndNothingElse() {
        var options = CalibrationRunOptions(target: .wearerSpeech)
        options.restDuration = 3
        options.speakDuration = 6
        let timeline = CalibrationTimeline(options: options)

        XCTAssertEqual(timeline.totalDuration, 11)
        XCTAssertEqual(timeline.phase(at: 1), .resting)
        XCTAssertNil(timeline.phase(at: 4.5))
        XCTAssertEqual(timeline.phase(at: 5), .speak)
        XCTAssertFalse(timeline.stages.contains {
            $0.phase == .nod || $0.phase == .shake || $0.phase == .tap
        })
    }

    func testGestureOnlyTimelineDoesNotRepeatTap() {
        var options = CalibrationRunOptions(target: .gesture)
        options.restDuration = 3
        options.nodDuration = 4
        options.shakeDuration = 4
        let timeline = CalibrationTimeline(options: options)

        XCTAssertEqual(timeline.totalDuration, 14)
        XCTAssertFalse(timeline.stages.contains {
            $0.phase == .tap || $0.phase == .speak
        })
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
        XCTAssertFalse(timeline.stages.contains {
            $0.phase == .nod || $0.phase == .shake || $0.phase == .speak
        })
    }
}
