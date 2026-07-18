import XCTest
@testable import TapQAppleAdapters
import TapQContracts
import TapQDetectionBaseline

@MainActor
final class VolumeSwipeDetectorTests: XCTestCase {
    private func makeDetector(initial: Float32 = 0.5) -> (VolumeSwipeDetector, () -> [VolumeSwipeCommand]) {
        let detector = VolumeSwipeDetector()
        var events: [VolumeSwipeCommand] = []
        detector.beginForTesting(initialVolume: initial) { events.append($0) }
        return (detector, { events })
    }

    func testSingleStepUpEmitsOneSwipeUp() {
        let (detector, events) = makeDetector()
        detector.processVolumeChange(0.5625, at: 10.0) // one keyboard-style volume step
        XCTAssertEqual(events(), [.swipeUp])
    }

    func testRampCoalescesIntoOneEvent() {
        let (detector, events) = makeDetector()
        // A stem swipe ramps through several >=2% steps within ~0.25s.
        detector.processVolumeChange(0.53, at: 10.00)
        detector.processVolumeChange(0.56, at: 10.08)
        detector.processVolumeChange(0.59, at: 10.16)
        detector.processVolumeChange(0.62, at: 10.24)
        XCTAssertEqual(events(), [.swipeUp], "a monotonic ramp is one navigation event")
    }

    func testSecondSwipeAfterDebounceEmitsAgain() {
        let (detector, events) = makeDetector()
        detector.processVolumeChange(0.53, at: 10.0)
        detector.processVolumeChange(0.56, at: 10.5) // past the 0.4s debounce
        XCTAssertEqual(events(), [.swipeUp, .swipeUp])
    }

    func testOppositeDirectionInsideDebounceIsSuppressed() {
        let (detector, events) = makeDetector()
        detector.processVolumeChange(0.53, at: 10.0)
        detector.processVolumeChange(0.50, at: 10.2) // reversal inside the debounce window
        XCTAssertEqual(events(), [.swipeUp])
    }

    func testSubSensitivityJitterNeverFires() {
        let (detector, events) = makeDetector()
        detector.processVolumeChange(0.505, at: 10.0)
        detector.processVolumeChange(0.510, at: 10.5)
        detector.processVolumeChange(0.515, at: 11.0)
        XCTAssertTrue(events().isEmpty)
    }

    func testDownRampEmitsSwipeDown() {
        let (detector, events) = makeDetector()
        detector.processVolumeChange(0.45, at: 10.0)
        detector.processVolumeChange(0.40, at: 10.1)
        XCTAssertEqual(events(), [.swipeDown])
    }

    func testStoppedDetectorIgnoresChanges() {
        let detector = VolumeSwipeDetector()
        var events: [VolumeSwipeCommand] = []
        detector.beginForTesting(initialVolume: 0.5) { events.append($0) }
        detector.stop()
        detector.processVolumeChange(0.6, at: 10.0)
        XCTAssertTrue(events.isEmpty)
    }
}
