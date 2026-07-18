import XCTest
@testable import TapQClaudeAdapter
import TapQWireProtocol
import TapQContracts

/// Behavioural contract for the compiled `wavo-hook` shim. The broker round-trip is
/// injected so every fail-open branch is exercised without a real socket.
final class HookShimTests: XCTestCase {
    private enum StubError: Error { case unreachable }

    private func stdin(_ json: String) -> Data { Data(json.utf8) }

    /// Decode the PreToolUse stdout into (permissionDecision, permissionDecisionReason).
    private func parseOutput(_ stdout: String?) throws -> (decision: String, reason: String) {
        let data = Data((stdout ?? "").utf8)
        let obj = try JSONDecoder().decode([String: JSONValue].self, from: data)
        let inner = obj["hookSpecificOutput"]?.objectValue
        return (inner?["permissionDecision"]?.stringValue ?? "",
                inner?["permissionDecisionReason"]?.stringValue ?? "")
    }

    /// Decode PermissionRequest stdout into its event-specific decision object.
    private func parsePermissionRequestOutput(
        _ stdout: String?
    ) throws -> (event: String, behavior: String, message: String?) {
        let data = Data((stdout ?? "").utf8)
        let obj = try JSONDecoder().decode([String: JSONValue].self, from: data)
        let inner = obj["hookSpecificOutput"]?.objectValue
        let decision = inner?["decision"]?.objectValue
        return (
            inner?["hookEventName"]?.stringValue ?? "",
            decision?["behavior"]?.stringValue ?? "",
            decision?["message"]?.stringValue
        )
    }

    // MARK: - PreToolUse decision mapping

    func testPreToolUseAllow() throws {
        let input = stdin(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"npm test"},"request_id":"r1"}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in Data(#"{"decision":"allow"}"#.utf8) }
        XCTAssertEqual(result.exitCode, 0)
        let out = try parseOutput(result.stdout)
        XCTAssertEqual(out.decision, "allow")
        XCTAssertEqual(out.reason, "Approved via TapQ")
    }

