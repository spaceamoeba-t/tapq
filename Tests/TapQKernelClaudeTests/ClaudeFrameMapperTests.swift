import Foundation
import XCTest
import TapQContracts
import TapQKernel
@testable import TapQKernelClaude

/// The §7.1 rules, frame by frame: which events the kernel sees and which lines go back to
/// Claude Code.
final class ClaudeFrameMapperTests: XCTestCase {
    private let sessionID = "2ef4a829-1045-4f5b-b7fe-38e4270d704e"
    private let bashID = "602de92a-6878-4ce9-b730-d509f891207d"

    // MARK: - system/init

    func testTheFirstSystemInitMustReportThePersistedSession() {
        let sink = RecordingSink()
        XCTAssertEqual(ClaudeFrameMapper(sessionID: sessionID, version: "2.1.260", diagnostics: sink.emitter)
            .map(decode(Fixtures.systemInit)), .init())
        XCTAssertEqual(sink.events, [TapQDiagnosticEvent(
            category: "delegate.claude", name: "claude.init", level: .info,
            fields: ["apiKeySource": "none", "permissionMode": "acceptEdits"])],
            "what the process bills and the mode it runs in, once")

        guard case .violation(let session)? = ClaudeFrameMapper(sessionID: "another")
            .map(decode(Fixtures.systemInit)).events.first else { return XCTFail("expected a violation") }
        XCTAssertTrue(session.contains("not the persisted another"), session)
    }

    /// `--auto-mode`: the classifier's denial is told; a rule's is the user's own setting.
    func testAnAutoModeDenialIsToldAndARuleDenialIsNot() {
        let mapper = ClaudeFrameMapper(sessionID: sessionID)
        XCTAssertEqual(mapper.map(.permissionDenied(tool: "Bash", reasonType: "classifier")),
                       .init(events: [.notice("Claude Code's auto mode blocked it from running a command.")]))
        XCTAssertEqual(mapper.map(.permissionDenied(tool: "WebFetch", reasonType: "classifier")),
                       .init(events: [.notice("Claude Code's auto mode blocked it from fetching a web page.")]))
        XCTAssertEqual(mapper.map(.permissionDenied(tool: "mcp__x__y", reasonType: "classifier")),
                       .init(events: [.notice("Claude Code's auto mode blocked it from using mcp__x__y.")]))
        XCTAssertEqual(mapper.map(.permissionDenied(tool: "Bash", reasonType: "rule")), .init())
        XCTAssertEqual(mapper.map(.permissionDenied(tool: "Bash", reasonType: nil)), .init())
    }

    /// V2 P1-3: an auto-update inside the supported range is logged, and the session goes on.
    func testAnInRangeVersionOtherThanTheCheckedOneIsLoggedAndAccepted() {
        let sink = RecordingSink()
        XCTAssertEqual(ClaudeFrameMapper(sessionID: sessionID, version: "2.1.283", diagnostics: sink.emitter)
            .map(systemInit(version: "2.1.285")), .init())
        XCTAssertEqual(sink.events.last, TapQDiagnosticEvent(
            category: "delegate.claude", name: "claude.version_changed", level: .warning,
            fields: ["from": "2.1.283", "to": "2.1.285"]))
    }

    func testAnOutOfRangeVersionIsAViolationUnlessOverridden() {
        XCTAssertEqual(ClaudeFrameMapper(sessionID: sessionID, version: "2.1.283").map(systemInit(version: "2.2.0")),
                       .init(events: [.violation("Claude Code 2.2.0 is not supported. TapQ supports 2.1.260 through 2.1.293.")]))
        XCTAssertEqual(ClaudeFrameMapper(sessionID: sessionID, version: "2.2.0", allowsUnsupportedVersion: true)
            .map(systemInit(version: "2.2.0")), .init())
        XCTAssertEqual(ClaudeFrameMapper(sessionID: sessionID, version: "2.1.283", allowsUnsupportedVersion: true)
            .map(systemInit(version: "3.0.0")), .init())
    }

