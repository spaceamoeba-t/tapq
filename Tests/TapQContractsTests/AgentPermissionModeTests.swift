import XCTest
@testable import TapQContracts

final class AgentPermissionModeTests: XCTestCase {
    func testParsesOnlyTheModesAgentsActuallySend() {
        XCTAssertEqual(AgentPermissionMode("default"), .default)
        XCTAssertEqual(AgentPermissionMode("acceptEdits"), .acceptEdits)
        XCTAssertEqual(AgentPermissionMode("plan"), .plan)
        XCTAssertEqual(AgentPermissionMode("dontAsk"), .dontAsk)
        XCTAssertEqual(AgentPermissionMode("bypassPermissions"), .bypassPermissions)
        XCTAssertEqual(AgentPermissionMode.allCases.count, 5)

        XCTAssertNil(AgentPermissionMode(nil), "an agent that reports no mode gets no automatic behavior")
        XCTAssertNil(AgentPermissionMode(""))
        XCTAssertNil(AgentPermissionMode("auto"), "\"auto\" is not a mode any agent sends")
        XCTAssertNil(AgentPermissionMode("autoAccept"))
        XCTAssertNil(AgentPermissionMode("acceptedits"), "modes are protocol tokens, matched exactly")
    }

    func testAutoAllowCoversEveryModeAndSplitsAcceptEditsByTool() {
        for tool in ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "WebFetch"] {
            XCTAssertFalse(AgentPermissionMode.default.autoAllows(toolName: tool), tool)
            XCTAssertFalse(AgentPermissionMode.plan.autoAllows(toolName: tool), tool)
            XCTAssertTrue(AgentPermissionMode.dontAsk.autoAllows(toolName: tool), tool)
            XCTAssertTrue(AgentPermissionMode.bypassPermissions.autoAllows(toolName: tool), tool)
        }

        for tool in ["Write", "Edit", "MultiEdit", "NotebookEdit"] {
            XCTAssertTrue(AgentPermissionMode.acceptEdits.autoAllows(toolName: tool), tool)
        }
        for tool in ["Bash", "WebFetch", "AskUserQuestion", "edit"] {
            XCTAssertFalse(AgentPermissionMode.acceptEdits.autoAllows(toolName: tool),
                           "accepting edits is not accepting \(tool)")
        }
    }

    func testOnlyStopAskingModesOptOutOfStopQuestions() {
        XCTAssertTrue(AgentPermissionMode.dontAsk.skipsStopQuestions)
        XCTAssertTrue(AgentPermissionMode.bypassPermissions.skipsStopQuestions)
        XCTAssertFalse(AgentPermissionMode.default.skipsStopQuestions)
        XCTAssertFalse(AgentPermissionMode.plan.skipsStopQuestions)
        XCTAssertFalse(AgentPermissionMode.acceptEdits.skipsStopQuestions,
                       "acceptEdits silences file edits, not questions")
    }
}
