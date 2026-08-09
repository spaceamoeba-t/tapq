import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

@MainActor
final class MotionGatedSwipesTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @MainActor
    final class FakeSwipes: VolumeSwipeProviding {
        var onSwipe: (@MainActor (VolumeSwipeCommand) -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0
        func start(onSwipe: @escaping @MainActor (VolumeSwipeCommand) -> Void) {
            starts += 1
            self.onSwipe = onSwipe
        }
        func stop() { stops += 1 }
        func fire(_ command: VolumeSwipeCommand) { onSwipe?(command) }
    }

    func testEligibleStartDelegatesAndForwardsSwipes() {
        let inner = FakeSwipes()
        let gated = MotionGatedSwipes(wrapping: inner, isEligible: { true })
        var received: [VolumeSwipeCommand] = []
        gated.start { received.append($0) }
        XCTAssertEqual(inner.starts, 1)
        inner.fire(.swipeDown)
        XCTAssertEqual(received, [.swipeDown])
    }

    func testIneligibleStartLeavesInnerUntouched() {
        let sink = RecordingSink()
        let inner = FakeSwipes()
        let gated = MotionGatedSwipes(
            wrapping: inner, isEligible: { false }, diagnosticSink: sink)
        var received: [VolumeSwipeCommand] = []
        gated.start { received.append($0) }
        XCTAssertEqual(inner.starts, 0, "no listener may attach to the built-in speaker")
        inner.fire(.swipeDown)
        XCTAssertEqual(received, [], "a volume key press is not a navigation command")
        let suppressed = sink.events.first { $0.name == "swipes.suppressed" }
        XCTAssertEqual(suppressed?.fields["reason"], "motion_unavailable")
    }

    func testIneligibleStopIsNotForwarded() {
        let inner = FakeSwipes()
        let gated = MotionGatedSwipes(wrapping: inner, isEligible: { false })
        gated.start { _ in }
        gated.stop()
        XCTAssertEqual(inner.stops, 0, "teardown must stay balanced with startup")
    }

    func testEligibleStopIsForwardedOnce() {
        let inner = FakeSwipes()
        let gated = MotionGatedSwipes(wrapping: inner, isEligible: { true })
        gated.start { _ in }
        gated.stop()
        gated.stop()
        XCTAssertEqual(inner.stops, 1)
    }

    func testEligibilityIsReEvaluatedOnEveryWindow() {
        // The upgrade path: AirPods connected mid-session. `SelectionArbiter` starts and
        // stops swipes per window, so the next window is the one that recovers them.
        let inner = FakeSwipes()
        var eligible = false
        let gated = MotionGatedSwipes(wrapping: inner, isEligible: { eligible })

        gated.start { _ in }
        gated.stop()
        XCTAssertEqual(inner.starts, 0)

        eligible = true
        gated.start { _ in }
        XCTAssertEqual(inner.starts, 1, "a device that appeared between windows re-enables swipes")
        gated.stop()
        XCTAssertEqual(inner.stops, 1)
    }

    func testEligibilityLossBetweenWindowsDisablesSwipesAgain() {
        let inner = FakeSwipes()
        var eligible = true
        let gated = MotionGatedSwipes(wrapping: inner, isEligible: { eligible })

        gated.start { _ in }
        gated.stop()
        eligible = false
        gated.start { _ in }

        XCTAssertEqual(inner.starts, 1, "the second window found no device and stayed off")
        XCTAssertEqual(inner.stops, 1)
    }
}
