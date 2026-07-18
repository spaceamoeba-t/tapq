import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

final class PrioritySpeechQueueTests: XCTestCase {
    func testEqualPriorityRemainsFifo() {
        var queue = PrioritySpeechQueue()
        queue.enqueue(.init(text: "first", priority: .notification))
        queue.enqueue(.init(text: "second", priority: .notification))
        let first = queue.startNext()
        XCTAssertEqual(first?.text, "first")
        _ = queue.completeCurrent(id: first!.id)
        XCTAssertEqual(queue.startNext()?.text, "second")
    }

    func testHigherPriorityRequestsPreemption() {
        var queue = PrioritySpeechQueue()
        queue.enqueue(.init(text: "progress", priority: .progress))
        let current = queue.startNext()!
        XCTAssertTrue(queue.enqueue(.init(text: "approval", priority: .approval)))
        _ = queue.completeCurrent(id: current.id)
        XCTAssertEqual(queue.startNext()?.text, "approval")
    }

    func testLowerPriorityDoesNotPreempt() {
        var queue = PrioritySpeechQueue()
        queue.enqueue(.init(text: "approval", priority: .approval))
        _ = queue.startNext()
        XCTAssertFalse(queue.enqueue(.init(text: "progress", priority: .progress)))
    }

    func testRemovingPendingRetainsCurrent() {
        var queue = PrioritySpeechQueue()
        queue.enqueue(.init(text: "current", priority: .notification))
        _ = queue.startNext()
        queue.enqueue(.init(text: "pending", priority: .notification))
        XCTAssertEqual(queue.removeAllPending().map(\.text), ["pending"])
        XCTAssertTrue(queue.isBusy)
        XCTAssertEqual(queue.pendingCount, 0)
    }
}