    /// K0: one `system/init` per turn that starts. Only the first says anything.
    func testALaterSystemInitIsATurnBoundary() {
        let mapper = ClaudeFrameMapper(sessionID: sessionID)
        _ = mapper.map(decode(Fixtures.systemInit))
        XCTAssertEqual(mapper.map(.systemInit(sessionID: "c-2", version: "9.9.9")), .init())
    }

    // MARK: - assistant

    func testEachToolUseIsOneProgressLineWithItsArgumentInFull() {
        let mapper = ClaudeFrameMapper(sessionID: sessionID)
        XCTAssertEqual(mapper.map(decode(Fixtures.assistantBashToolUse)).events,
                       [.progress("Bash: Fetch first 10 bytes of example.com", step: "toolu_01Xe5LzGqcRi1F2TWio67LD7")],
                       "a command is the words Claude Code shows for it, never the command (2026-10-15)")
        let long = "swift test --filter 'TapQKernelClaudeTests.ClaudeFrameMapperTests' --parallel --num-workers 4 2>&1 | tee /tmp/claude-tests.txt"
        XCTAssertEqual(mapper.map(decode(ProtocolFrames.assistantMixedBlocks)).events,
                       [.said("Running it."), .progress("Bash: \(long)", step: "toolu_long")])
        let hello = "/private/tmp/claude-501/-Users-dev-tapq-open/1b22a3f9-cbab-4781-819c-69f9c6bb13f4/scratchpad/k0-workspace/hello.py"
        XCTAssertEqual(mapper.map(decode(Fixtures.assistantReadToolUse)).events,
                       [.progress("Read: \(hello)", step: "toolu_011YyzfT3ZxKVooUS6cKPEih")])
        XCTAssertEqual(mapper.map(decode(Fixtures.assistantEditToolUse)).events,
                       [.progress("Edit: \(hello)", step: "toolu_01TWGC6DAhhNynNBjvruXcPf")])
        XCTAssertEqual(mapper.map(decode(Fixtures.assistantText)).events, [.said("READY")],
                       "its words along the way, for status (2026-10-15)")
        XCTAssertEqual(mapper.map(decode(Fixtures.assistantThinking)).events, [])
    }

