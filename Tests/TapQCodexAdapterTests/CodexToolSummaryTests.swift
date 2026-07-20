import XCTest
@testable import TapQCodexAdapter
import TapQWireProtocol

final class CodexToolSummaryTests: XCTestCase {
    func testBashCommandGetsShortSpokenSummary() {
        let presentation = CodexToolSummary.render(
            toolName: "Bash",
            input: ["command": .string("swift test")]
        )

        XCTAssertEqual(presentation.summary, "run swift test")
        XCTAssertEqual(presentation.detail, "Run the command: swift test")
    }

    func testBashUsesCodexApprovalDescriptionForDetails() {
        let presentation = CodexToolSummary.render(
            toolName: "Bash",
            input: [
                "command": .string("git push origin main"),
                "description": .string("Publish the branch to the remote"),
            ]
        )

        XCTAssertEqual(presentation.summary, "run git push origin main")
        XCTAssertEqual(presentation.detail, "Publish the branch to the remote")
    }

    func testLongBashCommandIsBoundedAndNewlinesAreCollapsed() {
        let presentation = CodexToolSummary.render(
            toolName: "Bash",
            input: ["command": .string(
                "git log --oneline --graph --decorate\n--all --since yesterday --author me"
            )]
        )

        XCTAssertTrue(presentation.summary.hasSuffix("…"))
        XCTAssertFalse(presentation.summary.contains("\n"))
        XCTAssertFalse(presentation.detail.contains("\n"))
    }

    func testApplyPatchUsesStableSummaryAndDescription() {
        let presentation = CodexToolSummary.render(
            toolName: "apply_patch",
            input: [
                "command": .string("*** Begin Patch\n*** Update File: A.swift"),
                "description": .string("Update the parser"),
            ]
        )

        XCTAssertEqual(presentation.summary, "apply a code patch")
        XCTAssertEqual(presentation.detail, "Update the parser")
    }

    func testUnknownToolFallsBackToCompactArguments() {
        let presentation = CodexToolSummary.render(
            toolName: "mcp__filesystem__read_file",
            input: ["path": .string("/tmp/a")]
        )

        XCTAssertEqual(
            presentation.summary,
            "use the mcp__filesystem__read_file tool"
        )
        XCTAssertTrue(presentation.detail.contains("path"))
    }
}
