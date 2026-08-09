import XCTest
import TapQContracts
import TapQDetectionBaseline
@testable import TapQInteractionBaseline

/// Tier 2: motion that must never become a decision.
///
/// Each case pairs the negative with its positive control, because a rejection test that
/// no longer generates the thing it is rejecting passes for the wrong reason.
@MainActor
final class FalsePositiveE2ETests: XCTestCase {
    /// Six seconds of walking and looking around, fed into an open approval window. The
    /// user never answered, so the only correct ending is the one an unanswered request
    /// already has: the window times out and the request goes back to the screen.
    func testAmbientNoiseNeverApproves() async {
        let harness = DetectionPathHarness()
        let decision = Task { await harness.interaction.resolve(Self.request) }
        let window = await harness.waitForWindow(1)
        XCTAssertTrue(window)

        harness.feed(TraceGenerators.ambientNoise())

        XCTAssertFalse(harness.diagnostics.events.contains { Self.inputEvents.contains($0.name) },
                       "ambient motion reached the arbiter as an input")

        harness.timeouts.expire()
        let outcome = await decision.value
        XCTAssertEqual(outcome, .ask, "an unanswered approval defers; it never allows")
        XCTAssertTrue(harness.speech.said("Deferring to the screen."))
        XCTAssertEqual(harness.inputs.openedWindows, 1,
                       "the noise neither answered the window nor caused a re-listen")
        XCTAssertEqual(harness.timeouts.requested, [240],
                       "the decision came from the window timeout, not from an input")
    }

    /// A double-tap whose spikes land while the head is turning is not a double-tap: the
    /// same acceleration a finger makes is also what a shake's turnaround makes, and the
    /// rotation gate is the only thing telling them apart. Cleared first, then contaminated.
    func testRotationContaminatedTapIsRejected() async throws {
        let clean = DetectionPathHarness()
        let approved = Task { await clean.interaction.resolve(Self.request) }
        let cleanWindow = await clean.waitForWindow(1)
        XCTAssertTrue(cleanWindow)
        clean.feed(TraceGenerators.doubleTap())
        let cleanOutcome = await approved.value
        clean.assertWatchdogDidNotFire()
        XCTAssertEqual(cleanOutcome, .allow, "the trace must be a real double-tap")

        let harness = DetectionPathHarness()
        let decision = Task { await harness.interaction.resolve(Self.request) }
        let window = await harness.waitForWindow(1)
        XCTAssertTrue(window)

        harness.feed(TraceGenerators.doubleTap(rotation: Self.contaminatedRotation))

        let rejected = try XCTUnwrap(
            harness.diagnostics.events.first { $0.name == "tap.candidate_rejected" },
            "the analyzer logged no verdict on the spike at all"
        )
        XCTAssertEqual(rejected.fields["reason"], "rotation_not_quiet")
        XCTAssertEqual(rejected.fields["peak_g"], "0.7000",
                       "the spike must clear tap amplitude, so rotation is the sole defect")
        XCTAssertEqual(rejected.fields["max_rotation_rad_s"], "0.9000")
        XCTAssertFalse(harness.diagnostics.events.contains { $0.name == "input.tap" },
                       "a rejected tap must not reach the arbiter")

        harness.timeouts.expire()
        let outcome = await decision.value
        XCTAssertEqual(outcome, .ask)
        XCTAssertEqual(harness.inputs.openedWindows, 1)
    }

    /// The motion-swipe channel is experimental and ships off. One trace, two harnesses:
    /// with the flagless default it is inert, and with the flag set the same samples
    /// navigate — so the default-off guarantee is not just an undetectable trace.
    func testSwipeStaysInertUntilTheFlagIsSet() async {
        let drag = TraceGenerators.swipe(.swipeDown)

        let flagless = DetectionPathHarness()
        let ignored = Task { await flagless.selection.resolve(Self.selectionRequest) }
        let flaglessWindow = await flagless.waitForWindow(1)
        XCTAssertTrue(flaglessWindow)
        flagless.feed(drag)
        XCTAssertFalse(flagless.diagnostics.events.contains { $0.name == "input.swipe" },
                       "the default pipeline emitted a swipe")

        flagless.timeouts.expire()
        let ignoredResult = await ignored.value
        XCTAssertTrue(ignoredResult.timedOut)
        XCTAssertTrue(ignoredResult.choices.isEmpty)
        XCTAssertEqual(flagless.inputs.openedWindows, 1, "no navigation, so no re-listen")

        let enabled = DetectionPathHarness { $0.swipeDetectionEnabled = true }
        let result = Task { await enabled.selection.resolve(Self.selectionRequest) }
        let firstWindow = await enabled.waitForWindow(1)
        XCTAssertTrue(firstWindow)
        enabled.feed(drag)

        let secondWindow = await enabled.waitForWindow(2)
        XCTAssertTrue(secondWindow, "the drag must advance and re-listen")
        enabled.feed(TraceGenerators.swipe(.swipeUp))

        let thirdWindow = await enabled.waitForWindow(3)
        XCTAssertTrue(thirdWindow)
        enabled.feed(TraceGenerators.doubleNod())

        let selection = await result.value
        enabled.assertWatchdogDidNotFire()
        XCTAssertEqual(
            enabled.diagnostics.events.filter { $0.name == "input.swipe" }
                .map { $0.fields["swipe"] },
            ["swipeDown", "swipeUp"]
        )
        XCTAssertEqual(
            enabled.diagnostics.events.filter { $0.name == "selection.navigated" }
                .map { $0.fields["intent"] },
            ["next", "previous", "select"]
        )
        XCTAssertEqual(selection.choices.map(\.index), [0],
                       "one option forward and one back lands where it started")
    }

    /// 1.5x `TapConfig.rotationQuiet` (0.6 rad/s): the head is plainly turning, not still.
    private static let contaminatedRotation = 0.9

    /// Every arbiter event that means "an input won the window". None may appear in a
    /// window that only saw noise.
    private static let inputEvents: Set<String> = [
        "input.gesture", "input.tap", "input.tilt", "input.swipe", "input.voice",
    ]

    private static let request = ApprovalRequest(
        id: "r1", sessionID: "s1", toolName: "Bash",
        summary: "run the test suite", detail: "swift test"
    )

    private static let selectionRequest = SelectionRequest(
        id: "r1", sessionID: "s1", question: "Which format?",
        options: [
            .init(label: "PDF", description: ""),
            .init(label: "PNG", description: ""),
            .init(label: "SVG", description: ""),
        ],
        multiSelect: false
    )
}
