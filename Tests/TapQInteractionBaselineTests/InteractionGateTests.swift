import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

@MainActor
final class InteractionGateTests: XCTestCase {
    private func tick() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testSecondBodyWaitsForFirstToFinish() async {
        let gate = InteractionGate()
        var events: [String] = []
        var release: CheckedContinuation<Void, Never>?

        let first = Task { @MainActor in
            await gate.run {
                events.append("a-start")
                await withCheckedContinuation { release = $0 }
                events.append("a-end")
                return 1
            }
        }
        await tick()
        let second = Task { @MainActor in
            await gate.run {
                events.append("b-start")
                return 2
            }
        }
        await tick()
        XCTAssertEqual(events, ["a-start"], "second body must not start while first is running")

        release?.resume()
        let r1 = await first.value
        let r2 = await second.value
        XCTAssertEqual(r1, 1)
        XCTAssertEqual(r2, 2)
        XCTAssertEqual(events, ["a-start", "a-end", "b-start"])
    }

    func testReturnsBodyValueWhenUncontended() async {
        let gate = InteractionGate()
        let value = await gate.run { "hello" }
        XCTAssertEqual(value, "hello")
    }
}