    func testPreToolUseDenyWithBrokerReason() throws {
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in Data(#"{"decision":"deny","reason":"too risky"}"#.utf8) }
        let out = try parseOutput(result.stdout)
        XCTAssertEqual(out.decision, "deny")
        XCTAssertEqual(out.reason, "too risky")
    }

    func testPreToolUseDenyFallsBackToDefaultReason() throws {
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in Data(#"{"decision":"deny"}"#.utf8) }
        let out = try parseOutput(result.stdout)
        XCTAssertEqual(out.decision, "deny")
        XCTAssertEqual(out.reason, "Denied via TapQ")
    }

    func testPreToolUseAskWhenBrokerReturnsAsk() throws {
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in Data(#"{"decision":"ask"}"#.utf8) }
        let out = try parseOutput(result.stdout)
        XCTAssertEqual(out.decision, "ask")
        XCTAssertEqual(out.reason, "No hands-free response; deferring to prompt")
    }

    func testPreToolUseAsksWhenBrokerAcksWithoutDecision() throws {
        // Broker reached but no allow/deny (e.g. it timed out and acked) → show the prompt.
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in Data(#"{"ok":true}"#.utf8) }
        let out = try parseOutput(result.stdout)
        XCTAssertEqual(out.decision, "ask")
    }

    func testPreToolUseAsksWhenBrokerRejectsMissingApprovalSource() throws {
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in
            Data(#"{"error":"approval_source"}"#.utf8)
        }
        let out = try parseOutput(result.stdout)
        XCTAssertEqual(out.decision, "ask")
        XCTAssertEqual(out.reason, "No hands-free response; deferring to prompt")
    }

    // MARK: - PreToolUse fail-open (pass through, never block auto mode)

    func testPreToolUsePassesThroughWhenBrokerUnreachable() {
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in throw StubError.unreachable }
        XCTAssertNil(result.stdout, "unreachable broker must emit no decision so Claude uses its own flow")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPreToolUsePassesThroughOnGarbageReply() {
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in Data("not json".utf8) }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Request the broker receives

    func testPreToolUseSendsWellFormedApprovalRequest() throws {
        let input = stdin(#"{"hook_event_name":"PreToolUse","session_id":"s9","tool_name":"Edit","tool_input":{"file_path":"a.txt"},"request_id":"rid","permission_mode":"default","cwd":"/tmp"}"#)
        var captured: [String: JSONValue]?
        var capturedTimeout: TimeInterval?
        _ = HookShim.handle(stdinData: input) { message, timeout in
            captured = message
            capturedTimeout = timeout
            return Data(#"{"decision":"allow"}"#.utf8)
        }
        XCTAssertEqual(captured?["type"]?.stringValue, "approval.request")
        XCTAssertEqual(captured?["session_id"]?.stringValue, "s9")
        XCTAssertEqual(captured?["tool_name"]?.stringValue, "Edit")
        XCTAssertEqual(captured?["tool_input"]?["file_path"]?.stringValue, "a.txt")
        XCTAssertEqual(captured?["request_id"]?.stringValue, "rid")
        XCTAssertEqual(captured?["approval_source"]?.stringValue, "pre_tool_use")
        XCTAssertEqual(captured?["agent"]?["id"]?.stringValue, "claude-code")
        XCTAssertEqual(captured?["agent"]?["display_name"]?.stringValue, "Claude Code")
        XCTAssertEqual(captured?["summary"]?.stringValue, "edit the file a.txt")
        XCTAssertFalse(captured?["detail"]?.stringValue?.isEmpty ?? true)
        XCTAssertEqual(capturedTimeout, HookShim.approvalTimeout)
    }

    func testApprovalMessageDecodesAsBrokerRequestOnceTokenIsAdded() throws {
        let input = stdin(#"{"hook_event_name":"PreToolUse","session_id":"s9","tool_name":"Bash","tool_input":{"command":"ls"},"request_id":"rid"}"#)
        var captured: [String: JSONValue]?
        _ = HookShim.handle(stdinData: input) { message, _ in
            captured = message
            return Data(#"{"decision":"allow"}"#.utf8)
        }
        var withToken = try XCTUnwrap(captured)
        withToken["token"] = .string("tok")
        let request = try BrokerRequest(from: JSONEncoder().encode(withToken))
        guard case .approval(let msg) = request else { return XCTFail("expected approval") }
        XCTAssertEqual(msg.token, "tok")
        XCTAssertEqual(msg.toolName, "Bash")
        XCTAssertEqual(msg.approvalSource, .preToolUse)
        XCTAssertEqual(msg.agent, .claudeCode)
        XCTAssertEqual(msg.summary, "run ls")
        XCTAssertEqual(msg.toolInput["command"]?.stringValue, "ls")
    }

    func testPreToolUseMintsRequestIDWhenMissing() throws {
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#)
        var captured: [String: JSONValue]?
        _ = HookShim.handle(stdinData: input) { message, _ in
            captured = message
            return Data(#"{"decision":"allow"}"#.utf8)
        }
        let rid = captured?["request_id"]?.stringValue
        XCTAssertNotNil(rid)
        XCTAssertFalse(rid?.isEmpty ?? true)
    }

    // MARK: - PermissionRequest decision mapping

    func testPermissionRequestAllowUsesExactClaudeOutputShape() throws {
        let input = stdin(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"npm test"}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in
            Data(#"{"decision":"allow"}"#.utf8)
        }

        XCTAssertEqual(result.exitCode, 0)
        let output = try parsePermissionRequestOutput(result.stdout)
        XCTAssertEqual(output.event, "PermissionRequest")
        XCTAssertEqual(output.behavior, "allow")
        XCTAssertNil(output.message, "allow must not emit deny-only fields")

        let object = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(try XCTUnwrap(result.stdout).utf8)
        )
        let inner = try XCTUnwrap(object["hookSpecificOutput"]?.objectValue)
        let decision = try XCTUnwrap(inner["decision"]?.objectValue)
        XCTAssertEqual(Set(inner.keys), ["hookEventName", "decision"])
        XCTAssertEqual(Set(decision.keys), ["behavior"])
    }

    func testPermissionRequestDenyUsesBrokerReason() throws {
        let input = stdin(#"{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in
            Data(#"{"decision":"deny","reason":"production is locked"}"#.utf8)
        }

        let output = try parsePermissionRequestOutput(result.stdout)
        XCTAssertEqual(output.event, "PermissionRequest")
        XCTAssertEqual(output.behavior, "deny")
        XCTAssertEqual(output.message, "production is locked")

        let object = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(try XCTUnwrap(result.stdout).utf8)
        )
        let inner = try XCTUnwrap(object["hookSpecificOutput"]?.objectValue)
        let decision = try XCTUnwrap(inner["decision"]?.objectValue)
        XCTAssertEqual(Set(inner.keys), ["hookEventName", "decision"])
        XCTAssertEqual(Set(decision.keys), ["behavior", "message"])
    }

    func testPermissionRequestDenyFallsBackToDefaultReason() throws {
        let input = stdin(#"{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in
            Data(#"{"decision":"deny"}"#.utf8)
        }

        let output = try parsePermissionRequestOutput(result.stdout)
        XCTAssertEqual(output.behavior, "deny")
        XCTAssertEqual(output.message, "Denied via TapQ")
    }

    func testPermissionRequestSendsNativeApprovalSourceAndMetadata() throws {
        let input = stdin(#"{"hook_event_name":"PermissionRequest","session_id":"s9","tool_name":"Bash","tool_input":{"command":"curl example.com"},"permission_mode":"auto","cwd":"/tmp"}"#)
        var captured: [String: JSONValue]?
        var capturedTimeout: TimeInterval?
        _ = HookShim.handle(stdinData: input) { message, timeout in
            captured = message
            capturedTimeout = timeout
            return Data(#"{"decision":"allow"}"#.utf8)
        }

        XCTAssertEqual(captured?["type"]?.stringValue, "approval.request")
        XCTAssertEqual(captured?["session_id"]?.stringValue, "s9")
        XCTAssertEqual(captured?["tool_name"]?.stringValue, "Bash")
        XCTAssertEqual(captured?["tool_input"]?["command"]?.stringValue, "curl example.com")
        XCTAssertEqual(captured?["permission_mode"]?.stringValue, "auto")
        XCTAssertEqual(captured?["approval_source"]?.stringValue, "permission_request")
        XCTAssertEqual(captured?["cwd"]?.stringValue, "/tmp")
        XCTAssertFalse(captured?["request_id"]?.stringValue?.isEmpty ?? true)
        XCTAssertEqual(captured?["agent"]?["id"]?.stringValue, "claude-code")
        XCTAssertEqual(captured?["protocol_version"]?.intValue, WireProtocol.version)
        XCTAssertEqual(capturedTimeout, HookShim.approvalTimeout)
    }

    func testPermissionRequestPassesThroughWhenBrokerReturnsAsk() {
        let input = stdin(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in
            Data(#"{"decision":"ask"}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPermissionRequestPassesThroughWhenBrokerTimesOut() {
        let input = stdin(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in
            Data(#"{"error":"timeout"}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPermissionRequestPassesThroughWhenBrokerRejectsProtocol() {
        XCTAssertEqual(WireProtocol.version, 3)
        let input = stdin(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in
            Data(#"{"error":"protocol_version"}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPermissionRequestPassesThroughWhenBrokerRejectsMissingApprovalSource() {
        let input = stdin(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in
            Data(#"{"error":"approval_source"}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPermissionRequestPassesThroughWhenBrokerUnreachable() {
        let input = stdin(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in throw StubError.unreachable }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPermissionRequestPassesThroughOnGarbageReply() {
        let input = stdin(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in Data("not json".utf8) }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Notifications (fire-and-forget)

    func testNotificationClassifiesPermissionPrompt() throws {
        let input = stdin(#"{"hook_event_name":"Notification","session_id":"s1","message":"Claude needs your permission to run npm"}"#)
        var captured: [String: JSONValue]?
        let result = HookShim.handle(stdinData: input) { message, _ in
            captured = message
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(captured?["type"]?.stringValue, "notification.event")
        XCTAssertEqual(captured?["event"]?.stringValue, "permission_prompt")
        XCTAssertEqual(captured?["summary"]?.stringValue, "Claude needs your permission to run npm")
    }

    func testNotificationClassifiesIdlePrompt() throws {
        let input = stdin(#"{"hook_event_name":"Notification","message":"Claude is waiting for you"}"#)
        var captured: [String: JSONValue]?
        _ = HookShim.handle(stdinData: input) { message, _ in
            captured = message
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(captured?["event"]?.stringValue, "idle_prompt")
    }

    func testNotificationPassesThroughWhenBrokerUnreachable() {
        let input = stdin(#"{"hook_event_name":"Notification","message":"hi"}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in throw StubError.unreachable }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testStopSendsStopEvent() throws {
        let input = stdin(#"{"hook_event_name":"Stop","session_id":"s1"}"#)
        var captured: [String: JSONValue]?
        let result = HookShim.handle(stdinData: input) { message, timeout in
            captured = message
            XCTAssertEqual(timeout, HookShim.notifyTimeout)
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(captured?["type"]?.stringValue, "notification.event")
        XCTAssertEqual(captured?["event"]?.stringValue, "stop")
    }

    // MARK: - AskUserQuestion broker-forwarded flow

    func testAskUserQuestionForwardsToBrokerAndFormatsDenyWithSelection() throws {
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick a color","options":[{"label":"Red","description":"warm"},{"label":"Blue","description":"cool"}],"multiSelect":false,"header":"Color"}]},"session_id":"s1","request_id":"r1"}"#)
        var captured: [String: JSONValue]?
        let result = HookShim.handle(stdinData: input) { message, _ in
            captured = message
            return Data(#"{"selected_indices":[1],"selected_labels":["Blue"]}"#.utf8)
        }
        XCTAssertEqual(captured?["type"]?.stringValue, "selection.request")
        XCTAssertEqual(captured?["question"]?.stringValue, "Pick a color")
        let out = try parseOutput(result.stdout)
        XCTAssertEqual(out.decision, "deny")
        XCTAssertTrue(out.reason.contains("Blue"))
        XCTAssertTrue(out.reason.contains("Pick a color"))
    }

    func testAskUserQuestionPassesThroughOnBrokerError() {
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q","options":[{"label":"A","description":"a"}],"multiSelect":false,"header":"H"}]}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in throw StubError.unreachable }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testAskUserQuestionPassesThroughOnTimeout() throws {
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q","options":[{"label":"A","description":"a"}],"multiSelect":false,"header":"H"}]}}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in Data(#"{"error":"timeout"}"#.utf8) }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Unknown / malformed input

    func testUnknownEventDoesNothing() {
        let input = stdin(#"{"hook_event_name":"PostToolUse"}"#)
        var called = false
        let result = HookShim.handle(stdinData: input) { _, _ in called = true; return Data() }
        XCTAssertFalse(called, "unknown events must never contact the broker")
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testMalformedStdinDoesNothing() {
        let input = stdin("this is not json")
        var called = false
        let result = HookShim.handle(stdinData: input) { _, _ in called = true; return Data() }
        XCTAssertFalse(called)
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - AskUserQuestion multi-question and multiSelect pass-through

    func testAskUserQuestionMultiQuestionPassesThrough() {
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q1","options":[{"label":"A","description":""}],"multiSelect":false},{"question":"Q2","options":[{"label":"B","description":""}],"multiSelect":false}]}}"#)
        var called = false
        let result = HookShim.handle(stdinData: input) { _, _ in
            called = true
            return Data(#"{"selected_indices":[0],"selected_labels":["A"]}"#.utf8)
        }
        XCTAssertFalse(called, "multi-question calls must not reach the broker")
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testAskUserQuestionMultiSelectPassesThrough() {
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q","options":[{"label":"A","description":""},{"label":"B","description":""}],"multiSelect":true}]}}"#)
        var called = false
        let result = HookShim.handle(stdinData: input) { _, _ in
            called = true
            return Data()
        }
        XCTAssertFalse(called, "multiSelect calls must not reach the broker")
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testAskUserQuestionMissingMultiSelectIsIntercepted() throws {
        // No multiSelect key at all → treated as single-select and handled normally.
        let input = stdin(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q","options":[{"label":"A","description":""}]}]}}"#)
        var captured: [String: JSONValue]?
        let result = HookShim.handle(stdinData: input) { message, _ in
            captured = message
            return Data(#"{"selected_indices":[0],"selected_labels":["A"]}"#.utf8)
        }
        let out = try parseOutput(result.stdout)
        XCTAssertEqual(out.decision, "deny")
        XCTAssertTrue(out.reason.contains("A"))
        XCTAssertEqual(captured?["multi_select"], .bool(false), "missing multiSelect is stamped as a real boolean")
    }

    // MARK: - Protocol version stamping

    func testOutgoingMessagesCarryProtocolVersion() {
        for (name, json) in [
            ("approval", #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#),
            ("notification", #"{"hook_event_name":"Notification","message":"hi"}"#),
            ("selection", #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q","options":[{"label":"A","description":""}],"multiSelect":false}]}}"#),
        ] {
            var captured: [String: JSONValue]?
            _ = HookShim.handle(stdinData: stdin(json)) { message, _ in
                captured = message
                return Data(#"{"ok":true}"#.utf8)
            }
            XCTAssertEqual(captured?["protocol_version"]?.intValue, WireProtocol.version, "\(name) must be stamped")
        }
    }

    // MARK: - Stop interception (prose-question capture)

    /// Writes a one-reply transcript fixture and returns its path.
    private func transcript(_ assistantText: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavo-shimtest-\(UUID().uuidString).jsonl")
        let escaped = assistantText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(escaped)"}]}}"#
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func stopInput(_ transcriptPath: String, mode: String = "default") -> Data {
        stdin(#"{"hook_event_name":"Stop","session_id":"s1","permission_mode":"\#(mode)","transcript_path":"\#(transcriptPath)"}"#)
    }

    func testStopQuestionAnsweredEmitsBlock() throws {
        let path = try transcript("Which approach? 1) A 2) B")
        var sentTypes: [String] = []
        let result = HookShim.handle(stdinData: stopInput(path)) { message, timeout in
            let type = message["type"]?.stringValue ?? ""
            sentTypes.append(type)
            if type == "stop.question" {
                XCTAssertEqual(message["session_id"]?.stringValue, "s1")
                XCTAssertEqual(message["text"]?.stringValue, "Which approach? 1) A 2) B")
                XCTAssertEqual(message["protocol_version"]?.intValue, WireProtocol.version)
                XCTAssertEqual(timeout, HookShim.approvalTimeout)
                return Data(#"{"action":"answer","reply":"They chose A"}"#.utf8)
            }
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(result.exitCode, 0)
        let obj = try JSONDecoder().decode([String: JSONValue].self, from: Data((result.stdout ?? "").utf8))
        XCTAssertEqual(obj["decision"]?.stringValue, "block")
        XCTAssertEqual(obj["reason"]?.stringValue, "They chose A")
        XCTAssertNil(obj["hookSpecificOutput"], "Stop block output is top-level, not wrapped")
        XCTAssertEqual(sentTypes, ["stop.question"], "an answered stop must not also notify")
    }

    func testStopQuestionPassSendsNotification() throws {
        let path = try transcript("Which approach? 1) A 2) B")
        var sentTypes: [String] = []
        let result = HookShim.handle(stdinData: stopInput(path)) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            if message["type"]?.stringValue == "stop.question" {
                return Data(#"{"action":"pass"}"#.utf8)
            }
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(sentTypes, ["stop.question", "notification.event"])
    }

    func testStopWithoutQuestionMarkSkipsBroker() throws {
        let path = try transcript("All tests pass. The branch is ready.")
        var sentTypes: [String] = []
        let result = HookShim.handle(stdinData: stopInput(path)) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(sentTypes, ["notification.event"], "no ? means no stop.question round-trip")
    }

    func testStopInAutoModePassesThrough() throws {
        let path = try transcript("Which approach? 1) A 2) B")
        var sentTypes: [String] = []
        let result = HookShim.handle(stdinData: stopInput(path, mode: "autoAccept")) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(sentTypes, ["notification.event"])
    }

    func testStopWithMissingTranscriptPassesThrough() {
        let input = stdin(#"{"hook_event_name":"Stop","session_id":"s1","transcript_path":"/nonexistent/t.jsonl"}"#)
        var sentTypes: [String] = []
        let result = HookShim.handle(stdinData: input) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(sentTypes, ["notification.event"])
    }

    func testStopQuestionBrokerErrorFailsOpen() throws {
        let path = try transcript("Which? 1) A 2) B")
        var sentTypes: [String] = []
        let result = HookShim.handle(stdinData: stopInput(path)) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            throw StubError.unreachable
        }
        XCTAssertNil(result.stdout, "broker failure must pass through")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(sentTypes, ["stop.question"],
                       "the stop.question send already failed against this broker — the follow-up " +
                       "notification would target the same dead broker and could push the hook past " +
                       "its 120s ceiling (115s socket timeout + 8s notify), so it must be skipped")
    }

    func testStopQuestionBrokerErrorReplyFailsOpen() throws {
        let path = try transcript("Which? 1) A 2) B")
        var sentTypes: [String] = []
        let result = HookShim.handle(stdinData: stopInput(path)) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            if message["type"]?.stringValue == "stop.question" {
                return Data(#"{"error":"protocol_version"}"#.utf8)
            }
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(sentTypes, ["stop.question", "notification.event"])
    }

    func testSubagentStopDoesNothing() {
        let input = stdin(#"{"hook_event_name":"SubagentStop","session_id":"s1","transcript_path":"/tmp/x.jsonl"}"#)
        var sent = 0
        let result = HookShim.handle(stdinData: input) { _, _ in sent += 1; return Data(#"{"ok":true}"#.utf8) }
        XCTAssertNil(result.stdout)
        XCTAssertEqual(sent, 0)
    }

    func testStopQuestionTextIsTailCapped() throws {
        let long = String(repeating: "a", count: 20_000) + " Which? 1) A 2) B"
        let path = try transcript(long)
        var sentText: String?
        _ = HookShim.handle(stdinData: stopInput(path)) { message, _ in
            if message["type"]?.stringValue == "stop.question" {
                sentText = message["text"]?.stringValue
                return Data(#"{"action":"pass"}"#.utf8)
            }
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(sentText?.count, 16_384)
        XCTAssertTrue(sentText?.hasSuffix("Which? 1) A 2) B") ?? false, "the tail, not the head, must survive")
    }

    // MARK: - UserPromptSubmit steering

    func testUserPromptSubmitInjectsNudgeWhenSteeringEnabled() throws {
        let input = stdin(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"do the thing"}"#)
        var sent = 0
        let result = HookShim.handle(stdinData: input, steeringEnabled: { true }) { _, _ in
            sent += 1
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(sent, 0, "steering never touches the socket")
        XCTAssertEqual(result.exitCode, 0)
        let obj = try JSONDecoder().decode([String: JSONValue].self, from: Data((result.stdout ?? "").utf8))
        let inner = obj["hookSpecificOutput"]?.objectValue
        XCTAssertEqual(inner?["hookEventName"]?.stringValue, "UserPromptSubmit")
        XCTAssertEqual(inner?["additionalContext"]?.stringValue, HookShim.steeringNudge)
    }

    func testUserPromptSubmitSilentWhenSteeringDisabled() {
        let input = stdin(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#)
        var sent = 0
        let result = HookShim.handle(stdinData: input, steeringEnabled: { false }) { _, _ in
            sent += 1
            return Data(#"{"ok":true}"#.utf8)
        }
        XCTAssertEqual(result, HookShim.passThrough)
        XCTAssertEqual(sent, 0)
    }

    func testUserPromptSubmitDefaultsToSilent() {
        // Callers that don't pass steeringEnabled (all pre-existing tests) stay silent.
        let input = stdin(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#)
        let result = HookShim.handle(stdinData: input) { _, _ in Data(#"{"ok":true}"#.utf8) }
        XCTAssertEqual(result, HookShim.passThrough)
    }
}
