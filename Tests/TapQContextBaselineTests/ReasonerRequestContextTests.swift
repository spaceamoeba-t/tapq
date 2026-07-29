import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// Pins the broker-request → reasoner-context mapping, including the `commandText`
/// convention the bench corpus was recorded against. A drift here would feed the model a
/// different action than the one the user was asked about, without failing anything else.
final class ReasonerRequestContextTests: XCTestCase {
    private func request(
        toolName: String,
        toolInput: [String: JSONValue]?,
        agent: AgentIdentity = .claudeCode,
        summary: String = "run npm test",
        detail: String = "Run the command: npm test",
        cwd: String? = "/Users/dev/project"
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: "req-1",
            sessionID: "s1",
            agent: agent,
            toolName: toolName,
            summary: summary,
            detail: detail,
            toolInput: toolInput,
            cwd: cwd,
            permissionMode: "default",
            approvalSource: .preToolUse
        )
    }

    // MARK: - Presentation and identity

    func testCarriesPresentationIdentityAndWorkingDirectory() {
        let context = ReasonerContext(approvalRequest: request(
            toolName: "Bash",
            toolInput: ["command": .string("npm test")]
        ))
        XCTAssertEqual(context.toolName, "Bash")
        XCTAssertEqual(context.summary, "run npm test")
        XCTAssertEqual(context.detail, "Run the command: npm test")
        XCTAssertEqual(context.cwd, "/Users/dev/project")
        XCTAssertEqual(context.agentName, "Claude Code")
    }

    func testAgentNameUsesDisplayNameIncludingTheLegacyIdentity() {
        XCTAssertEqual(
            ReasonerContext(approvalRequest: request(
                toolName: "Bash",
                toolInput: nil,
                agent: .codex
            )).agentName,
            "Codex"
        )
        XCTAssertEqual(
            ReasonerContext(approvalRequest: request(
                toolName: "Bash",
                toolInput: nil,
                agent: .unknown
            )).agentName,
            "The agent",
            "legacy clients appear in the corpus under AgentIdentity.unknown's display name"
        )
    }

    func testAbsentWorkingDirectoryAndBlankDetailBecomeNil() {
        let context = ReasonerContext(approvalRequest: request(
            toolName: "Bash",
            toolInput: ["command": .string("npm test")],
            detail: "   \n ",
            cwd: nil
        ))
        XCTAssertNil(context.cwd)
        XCTAssertNil(context.detail, "a blank detail is absence, not an empty detail")
    }

    // MARK: - commandText convention

    func testBashCommandTextIsTheFullCommandLine() {
        let context = ReasonerContext(approvalRequest: request(
            toolName: "Bash",
            toolInput: [
                "command": .string("rm -rf ~/Documents/tax-2025"),
                "description": .string("clean up"),
            ]
        ))
        XCTAssertEqual(context.commandText, "rm -rf ~/Documents/tax-2025")
    }

    func testApplyPatchCommandTextIsThePatchWithNewlinesPreserved() {
        let patch = "*** Begin Patch\n*** Delete File: Sources/A.swift\n*** End Patch"
        let context = ReasonerContext(approvalRequest: request(
            toolName: "apply_patch",
            toolInput: ["command": .string(patch)],
            agent: .codex
        ))
        XCTAssertEqual(context.commandText, patch)
    }

    func testFileToolsUseTheirPrimaryPathArgument() {
        for tool in ["Write", "Edit", "MultiEdit"] {
            let context = ReasonerContext(approvalRequest: request(
                toolName: tool,
                toolInput: [
                    "file_path": .string("/Users/dev/project/README.md"),
                    "old_string": .string("a"),
                ]
            ))
            XCTAssertEqual(context.commandText, "/Users/dev/project/README.md", tool)
        }
    }

    func testNotebookEditPrefersNotebookPathAndFallsBackToFilePath() {
        XCTAssertEqual(
            ReasonerContext(approvalRequest: request(
                toolName: "NotebookEdit",
                toolInput: [
                    "notebook_path": .string("/nb/run.ipynb"),
                    "file_path": .string("/nb/other.ipynb"),
                ]
            )).commandText,
            "/nb/run.ipynb"
        )
        XCTAssertEqual(
            ReasonerContext(approvalRequest: request(
                toolName: "NotebookEdit",
                toolInput: ["file_path": .string("/nb/other.ipynb")]
            )).commandText,
            "/nb/other.ipynb"
        )
    }

    func testUnmappedToolHasNoCommandText() {
        let context = ReasonerContext(approvalRequest: request(
            toolName: "WebFetch",
            toolInput: ["url": .string("https://example.com"), "prompt": .string("read")]
        ))
        XCTAssertNil(
            context.commandText,
            "a tool whose input is not a command must not have one invented from its fields"
        )
        XCTAssertEqual(context.toolName, "WebFetch")
    }

    // MARK: - Missing and malformed fields

    func testMissingToolInputMissingKeyWrongTypeAndBlankAllCollapseToNil() {
        let cases: [(String, [String: JSONValue]?)] = [
            ("absent tool input", nil),
            ("empty tool input", [:]),
            ("missing key", ["description": .string("no command here")]),
            ("non-string value", ["command": .number(7)]),
            ("null value", ["command": .null]),
            ("blank value", ["command": .string("   ")]),
        ]
        for (label, toolInput) in cases {
            let context = ReasonerContext(approvalRequest: request(
                toolName: "Bash",
                toolInput: toolInput
            ))
            XCTAssertNil(context.commandText, label)
            XCTAssertEqual(context.summary, "run npm test",
                           "\(label): the summary still describes the action")
        }
    }

    func testFileToolWithMissingPathHasNoCommandText() {
        let context = ReasonerContext(approvalRequest: request(
            toolName: "Write",
            toolInput: ["content": .string("hello")]
        ))
        XCTAssertNil(context.commandText)
    }
}
