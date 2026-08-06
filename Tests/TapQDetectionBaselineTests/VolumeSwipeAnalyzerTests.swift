import XCTest
@testable import TapQDetectionBaseline
import TapQGestureContracts

final class VolumeSwipeAnalyzerTests: XCTestCase {
    private func makeAnalyzer(initial: Double = 0.5) -> VolumeSwipeAnalyzer {
        var analyzer = VolumeSwipeAnalyzer()
        analyzer.reset(initialVolume: initial)
        return analyzer
    }

    func testSingleStepUpEmitsSwipeUp() {
        var analyzer = makeAnalyzer()
        XCTAssertEqual(analyzer.ingest(volume: 0.5625, at: 10), .swipeUp)
    }

    func testRampIsCoalescedByDebounce() {
        var analyzer = makeAnalyzer()
        let events = [
            analyzer.ingest(volume: 0.53, at: 10.00),
            analyzer.ingest(volume: 0.56, at: 10.08),
            analyzer.ingest(volume: 0.59, at: 10.16),
            analyzer.ingest(volume: 0.62, at: 10.24),
        ].compactMap { $0 }
        XCTAssertEqual(events, [.swipeUp])
    }

    func testSecondSwipeAfterDebounceEmitsAgain() {
        var analyzer = makeAnalyzer()
        XCTAssertEqual(analyzer.ingest(volume: 0.53, at: 10), .swipeUp)
        XCTAssertEqual(analyzer.ingest(volume: 0.56, at: 10.5), .swipeUp)
    }

    func testJitterDoesNotFire() {
        var analyzer = makeAnalyzer()
        XCTAssertNil(analyzer.ingest(volume: 0.505, at: 10))
        XCTAssertNil(analyzer.ingest(volume: 0.510, at: 10.5))
        XCTAssertNil(analyzer.ingest(volume: 0.515, at: 11))
    }

    func testDownStepEmitsSwipeDown() {
        var analyzer = makeAnalyzer()
        XCTAssertEqual(analyzer.ingest(volume: 0.45, at: 10), .swipeDown)
    }
}