    func testTheProgressArgumentFallsBackToDescriptionThenTheFirstStringField() {
        XCTAssertEqual(ClaudeFrameMapper.progressLine(ClaudeToolUse(
            name: "Edit", inputJSON: ##"{"file_path":"/w/a.swift","old_string":"x"}"##)), "Edit: /w/a.swift")
        XCTAssertEqual(ClaudeFrameMapper.progressLine(ClaudeToolUse(
            name: "Custom", inputJSON: ##"{"zeta":"z","description":"does a\nthing"}"##)), "Custom: does a thing")
        XCTAssertEqual(ClaudeFrameMapper.progressLine(ClaudeToolUse(
            name: "Custom", inputJSON: ##"{"zeta":"z","alpha":"a"}"##)), "Custom: a")
        XCTAssertEqual(ClaudeFrameMapper.progressLine(ClaudeToolUse(name: "TodoWrite", inputJSON: "{}")),
                       "TodoWrite")
    }

    func testABashCallIsItsDescriptionAndItsCommandOnlyWithoutOne() {
        XCTAssertEqual(ClaudeFrameMapper.progressLine(ClaudeToolUse(
            name: "Bash", inputJSON: ##"{"command":"swift test 2>&1 | tail","description":"Run the\nunit tests"}"##)),
            "Bash: Run the unit tests")
        XCTAssertEqual(ClaudeFrameMapper.progressLine(ClaudeToolUse(
            name: "Bash", inputJSON: ##"{"command":"swift test","description":" "}"##)), "Bash: swift test")
        XCTAssertEqual(ClaudeFrameMapper.progressLine(ClaudeToolUse(
            name: "Bash", inputJSON: ##"{"command":"swift test"}"##)), "Bash: swift test")
    }

    // MARK: - result

    func testASuccessfulResultFinishesWithItsText() {
        XCTAssertEqual(map(Fixtures.resultSuccess), [.finished(text: "READY")])
        XCTAssertEqual(map(Fixtures.resultWithPermissionDenial).count, 1)
    }

    /// 02-2: every abort is the interrupt TapQ sent, whether a tool or the model was running.
    func testEveryAbortedResultIsStopped() {
        XCTAssertEqual(map(Fixtures.resultAbortedTools), [.stopped])
        XCTAssertEqual(map(ProtocolFrames.resultAbortedStreaming), [.stopped])
    }

    /// 02-5, D6: the first reason Claude Code gave, in plan order.
    func testAnyOtherErrorResultFailsWithItsReason() {
        XCTAssertEqual(map(ProtocolFrames.resultAPIError), [.failed(reason: "API Error: 529 Overloaded")])
        XCTAssertEqual(map(ProtocolFrames.resultMaxTurns),
                       [.failed(reason: "Reached maximum number of turns (3); stopping")])
        XCTAssertEqual(map(ProtocolFrames.resultModelErrorBare),
                       [.failed(reason: "error_during_execution (model_error)")])
    }

    /// The CLI's `[ede_diagnostic]` entries are never spoken: the other errors are, and with
    /// none left the reason is the subtype and terminal reason.
    func testDiagnosticErrorEntriesAreNotTheReason() {
        let frame = { (errors: String) in
            ##"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"model_error","errors":"## + errors + ##","session_id":"2ef4a829-1045-4f5b-b7fe-38e4270d704e"}"##
        }
        XCTAssertEqual(map(frame(##"["[ede_diagnostic] stack at turn.ts:41","Prompt is too long"]"##)),
                       [.failed(reason: "Prompt is too long")])
        XCTAssertEqual(map(frame(##"["[ede_diagnostic] stack at turn.ts:41"]"##)),
                       [.failed(reason: "error_during_execution (model_error)")])
    }

    // MARK: - can_use_tool

    func testAPermissionCarriesTheFullInputAndTheConsentFields() {
        let events = map(Fixtures.canUseToolBash)
        guard case .permission(let request)? = events.first, events.count == 1 else {
            return XCTFail("expected one permission, got \(events)")
        }
        XCTAssertEqual(request.id, bashID)
        XCTAssertEqual(request.tool, "Bash")
        XCTAssertEqual(request.command, "curl -s https://example.com | head -c 10")
        XCTAssertEqual(request.paths, [])
        XCTAssertEqual(request.title, "Fetch first 10 bytes of example.com")
        XCTAssertEqual(request.alwaysAllow, AlwaysAllowOffer(
            description: "allow Bash(curl -s https://example.com) for this session",
            payloadJSON: ##"[{"behavior":"allow","destination":"session","rules":[{"ruleContent":"curl -s https://example.com","toolName":"Bash"}],"type":"addRules"}]"##))
    }

    func testABoilerplateReasonIsNotPassedOn() {
        let frame = ProtocolFrames.canUseToolGmailSend.replacingOccurrences(
            of: #""decision_reason":"\u001b[1mSends mail\u001b[0m on your behalf""#,
            with: #""decision_reason":"This command requires approval""#)
        XCTAssertNotEqual(frame, ProtocolFrames.canUseToolGmailSend)
        guard case .permission(let request)? = map(frame).first else {
            return XCTFail("expected a permission")
        }
        XCTAssertNil(request.reason)
    }

    func testAnEditNamesItsPathAndOffersNothingWithoutSuggestions() {
        guard case .permission(let request)? = map(ProtocolFrames.canUseToolEdit).first else {
            return XCTFail("expected a permission")
        }
        XCTAssertEqual(request.paths, ["/w/README.md"])
        XCTAssertNil(request.command)
        XCTAssertNil(request.alwaysAllow)
    }

    func testSuppressAlwaysAllowRuleWithdrawsTheOffer() {
        guard case .permission(let request)? = map(ProtocolFrames.canUseToolGmailSend).first else {
            return XCTFail("expected a permission")
        }
        XCTAssertNil(request.alwaysAllow)
        XCTAssertEqual(request.reason, "Sends mail on your behalf")
        XCTAssertEqual(request.inputJSON, ##"{"to":"bob@example.com","subject":"Notes","body":"See attached."}"##)
    }

    func testAMultiQuestionRequestCarriesEveryQuestionAndOption() {
        XCTAssertEqual(map(ProtocolFrames.canUseToolTwoQuestions), [.question(QuestionRequest(
            id: "req-questions",
            questions: [
                Question(key: "Which database?", header: "Database", text: "Which database?",
                         options: [QuestionOption(label: "Postgres", description: "Server"),
                                   QuestionOption(label: "SQLite", description: "File")],
                         multiSelect: false, allowsFreeText: true),
                Question(key: "Which checks should run?", header: "Checks", text: "Which checks should run?",
                         options: [QuestionOption(label: "lint"), QuestionOption(label: "test"),
                                   QuestionOption(label: "build")],
                         multiSelect: true, allowsFreeText: true),
            ]))])
    }

    func testTwoOutstandingRequestsAreTwoPermissions() {
        let mapper = ClaudeFrameMapper(sessionID: sessionID)
        let first = mapper.map(decode(Fixtures.canUseToolBash)).events
        let second = mapper.map(decode(ProtocolFrames.canUseToolWebFetch)).events
        guard case .permission(let a)? = first.first, case .permission(let b)? = second.first else {
            return XCTFail("expected two permissions")
        }
        XCTAssertEqual([a.id, b.id], [bashID, "req-webfetch"])
        XCTAssertNotNil(try mapper.reply(toPermission: "req-webfetch", .allow(always: false)))
        XCTAssertNotNil(try mapper.reply(toPermission: bashID, .deny(feedback: nil)))
    }

    /// §3.1: withdrawn for every open request, in arrival order, before the terminal event.
    func testAResultWithdrawsEveryOpenRequestBeforeTheTerminalEvent() throws {
        let mapper = ClaudeFrameMapper(sessionID: sessionID)
        _ = mapper.map(decode(Fixtures.canUseToolBash))
        _ = mapper.map(decode(ProtocolFrames.canUseToolWebFetch))
        _ = mapper.map(decode(ProtocolFrames.canUseToolEdit))
        _ = try mapper.reply(toPermission: "req-webfetch", .allow(always: false))
        XCTAssertEqual(mapper.map(decode(Fixtures.resultAbortedTools)).events,
                       [.withdrawn(requestID: bashID), .withdrawn(requestID: "req-edit"), .stopped])
        XCTAssertNil(try mapper.reply(toPermission: bashID, .allow(always: false)))
    }

    // MARK: - Cancel

    /// 02-1: both halves clear, and a reply the kernel decided on meanwhile is dropped.
    func testACancelWithdrawsTheRequestAndALateReplyIsDropped() throws {
        let mapper = ClaudeFrameMapper(sessionID: sessionID)
        _ = mapper.map(decode(Fixtures.canUseToolBash))
        XCTAssertEqual(mapper.map(decode(ProtocolFrames.cancelBashRequest)),
                       .init(events: [.withdrawn(requestID: bashID)]))
        XCTAssertNil(try mapper.reply(toPermission: bashID, .allow(always: false)))
        XCTAssertEqual(mapper.map(decode(Fixtures.resultSuccess)).events, [.finished(text: "READY")])
    }

    func testACancelForARequestThatIsNotOpenSaysNothing() {
        XCTAssertEqual(ClaudeFrameMapper(sessionID: sessionID).map(decode(ProtocolFrames.cancelBashRequest)),
                       .init())
    }

    // MARK: - Other control requests and frames

    func testAnUnknownControlSubtypeGetsTheProtocolsErrorReply() {
        XCTAssertEqual(ClaudeFrameMapper(sessionID: sessionID).map(decode(ProtocolFrames.hookCallback)),
                       .init(replies: [##"{"type":"control_response","response":{"subtype":"error","request_id":"req-hook","error":"TapQ does not handle hook_callback"}}"##]))
    }

    /// Declined, and the user is told which server asked (§7.1).
    func testAnElicitationIsDeclinedOutLoud() {
        XCTAssertEqual(ClaudeFrameMapper(sessionID: sessionID).map(decode(ProtocolFrames.elicitation)),
                       .init(events: [.notice("Claude Code's github server asked for input; I declined.")],
                             replies: [##"{"type":"control_response","response":{"subtype":"success","request_id":"req-elicit","response":{"action":"decline"}}}"##]))
    }

    // MARK: - user: tool results

    /// A tool call ends with its `tool_result`, as Claude Code's screen turns its spinner into
    /// the result (2026-10-15): done, failed (`is_error`), or declined, never run: Claude Code
    /// marks a rejection in `tool_result_meta`, and a TapQ deny is an error that only says no.
    func testEachToolResultEndsItsStep() {
        let mapper = ClaudeFrameMapper(sessionID: sessionID)
        XCTAssertEqual(mapper.map(decode(Fixtures.userToolResultSuccess)).events,
                       [.stepEnded(step: "toolu_01Xe5LzGqcRi1F2TWio67LD7", .done)])
        XCTAssertEqual(mapper.map(decode(ProtocolFrames.userToolResultExitCode)).events,
                       [.stepEnded(step: "toolu_failed", .failed)])
        XCTAssertEqual(mapper.map(decode(Fixtures.userToolResultError)).events,
                       [.stepEnded(step: "toolu_01WLWb644HoqPzcVbNVqK7yT", .declined)],
                       "an interrupt's rejection never ran")
        XCTAssertEqual(mapper.map(decode(ProtocolFrames.userToolResultSubagent)).events,
                       [.stepEnded(step: "toolu_sub", .done)], "a subagent's steps end too")
        XCTAssertEqual(mapper.map(decode(ProtocolFrames.userToolResultsTwo)).events,
                       [.stepEnded(step: "toolu_a", .done), .stepEnded(step: "toolu_b", .failed)])
    }

    /// A command Claude Code moved to the background (`run_in_background`, or past its
    /// timeout) has its `tool_result` at once and runs on: its step ends with its task's
    /// `task_notification`. One that ran in the foreground had its notification first (05-midturn).
    func testABackgroundedCommandEndsWithItsTask() {
        let mapper = ClaudeFrameMapper(sessionID: sessionID)
        XCTAssertEqual(mapper.map(decode(Fixtures.systemTaskStarted)).events, [])
        XCTAssertEqual(mapper.map(decode(ProtocolFrames.taskNotification)).events, [])
        XCTAssertEqual(mapper.map(decode(ProtocolFrames.toolResult("toolu_015F377fkrWdRbGbUoczbpN8"))).events,
                       [.stepEnded(step: "toolu_015F377fkrWdRbGbUoczbpN8", .done)], "a foreground task")

        for (status, outcome) in [("completed", StepOutcome.done), ("failed", .failed), ("stopped", .stopped)] {
            let id = "toolu_bg_\(status)"
            XCTAssertEqual(mapper.map(decode(ProtocolFrames.taskStarted(id))).events, [])
            XCTAssertEqual(mapper.map(decode(ProtocolFrames.toolResult(id))).events, [], "it still runs")
            XCTAssertEqual(mapper.map(decode(ProtocolFrames.taskEnded(id, status))).events,
                           [.stepEnded(step: id, outcome)])
            XCTAssertEqual(mapper.map(decode(ProtocolFrames.taskEnded(id, status))).events, [], "once")
        }
    }

    /// Its step waits on the user, by the `tool_use_id` the request names.
    func testAPermissionRequestNamesItsStep() {
        let events = ClaudeFrameMapper(sessionID: sessionID).map(decode(Fixtures.canUseToolBash)).events
        guard case .permission(let request)? = events.first else { return XCTFail("expected a permission") }
        XCTAssertEqual(request.step, "toolu_01Xe5LzGqcRi1F2TWio67LD7")
    }

    func testAToolCallTheUserDeniedWasDeclined() throws {
        let mapper = mapperWith(Fixtures.canUseToolDeniedBash)
        XCTAssertNotNil(try mapper.reply(toPermission: "a424c5b0-ad19-4214-9502-a66f8d21a8d1", .deny(feedback: nil)))
        XCTAssertEqual(mapper.map(decode(ProtocolFrames.userToolResultDenied)).events,
                       [.stepEnded(step: "toolu_01Cco4HJbHQP1Pde5MhjgmZU", .declined)])
        XCTAssertEqual(mapper.map(decode(ProtocolFrames.userToolResultExitCode)).events,
                       [.stepEnded(step: "toolu_failed", .failed)], "only the denied one")
    }

    func testFramesThatNeedNothingFromTheLoopSayNothing() {
        let mapper = ClaudeFrameMapper(sessionID: sessionID)
        for line in [ProtocolFrames.requestUserDialog, ProtocolFrames.keepAlive, ProtocolFrames.chatter,
                     ProtocolFrames.controlResponseError, Fixtures.controlResponseInterruptAck,
                     Fixtures.toolProgressHeartbeat, Fixtures.userInterruptedText,
                     ProtocolFrames.authStatus] {
            XCTAssertEqual(mapper.map(decode(line)), .init(), line)
        }
    }

    func testAViolationPassesStraightThrough() {
        XCTAssertEqual(map(##"{"type":"result"}"##).count, 1)
        guard case .violation? = map(##"{"type":"result"}"##).first else { return XCTFail("expected a violation") }
    }

    // MARK: - Replies

    func testAllowEchoesTheInputVerbatim() throws {
        let mapper = mapperWith(ProtocolFrames.canUseToolGmailSend)
        XCTAssertEqual(try mapper.reply(toPermission: "req-gmail", .allow(always: false)),
                       ##"{"type":"control_response","response":{"subtype":"success","request_id":"req-gmail","response":{"behavior":"allow","updatedInput":{"to":"bob@example.com","subject":"Notes","body":"See attached."}}}}"##)
    }

    /// "Don't ask again" lasts for this Claude process only: destination session, never a
    /// settings file.
    func testAllowAlwaysAddsTheSuggestionsScopedToTheSession() throws {
        let mapper = mapperWith(Fixtures.canUseToolBash)
        XCTAssertEqual(try mapper.reply(toPermission: bashID, .allow(always: true)),
                       ##"{"type":"control_response","response":{"subtype":"success","request_id":"602de92a-6878-4ce9-b730-d509f891207d","response":{"behavior":"allow","updatedInput":{"command":"curl -s https://example.com | head -c 10","description":"Fetch first 10 bytes of example.com"},"updatedPermissions":[{"behavior":"allow","destination":"session","rules":[{"ruleContent":"curl -s https://example.com","toolName":"Bash"}],"type":"addRules"}]}}}"##)
    }

    func testAllowAlwaysOnARequestThatOffersNothingIsAPlainAllow() throws {
        let mapper = mapperWith(ProtocolFrames.canUseToolGmailSend)
        let reply = try XCTUnwrap(try mapper.reply(toPermission: "req-gmail", .allow(always: true)))
        XCTAssertFalse(reply.contains("updatedPermissions"), reply)
    }

    func testDenyCarriesTheFeedbackOrTheDefaultSentence() throws {
        XCTAssertEqual(try mapperWith(Fixtures.canUseToolBash).reply(toPermission: bashID, .deny(feedback: "use pnpm")),
                       ##"{"type":"control_response","response":{"subtype":"success","request_id":"602de92a-6878-4ce9-b730-d509f891207d","response":{"behavior":"deny","message":"use pnpm"}}}"##)
        let plain = try XCTUnwrap(try mapperWith(Fixtures.canUseToolBash).reply(toPermission: bashID, .deny(feedback: nil)))
        XCTAssertEqual(JSONText.parse(plain)?["response"]?["response"]?["message"]?.stringValue, "The user said no.")
    }

    /// The single-label answer K0 confirmed live.
    func testASingleAnswerMatchesTheLineThatAnsweredTheK0Question() throws {
        let reply = try XCTUnwrap(try mapperWith(Fixtures.canUseToolAskUserQuestion)
            .reply(toQuestion: "e0700bb3-7e38-4af5-b9bd-a5ea42168bcb", answers: [["Howdy"]]))
        XCTAssertEqual(JSONText.parse(reply), JSONText.parse(Fixtures.sentQuestionAnswer))
    }

    /// The questions travel back verbatim; a multi-select answer is its labels joined with
    /// ", " (AskUserQuestionOutput documents the join; unverified live).
    func testAMultiQuestionAnswerKeysEachQuestionByItsTextInOrder() throws {
        let reply = try mapperWith(ProtocolFrames.canUseToolTwoQuestions)
            .reply(toQuestion: "req-questions", answers: [["SQLite"], ["lint", "build"]])
        let request = try XCTUnwrap(JSONText.rawMember("request", of: ProtocolFrames.canUseToolTwoQuestions[...]))
        let input = try XCTUnwrap(JSONText.rawMember("input", of: request))
        let questions = try XCTUnwrap(JSONText.rawMember("questions", of: input))
        XCTAssertEqual(reply, ##"{"type":"control_response","response":{"subtype":"success","request_id":"req-questions","response":{"behavior":"allow","updatedInput":{"questions":"## + questions + ##","answers":{"Which database?":"SQLite","Which checks should run?":"lint, build"}}}}}"##)
    }

    func testRepliesRefuseRequestsTheMapperCannotAnswer() {
        let mapper = mapperWith(Fixtures.canUseToolBash, ProtocolFrames.canUseToolTwoQuestions)
        XCTAssertThrowsError(try mapper.reply(toPermission: "nope", .allow(always: false))) { error in
            XCTAssertEqual(error as? ClaudeDelegateError, .unknownRequest("nope"))
        }
        XCTAssertThrowsError(try mapper.reply(toQuestion: bashID, answers: [["x"]])) { error in
            XCTAssertEqual(error as? ClaudeDelegateError, .notAQuestion(bashID))
        }
        XCTAssertThrowsError(try mapper.reply(toQuestion: "req-questions", answers: [["SQLite"]])) { error in
            XCTAssertEqual(error as? ClaudeDelegateError, .answerCount("req-questions", expected: 2, got: 1))
        }
        XCTAssertNotNil(try mapper.reply(toPermission: bashID, .allow(always: false)))
        XCTAssertThrowsError(try mapper.reply(toPermission: bashID, .allow(always: false)))
    }

    /// Only the last 64 withdrawals are remembered (V2 P2-9).
    func testTheWithdrawnMemoryIsBounded() throws {
        let mapper = ClaudeFrameMapper(sessionID: sessionID)
        for index in 0...64 {
            _ = mapper.map(.canUseTool(ClaudeToolRequest(requestID: "r\(index)", toolName: "Bash", inputJSON: "{}")))
        }
        _ = mapper.map(decode(Fixtures.resultSuccess))
        XCTAssertNil(try mapper.reply(toPermission: "r1", .allow(always: false)))
        XCTAssertThrowsError(try mapper.reply(toPermission: "r0", .allow(always: false))) { error in
            XCTAssertEqual(error as? ClaudeDelegateError, .unknownRequest("r0"))
        }
    }

    // MARK: - Helpers

    private func decode(_ line: String) -> ClaudeFrame {
        StreamJSONCodec.decode(line: line)
    }

    private func systemInit(version: String) -> ClaudeFrame {
        .systemInit(sessionID: sessionID, version: version)
    }

    private func map(_ line: String) -> [DelegateEvent] {
        ClaudeFrameMapper(sessionID: sessionID).map(decode(line)).events
    }

    private func mapperWith(_ lines: String...) -> ClaudeFrameMapper {
        let mapper = ClaudeFrameMapper(sessionID: sessionID)
        for line in lines { _ = mapper.map(decode(line)) }
        return mapper
    }
}

/// Every diagnostic recorded through `emitter`, in order.
private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TapQDiagnosticEvent] = []

    var emitter: TapQDiagnosticEmitter { TapQDiagnosticEmitter(category: "delegate.claude", sink: self) }
    var events: [TapQDiagnosticEvent] { lock.lock(); defer { lock.unlock() }; return recorded }

    func record(_ event: TapQDiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(event)
    }
}
