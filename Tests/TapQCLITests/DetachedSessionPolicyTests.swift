import XCTest
import TapQContracts
@testable import TapQCLI

/// The answers a detached session's hooks get (`docs/SESSION_FOCUS_PLAN.md` §2): at once,
/// in silence, and the same as if TapQ were not there — except for a session TapQ started,
/// which has no screen to fall back to and is denied so it winds down.
final class DetachedSessionPolicyTests: XCTestCase {
    func testAKeyboardSessionsApprovalGoesToItsOwnScreen() {
        XCTAssertEqual(DetachedSessionPolicy.approval(ownedByTapQ: false), .ask)
    }

    func testAnOwnedSessionsApprovalIsDeniedBecauseItHasNoScreen() {
        XCTAssertEqual(DetachedSessionPolicy.approval(ownedByTapQ: true), .deny)
    }

    func testASelectionFallsThroughToTheAgentsOwnPicker() {
        XCTAssertTrue(DetachedSessionPolicy.selection.timedOut)
        XCTAssertTrue(DetachedSessionPolicy.selection.choices.isEmpty)
    }

    func testAStopQuestionGetsNoReply() {
        XCTAssertNil(DetachedSessionPolicy.stopQuestionReply)
    }
}
