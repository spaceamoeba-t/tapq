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

    func testCanonicalMCPToolGetsHumanizedWithoutSpeakingArguments() {
        let presentation = CodexToolSummary.render(
            toolName: "mcp__filesystem__read_file",
            input: ["path": .string("/tmp/a")]
        )

        XCTAssertEqual(presentation.summary, "use read file from filesystem")
        XCTAssertEqual(presentation.detail, "Use read file from the filesystem MCP server")
        XCTAssertFalse(presentation.summary.contains("/tmp/a"))
        XCTAssertFalse(presentation.detail.contains("/tmp/a"))
    }

    func testMCPPresentationNeverIncludesArbitraryNestedArgumentValues() {
        let secrets = [
            "tapq-secret-token-7",
            "/Users/example/.ssh/id_ed25519",
            "private message body\nwith another line",
            "Bearer private-authorization",
            "description supplied by an untrusted tool",
        ]
        let presentation = CodexToolSummary.render(
            toolName: "mcp__github__create_issue",
            input: [
                "token": .string(secrets[0]),
                "path": .string(secrets[1]),
                "content": .string(secrets[2]),
                "nested": .object([
                    "authorization": .string(secrets[3]),
                ]),
                "description": .string(secrets[4]),
            ]
        )

        XCTAssertEqual(presentation.summary, "use create issue from github")
        XCTAssertEqual(presentation.detail, "Use create issue from the github MCP server")
        for secret in secrets {
            XCTAssertFalse(presentation.summary.contains(secret))
            XCTAssertFalse(presentation.detail.contains(secret))
        }
        XCTAssertFalse(presentation.summary.contains("\n"))
        XCTAssertFalse(presentation.detail.contains("\n"))
    }

    func testMCPPresentationIsBoundedAndNewlineFreeForAdversarialNames() {
        let server = String(repeating: "private_server_", count: 30) + "\ncredentials"
        let operation = String(repeating: "write_content_", count: 30) + "\nnow"
        let presentation = CodexToolSummary.render(
            toolName: "mcp__\(server)__\(operation)",
            input: ["content": .string("never speak this content")]
        )

        XCTAssertLessThanOrEqual(presentation.summary.count, 64)
        XCTAssertLessThanOrEqual(presentation.detail.count, 160)
        XCTAssertTrue(presentation.summary.hasSuffix("…"))
        XCTAssertTrue(presentation.detail.hasSuffix("…"))
        XCTAssertFalse(presentation.summary.contains("\n"))
        XCTAssertFalse(presentation.detail.contains("\n"))
        XCTAssertFalse(presentation.summary.contains("never speak this content"))
        XCTAssertFalse(presentation.detail.contains("never speak this content"))
    }

    func testMalformedMCPNameUsesSafeGenericPresentation() {
        let presentation = CodexToolSummary.render(
            toolName: "mcp__missing_separator",
            input: ["password": .string("do-not-speak")]
        )

        XCTAssertEqual(presentation.summary, "use an MCP tool")
        XCTAssertEqual(presentation.detail, "Use an MCP tool")
        XCTAssertFalse(presentation.summary.contains("do-not-speak"))
        XCTAssertFalse(presentation.detail.contains("do-not-speak"))
    }

    func testNonMCPUnknownToolKeepsCompactArgumentFallback() {
        let presentation = CodexToolSummary.render(
            toolName: "custom_tool",
            input: ["path": .string("/tmp/a")]
        )

        XCTAssertEqual(presentation.summary, "use the custom_tool tool")
        XCTAssertTrue(presentation.detail.contains("path"))
        XCTAssertTrue(presentation.detail.contains("tmp"))
    }
}
