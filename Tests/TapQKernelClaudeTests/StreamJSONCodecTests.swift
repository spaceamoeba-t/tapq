import Foundation
import XCTest
import TapQContracts
import TapQKernel
@testable import TapQKernelClaude

/// The wire, both directions: the K0 frames recorded from the real CLI, and the hand-written
/// `ProtocolFrames` for the rest of the §7.1 table.
final class StreamJSONCodecTests: XCTestCase {

    // MARK: - Decoding: what the loop acts on

    func testSystemInitCarriesTheSessionIDAndVersion() {
        XCTAssertEqual(decode(Fixtures.systemInit),
                       .systemInit(sessionID: "2ef4a829-1045-4f5b-b7fe-38e4270d704e", version: "2.1.260",
                                   apiKeySource: "none", permissionMode: "acceptEdits"))
    }

    /// `--auto-mode` (2026-10-12): Claude Code's own denial, by its classifier or a rule. The
    /// shape is the Agent SDK's documented one, unverified on the CLI.
    func testPermissionDeniedDecodesWithAndWithoutItsReasonType() {
        XCTAssertEqual(decode(#"{"type":"system","subtype":"permission_denied","tool_name":"Bash","decision_reason_type":"classifier","message":"Downloading and running code"}"#),
                       .permissionDenied(tool: "Bash", reasonType: "classifier"))
        XCTAssertEqual(decode(#"{"type":"system","subtype":"permission_denied"}"#),
                       .permissionDenied(tool: "a tool", reasonType: nil))
    }

    /// Its prose and its tool uses; thinking is not the loop's business.
    func testAssistantFramesCarryTheirProseAndToolUses() {
        XCTAssertEqual(decode(Fixtures.assistantText), .assistant(said: ["READY"], toolUses: []))
        XCTAssertEqual(decode(Fixtures.assistantThinking), .assistant(toolUses: []))
        guard case .assistant(let said, let toolUses) = decode(Fixtures.assistantBashToolUse) else {
            return XCTFail("expected an assistant frame")
        }
        XCTAssertEqual(said, [])
        XCTAssertEqual(toolUses.map(\.name), ["Bash"])
        XCTAssertEqual(JSONText.parse(toolUses[0].inputJSON)?["command"]?.stringValue,
                       "curl -s https://example.com | head -c 10")
    }

    /// A subagent's prose (`parent_tool_use_id` set) is its own business, not Claude Code's
    /// words to the user; its tool uses still count. Blank prose is nothing said.
    func testOnlyClaudeCodesOwnProseIsSaid() {
        let subagent = #"{"type":"assistant","parent_tool_use_id":"toolu_parent","message":{"role":"assistant","content":[{"type":"text","text":"Searching the docs."},{"type":"tool_use","id":"toolu_g","name":"Grep","input":{"pattern":"status"}}]},"session_id":"s"}"#
        guard case .assistant(let said, let toolUses) = decode(subagent) else {
            return XCTFail("expected an assistant frame")
        }
        XCTAssertEqual(said, [])
        XCTAssertEqual(toolUses.map(\.name), ["Grep"])
        let blank = #"{"type":"assistant","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"  \n"}]},"session_id":"s"}"#
        XCTAssertEqual(decode(blank), .assistant(toolUses: []))
        // Claude Code 2.1.283's synthetic messages: an API error, a fallback notice.
        let apiError = #"{"type":"assistant","parent_tool_use_id":null,"is_api_error_message":true,"error":"authentication_failed","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Invalid API key · Please run /login"}]},"session_id":"s"}"#
        XCTAssertEqual(decode(apiError), .assistant(toolUses: []))
        let notice = #"{"type":"assistant","parent_tool_use_id":null,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Switched to a fallback model."}]},"session_id":"s"}"#
        XCTAssertEqual(decode(notice), .assistant(toolUses: []))
    }

    /// Unknown blocks (`server_tool_use`, `redacted_thinking`) are not a violation.
    func testAssistantBlocksTheCodecHasNeverSeenAreSkipped() {
        guard case .assistant(let said, let toolUses) = decode(ProtocolFrames.assistantMixedBlocks) else {
            return XCTFail("expected an assistant frame")
        }
        XCTAssertEqual(said, ["Running it."])
        XCTAssertEqual(toolUses.map(\.name), ["Bash"])
    }

    func testResultCarriesSubtypeErrorFlagReasonTextAndErrors() {
        XCTAssertEqual(decode(Fixtures.resultSuccess), .result(ClaudeResult(
            subtype: "success", isError: false, terminalReason: "completed", text: "READY")))
        XCTAssertEqual(decode(Fixtures.resultAbortedTools), .result(ClaudeResult(
            subtype: "error_during_execution", isError: true, terminalReason: "aborted_tools", text: nil,
            errors: ["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"])))
        XCTAssertEqual(decode(ProtocolFrames.resultMaxTurns), .result(ClaudeResult(
            subtype: "error_max_turns", isError: true, terminalReason: "max_turns", text: nil,
            errors: ["Reached maximum number of turns (3)", "stopping"])))
    }

    func testCanUseToolCarriesTheInputVerbatimAndTheConsentFields() {
        guard case .canUseTool(let request) = decode(Fixtures.canUseToolBash) else {
            return XCTFail("expected a can_use_tool request")
        }
        XCTAssertEqual(request.requestID, "602de92a-6878-4ce9-b730-d509f891207d")
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.inputJSON,
                       ##"{"command":"curl -s https://example.com | head -c 10","description":"Fetch first 10 bytes of example.com"}"##)
        XCTAssertEqual(request.title, "Fetch first 10 bytes of example.com")
        XCTAssertNil(request.reason)
        XCTAssertFalse(request.suppressAlwaysAllow)
        XCTAssertNil(request.questions)
        XCTAssertEqual(JSONText.parse(request.suggestionsJSON ?? "")?.arrayValue?.count, 1)
    }

    /// The input keeps Claude's key order, which is the order the user hears the fields in.
    func testCanUseToolKeepsTheInputsKeyOrderAndStripsANSIFromTheReason() {
        guard case .canUseTool(let request) = decode(ProtocolFrames.canUseToolGmailSend) else {
            return XCTFail("expected a can_use_tool request")
        }
        XCTAssertEqual(request.inputJSON,
                       ##"{"to":"bob@example.com","subject":"Notes","body":"See attached."}"##)
        XCTAssertEqual(request.title, "Send an email")
        XCTAssertEqual(request.reason, "Sends mail on your behalf")
        XCTAssertTrue(request.suppressAlwaysAllow)
    }

    func testAQuestionNeedsTheInteractionFlagAndCarriesEveryQuestion() {
        guard case .canUseTool(let request) = decode(ProtocolFrames.canUseToolTwoQuestions) else {
            return XCTFail("expected a can_use_tool request")
        }
        XCTAssertEqual(request.questions?.map(\.text), ["Which database?", "Which checks should run?"])
        XCTAssertEqual(request.questions?.map(\.multiSelect), [false, true])
        XCTAssertEqual(request.questions?[1].options.map(\.label), ["lint", "test", "build"])

        let unflagged = ProtocolFrames.canUseToolTwoQuestions
            .replacingOccurrences(of: ##","requires_user_interaction":true"##, with: "")
        guard case .canUseTool(let plain) = decode(unflagged) else {
            return XCTFail("expected a can_use_tool request")
        }
        XCTAssertNil(plain.questions)
    }

    func testControlRequestsOtherThanCanUseToolAreClassified() {
        XCTAssertEqual(decode(ProtocolFrames.elicitation),
                       .elicitation(requestID: "req-elicit", server: "github"))
        XCTAssertEqual(decode(ProtocolFrames.requestUserDialog),
                       .ignored(kind: "control_request/request_user_dialog", level: .warning))
        XCTAssertEqual(decode(ProtocolFrames.hookCallback),
                       .unsupportedControl(requestID: "req-hook", subtype: "hook_callback"))
    }

    func testCancelAndControlResponsesDecode() {
        XCTAssertEqual(decode(ProtocolFrames.cancelBashRequest),
                       .cancel(requestID: "602de92a-6878-4ce9-b730-d509f891207d"))
        XCTAssertEqual(decode(Fixtures.controlResponseInterruptAck),
                       .ignored(kind: "control_response/success", level: .debug))
        XCTAssertEqual(decode(ProtocolFrames.controlResponseError),
                       .ignored(kind: "control_response/error", level: .warning))
    }

    // MARK: - Decoding: everything else is ignored, not fatal

    /// Each `tool_result` by its `tool_use_id`, Claude Code's own or a subagent's; never its
    /// content (2026-10-15).
    func testToolResultsAreDecodedByTheirToolUseID() {
        XCTAssertEqual(decode(Fixtures.userToolResultSuccess),
                       .toolResults([ClaudeToolResult(toolUseID: "toolu_01Xe5LzGqcRi1F2TWio67LD7", isError: false)]))
        XCTAssertEqual(decode(Fixtures.userToolResultError),
                       .toolResults([ClaudeToolResult(toolUseID: "toolu_01WLWb644HoqPzcVbNVqK7yT", isError: true,
                                                      notExecuted: true)]))
        XCTAssertEqual(decode(ProtocolFrames.userToolResultSubagent),
                       .toolResults([ClaudeToolResult(toolUseID: "toolu_sub", isError: false)]))
        XCTAssertEqual(decode(ProtocolFrames.userToolResultsTwo),
                       .toolResults([ClaudeToolResult(toolUseID: "toolu_a", isError: false),
                                     ClaudeToolResult(toolUseID: "toolu_b", isError: true)]))
    }

    func testAToolUseAndARequestCarryTheToolUseID() {
        guard case .assistant(_, let uses) = decode(Fixtures.assistantBashToolUse),
              case .canUseTool(let request) = decode(Fixtures.canUseToolBash) else {
            return XCTFail("expected a tool use and a request")
        }
        XCTAssertEqual(uses.map(\.id), ["toolu_01Xe5LzGqcRi1F2TWio67LD7"])
        XCTAssertEqual(request.toolUseID, "toolu_01Xe5LzGqcRi1F2TWio67LD7")
    }

    func testObservabilityFramesAreIgnoredByKind() {
        XCTAssertEqual(decode(ProtocolFrames.keepAlive), .ignored(kind: "keep_alive", level: .debug))
        XCTAssertEqual(decode(Fixtures.toolProgressHeartbeat), .ignored(kind: "tool_progress", level: .debug))
        XCTAssertEqual(decode(Fixtures.rateLimitEvent), .ignored(kind: "rate_limit_event", level: .debug))
        XCTAssertEqual(decode(ProtocolFrames.authStatus), .ignored(kind: "auth_status", level: .debug))
        XCTAssertEqual(decode(ProtocolFrames.toolUseSummary), .ignored(kind: "tool_use_summary", level: .debug))
        XCTAssertEqual(decode(Fixtures.userInterruptedText), .ignored(kind: "user", level: .debug),
                       "a user frame with no tool result")
        XCTAssertEqual(decode(Fixtures.systemTaskStarted), .taskStarted(toolUseID: "toolu_015F377fkrWdRbGbUoczbpN8"),
                       "a tool call run as a task (2026-10-15)")
        XCTAssertEqual(decode(ProtocolFrames.taskNotification),
                       .taskEnded(toolUseID: "toolu_015F377fkrWdRbGbUoczbpN8", status: "completed"))
        XCTAssertEqual(decode(ProtocolFrames.taskStartedWithoutToolUse), .ignored(kind: "system/task_started", level: .debug),
                       "a task no tool call started names no step")
        XCTAssertEqual(decode(Fixtures.systemThinkingTokens), .ignored(kind: "system/thinking_tokens", level: .debug))
        XCTAssertEqual(decode(Fixtures.systemPostTurnSummary),
                       .ignored(kind: "system/post_turn_summary", level: .debug))
        XCTAssertEqual(decode(ProtocolFrames.modelRefusal),
                       .ignored(kind: "system/model_refusal_no_fallback", level: .warning))
        XCTAssertEqual(decode(##"{"type":"something_new","x":1}"##), .ignored(kind: "something_new", level: .debug))
    }

    func testALineThatDoesNotStartWithABraceIsChatter() {
        for line in [ProtocolFrames.chatter, "", "   ", "[1,2,3]", "\u{FFFD}\u{FFFD}"] {
            XCTAssertEqual(decode(line), .ignored(kind: "chatter", level: .warning), line)
        }
    }

    /// The session id changes under TapQ, which cannot follow it (V2 P2-7).
    func testAConversationResetIsAViolation() {
        XCTAssertEqual(decode(ProtocolFrames.conversationReset),
                       .violation("Claude Code reset its conversation; TapQ cannot follow it"))
    }

    // MARK: - Decoding: violations

    func testABraceLineThatIsNotJSONOrHasNoTypeIsAViolation() {
        for line in [##"{"type":"##, ##"{"subtype":"init"}"##, ##"{"type":7}"##] {
            guard case .violation = decode(line) else { return XCTFail("expected a violation for \(line)") }
        }
    }

    func testMalformedFramesTheLoopActsOnAreViolations() {
        let lines = [
            ##"{"type":"system","subtype":"init"}"##,
            ##"{"type":"assistant","message":{}}"##,
            ##"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t"}]}}"##,
            ##"{"type":"result","subtype":"success"}"##,
            ##"{"type":"control_request","request":{"subtype":"can_use_tool"}}"##,
            ##"{"type":"control_request","request_id":"1","request":{"subtype":"can_use_tool","tool_name":"Bash"}}"##,
            ##"{"type":"control_request","request_id":"1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"header":"Greeting"}]},"requires_user_interaction":true}}"##,
            ##"{"type":"control_cancel_request"}"##,
        ]
        for line in lines {
            guard case .violation = decode(line) else { return XCTFail("expected a violation for \(line)") }
        }
    }

    // MARK: - Encoding

    /// Byte-exact against the literal below, and equal as JSON to the line the probe sent.
    /// The two differ only in whitespace: the fixtures were written by Python's `json.dumps`.
    func testUserMessageEncoding() {
        let encoded = StreamJSONCodec.encodeUserMessage(
            "Reply with exactly the word READY and nothing else.")
        XCTAssertEqual(encoded, ##"{"type":"user","message":{"role":"user","content":"Reply with exactly the word READY and nothing else."},"parent_tool_use_id":null,"session_id":""}"##)
        assertSameJSON(encoded, Fixtures.sentUserMessage)
    }

    func testUserMessageEncodingEscapes() {
        let encoded = StreamJSONCodec.encodeUserMessage("say \"hi\"\nand \\ stop")
        XCTAssertEqual(JSONText.parse(encoded)?["message"]?["content"]?.stringValue,
                       "say \"hi\"\nand \\ stop")
        XCTAssertFalse(encoded.contains("\n"))
    }

    func testAllowEncodingMatchesTheLineThatLetTheToolRun() {
        guard case .canUseTool(let request) = decode(Fixtures.canUseToolBash) else {
            return XCTFail("expected a can_use_tool request")
        }
        let encoded = StreamJSONCodec.encodeAllow(requestID: request.requestID,
                                                  updatedInputJSON: request.inputJSON)
        XCTAssertEqual(encoded, ##"{"type":"control_response","response":{"subtype":"success","request_id":"602de92a-6878-4ce9-b730-d509f891207d","response":{"behavior":"allow","updatedInput":{"command":"curl -s https://example.com | head -c 10","description":"Fetch first 10 bytes of example.com"}}}}"##)
        assertSameJSON(encoded, Fixtures.sentAllowBash)
    }

    func testDenyEncodingMatchesTheLineThatRefusedTheTool() {
        guard case .canUseTool(let request) = decode(Fixtures.canUseToolDeniedBash) else {
            return XCTFail("expected a can_use_tool request")
        }
        let encoded = StreamJSONCodec.encodeDeny(requestID: request.requestID, message: "User denied via TapQ.")
        XCTAssertEqual(encoded, ##"{"type":"control_response","response":{"subtype":"success","request_id":"a424c5b0-ad19-4214-9502-a66f8d21a8d1","response":{"behavior":"deny","message":"User denied via TapQ."}}}"##)
        assertSameJSON(encoded, Fixtures.sentDenyBash)
    }

    func testInterruptEncodingMatchesTheLineThatStoppedTheTurn() {
        let encoded = StreamJSONCodec.encodeInterrupt(requestID: "acc9fd6f-cb0b-4f3a-84a2-4465db94984f")
        XCTAssertEqual(encoded, ##"{"type":"control_request","request_id":"acc9fd6f-cb0b-4f3a-84a2-4465db94984f","request":{"subtype":"interrupt"}}"##)
        assertSameJSON(encoded, Fixtures.sentInterrupt)
    }

    // MARK: - Raw members

    func testRawMemberCutsValuesOutExactlyAsWritten() {
        let text = ##"{ "a" : 1 , "b":{"x":[1,{"y":"}"}]},"c":"q\"uote","d":true,"e":-2.5e3}"##[...]
        XCTAssertEqual(JSONText.rawMember("a", of: text), "1")
        XCTAssertEqual(JSONText.rawMember("b", of: text), ##"{"x":[1,{"y":"}"}]}"##)
        XCTAssertEqual(JSONText.rawMember("c", of: text), ##""q\"uote""##)
        XCTAssertEqual(JSONText.rawMember("d", of: text), "true")
        XCTAssertEqual(JSONText.rawMember("e", of: text), "-2.5e3")
        XCTAssertNil(JSONText.rawMember("f", of: text))
    }

    // MARK: - Helpers

    private func decode(_ line: String) -> ClaudeFrame {
        StreamJSONCodec.decode(line: line)
    }

    /// Equal as JSON, whatever the key order and whitespace.
    private func assertSameJSON(_ encoded: String, _ recorded: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let left = JSONText.parse(encoded), let right = JSONText.parse(recorded) else {
            return XCTFail("not JSON", file: file, line: line)
        }
        XCTAssertEqual(left, right, file: file, line: line)
    }
}
