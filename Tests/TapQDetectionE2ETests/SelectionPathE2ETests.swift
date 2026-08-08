import XCTest
import TapQContracts
@testable import TapQInteractionBaseline

/// Tier 1: navigating a multi-option question with the head alone.
@MainActor
final class SelectionPathE2ETests: XCTestCase {
    /// Two lateral tilts walk the cursor forward one option each, and a nod confirms
    /// wherever it landed. Three sequential windows on one `SelectionController.resolve`,
    /// all of them answered by motion.
    func testTiltTiltNodSelectsTheThirdOption() async {
        let harness = DetectionPathHarness()
        let result = Task { await harness.selection.resolve(Self.request) }

        let firstWindow = await harness.waitForWindow(1)
        XCTAssertTrue(firstWindow)
        harness.feed(TraceGenerators.doubleTilt(.tiltRight))

        let secondWindow = await harness.waitForWindow(2)
        XCTAssertTrue(secondWindow, "the first tilt must advance and re-listen")
        harness.feed(TraceGenerators.doubleTilt(.tiltRight))

        let thirdWindow = await harness.waitForWindow(3)
        XCTAssertTrue(thirdWindow)
        harness.feed(TraceGenerators.doubleNod())

        let selection = await result.value
        XCTAssertFalse(selection.timedOut)
        XCTAssertEqual(selection.choices.map(\.index), [2])
        XCTAssertEqual(selection.choices.map(\.label), ["SVG"])
        XCTAssertEqual(harness.inputs.openedWindows, 3,
                       "each tilt consumed exactly one window")
    }

    private static let request = SelectionRequest(
        id: "r1", sessionID: "s1", question: "Which format?",
        options: [
            .init(label: "PDF", description: ""),
            .init(label: "PNG", description: ""),
            .init(label: "SVG", description: ""),
        ],
        multiSelect: false
    )
}
