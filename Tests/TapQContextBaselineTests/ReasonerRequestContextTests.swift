import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// Pins the request → reasoner-context mappings for both things the runtime makes the
/// user answer — a broker approval and a question the agent asked — including the
/// `commandText` and `AgentQuestion` conventions the bench corpus was recorded against. A
/// drift here would feed the model a different action than the one the user was asked
/// about, without failing anything else.
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

    /// Cursor names the same operation `Shell` and sends it under the same `command` key,
    /// so it must reach the reasoner as a command line rather than as an unmapped tool.
    func testCursorShellCommandTextIsTheFullCommandLine() {
        let context = ReasonerContext(approvalRequest: request(
            toolName: "Shell",
            toolInput: ["command": .string("rm -rf ~/Documents/tax-2025")],
            agent: .cursor
        ))
        XCTAssertEqual(context.commandText, "rm -rf ~/Documents/tax-2025")
        XCTAssertEqual(context.agentName, "Cursor")
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
        XCTAssertNil(context.toolInput, "only open-schema MCP inputs are copied wholesale")
    }

    func testCodexMCPCallCarriesTheCompleteOpenSchemaInput() {
        let input: [String: JSONValue] = [
            "channel": .string("release-room"),
            "message": .string("Deploy completed"),
            "metadata": .object([
                "notify": .bool(true),
                "labels": .array([.string("production"), .string("urgent")]),
            ]),
        ]
        let context = ReasonerContext(approvalRequest: request(
            toolName: "mcp__slack__send_message",
            toolInput: input,
            agent: .codex,
            summary: "use send message from slack",
            detail: "Use send message from the slack MCP server"
        ))

        XCTAssertNil(context.commandText, "an MCP schema has no guessed primary argument")
        XCTAssertEqual(context.toolInput, input, "the reasoner receives the exact local input")
    }

    func testCodexMCPDistinguishesAbsentAndKnownEmptyInput() {
        XCTAssertNil(
            ReasonerContext(approvalRequest: request(
                toolName: "mcp__server__operation",
                toolInput: nil,
                agent: .codex
            )).toolInput
        )
        XCTAssertEqual(
            ReasonerContext(approvalRequest: request(
                toolName: "mcp__server__operation",
                toolInput: [:],
                agent: .codex
            )).toolInput,
            [:],
            "a known argument object with no fields is not the same as missing input"
        )
    }

    func testMalformedMCPNamesDoNotWidenTheReasonerContext() {
        let toolInput: [String: JSONValue] = ["secret": .string("value")]

        for toolName in ["mcp__", "mcp__server", "mcp____tool", "mcp__server__"] {
            XCTAssertNil(
                ReasonerContext.openSchemaToolInput(
                    toolName: toolName,
                    toolInput: toolInput
                ),
                "only canonical mcp__<server>__<tool> names carry open-schema input"
            )
        }
    }

    // MARK: - Question requests

    /// Exactly the request `StopQuestionCoordinator` builds for a yes/no question: the
    /// classified question as `summary`, an empty `detail`, no tool input, no `cwd`.
    private func questionRequest(
        _ question: String,
        agent: AgentIdentity = .claudeCode
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: "q-1",
            sessionID: "s1",
            agent: agent,
            toolName: "StopQuestion",
            summary: question,
            detail: "",
            kind: .question
        )
    }

    func testQuestionRequestCarriesTheSyntheticToolNameAndTheQuestion() {
        let question = "Should I delete the old backups and start fresh?"
        let context = ReasonerContext(questionRequest: questionRequest(question))

        XCTAssertEqual(context.toolName, "AgentQuestion")
        XCTAssertEqual(
            context.toolName,
            ReasonerContext.agentQuestionToolName,
            "the corpus and the runtime must name a question with the same constant"
        )
        XCTAssertNotEqual(
            context.toolName,
            "StopQuestion",
            "the reasoner is told what it is judging, not which runtime path asked"
        )
        XCTAssertEqual(context.questionText, question)
        XCTAssertEqual(
            context.summary,
            question,
            "the question is the line already spoken; the mapping invents no second one"
        )
        XCTAssertEqual(context.agentName, "Claude Code")
        XCTAssertNil(context.optionLabels, "a yes/no question offers no labels")
    }

    /// A question row puts strictly less in front of the model than a `Bash` row: no
    /// command line, no working directory, and an empty detail that reads as absence.
    func testQuestionRequestHasNoCommandTextCwdOrDetail() {
        let context = ReasonerContext(questionRequest: questionRequest("Proceed?"))

        XCTAssertNil(context.commandText)
        XCTAssertNil(context.cwd)
        XCTAssertNil(context.detail, "a blank detail is absence, not an empty detail")
    }

    func testQuestionRequestAgentNameUsesTheDisplayName() {
        XCTAssertEqual(
            ReasonerContext(questionRequest: questionRequest("Ship it?", agent: .codex))
                .agentName,
            "Codex"
        )
        XCTAssertEqual(
            ReasonerContext(questionRequest: questionRequest("Ship it?", agent: .unknown))
                .agentName,
            "The agent"
        )
    }

    /// The labels come in as a parameter because the request cannot carry them: the
    /// multi-option path has no escalation plumbing yet, so nothing passes them today.
    func testQuestionRequestCarriesSuppliedOptionLabels() {
        let context = ReasonerContext(
            questionRequest: questionRequest("Drop the staging database or keep it?"),
            optionLabels: ["Drop and re-seed", "Keep the current data"]
        )
        XCTAssertEqual(context.optionLabels, ["Drop and re-seed", "Keep the current data"])
        XCTAssertEqual(context.questionText, "Drop the staging database or keep it?")
    }

    func testBlankOptionLabelsAreDroppedAndAnEmptyListIsAbsence() {
        XCTAssertEqual(
            ReasonerContext(
                questionRequest: questionRequest("Pick one?"),
                optionLabels: ["Keep it", "   ", "\n", "Drop it"]
            ).optionLabels,
            ["Keep it", "Drop it"],
            "a label with no text is a choice the question never offered"
        )
        for labels in [[], ["  "], ["", " \n "]] {
            XCTAssertNil(
                ReasonerContext(
                    questionRequest: questionRequest("Pick one?"),
                    optionLabels: labels
                ).optionLabels,
                "\(labels): nothing usable is absence, which the renderer omits"
            )
        }
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
