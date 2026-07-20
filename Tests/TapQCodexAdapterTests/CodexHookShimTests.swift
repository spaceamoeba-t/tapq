import XCTest
@testable import TapQCodexAdapter
import TapQContracts
import TapQWireProtocol

final class CodexHookShimTests: XCTestCase {
    private enum StubError: Error { case unreachable }

    private func input(_ json: String) -> Data { Data(json.utf8) }

    private func permissionObject(
        toolName: String = "Bash",
        toolInput: JSONValue = .object(["command": .string("swift test")])
    ) -> [String: JSONValue] {
        [
            "hook_event_name": .string("PermissionRequest"),
            "session_id": .string("session-1"),
            "turn_id": .string("turn-1"),
            "transcript_path": .null,
            "cwd": .string("/tmp/project"),
            "model": .string("gpt-5.6"),
            "permission_mode": .string("default"),
            "tool_name": .string(toolName),
            "tool_input": toolInput,
        ]
    }

    private func permissionInput(
        toolName: String = "Bash",
        toolInput: JSONValue = .object(["command": .string("swift test")])
    ) -> Data {
        try! JSONEncoder().encode(permissionObject(toolName: toolName, toolInput: toolInput))
    }

    private func stopObject(
        message: JSONValue = .string("Continue?"),
        active: Bool = false
    ) -> [String: JSONValue] {
        [
            "hook_event_name": .string("Stop"),
            "session_id": .string("session-1"),
            "turn_id": .string("turn-1"),
            "transcript_path": .null,
            "cwd": .string("/tmp/project"),
            "model": .string("gpt-5.6"),
            "permission_mode": .string("default"),
            "stop_hook_active": .bool(active),
            "last_assistant_message": message,
        ]
    }

    private func stopInput(
        message: JSONValue = .string("Continue?"),
        active: Bool = false
    ) -> Data {
        try! JSONEncoder().encode(stopObject(message: message, active: active))
    }

    private func permissionOutput(
        _ stdout: String?
    ) throws -> (event: String, behavior: String, message: String?) {
        let data = Data((stdout ?? "").utf8)
        let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
        let inner = object["hookSpecificOutput"]?.objectValue
        let decision = inner?["decision"]?.objectValue
        return (
            inner?["hookEventName"]?.stringValue ?? "",
            decision?["behavior"]?.stringValue ?? "",
            decision?["message"]?.stringValue
        )
    }

    // MARK: - PermissionRequest

    func testPermissionRequestAllowUsesExactCodexShapeAndNormalizedWireMessage() throws {
        let stdin = permissionInput(toolInput: .object([
            "command": .string("swift test"),
            "description": .string("Run the test suite"),
        ]))
        var captured: [String: JSONValue]?
        var capturedTimeout: TimeInterval?

        let result = CodexHookShim.handle(stdinData: stdin) { message, timeout in
            captured = message
            capturedTimeout = timeout
            return Data(#"{"decision":"allow"}"#.utf8)
        }

        XCTAssertEqual(result.exitCode, 0)
        let output = try permissionOutput(result.stdout)
        XCTAssertEqual(output.event, "PermissionRequest")
        XCTAssertEqual(output.behavior, "allow")
        XCTAssertNil(output.message)

        let encodedOutput = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(try XCTUnwrap(result.stdout).utf8)
        )
        let inner = try XCTUnwrap(encodedOutput["hookSpecificOutput"]?.objectValue)
        let decision = try XCTUnwrap(inner["decision"]?.objectValue)
        XCTAssertEqual(Set(inner.keys), ["hookEventName", "decision"])
        XCTAssertEqual(Set(decision.keys), ["behavior"])

        XCTAssertEqual(captured?["type"]?.stringValue, WireType.approval)
        XCTAssertEqual(captured?["agent"]?["id"]?.stringValue, "codex")
        XCTAssertEqual(captured?["agent"]?["display_name"]?.stringValue, "Codex")
        XCTAssertEqual(captured?["session_id"]?.stringValue, "session-1")
        XCTAssertEqual(captured?["cwd"]?.stringValue, "/tmp/project")
        XCTAssertEqual(captured?["tool_name"]?.stringValue, "Bash")
        XCTAssertEqual(captured?["tool_input"]?["command"]?.stringValue, "swift test")
        XCTAssertEqual(captured?["permission_mode"]?.stringValue, "default")
        XCTAssertEqual(
            captured?["approval_source"]?.stringValue,
            ApprovalSource.permissionRequest.rawValue
        )
        XCTAssertEqual(captured?["summary"]?.stringValue, "run swift test")
        XCTAssertEqual(captured?["detail"]?.stringValue, "Run the test suite")
        XCTAssertFalse(captured?["request_id"]?.stringValue?.isEmpty ?? true)
        XCTAssertEqual(captured?["protocol_version"]?.intValue, WireProtocol.version)
        XCTAssertEqual(capturedTimeout, CodexHookShim.approvalTimeout)

        var authenticated = try XCTUnwrap(captured)
        authenticated["token"] = .string("token")
        let request = try BrokerRequest(from: JSONEncoder().encode(authenticated))
        guard case .approval(let approval) = request else {
            return XCTFail("expected approval request")
        }
        XCTAssertEqual(approval.agent, AgentIdentity(id: "codex", displayName: "Codex"))
        XCTAssertEqual(approval.approvalSource, .permissionRequest)
    }

    func testPermissionRequestDenyUsesBrokerReason() throws {
        let stdin = permissionInput(
            toolName: "apply_patch",
            toolInput: .object(["command": .string("*** Begin Patch")])
        )
        let result = CodexHookShim.handle(stdinData: stdin) { _, _ in
            Data(#"{"decision":"deny","reason":"Protected path"}"#.utf8)
        }

        let output = try permissionOutput(result.stdout)
        XCTAssertEqual(output.behavior, "deny")
        XCTAssertEqual(output.message, "Protected path")
    }

    func testPermissionRequestDenyReasonIsJSONEscaped() throws {
        let reason = "Blocked \"release\" path\\name\nUse staging instead."
        let brokerReply = try JSONEncoder().encode([
            "decision": JSONValue.string("deny"),
            "reason": .string(reason),
        ])
        let result = CodexHookShim.handle(stdinData: permissionInput()) { _, _ in
            brokerReply
        }

        XCTAssertEqual(try permissionOutput(result.stdout).message, reason)
    }

    func testPermissionRequestDenyFallsBackToTapQReason() throws {
        let stdin = permissionInput(toolInput: .object(["command": .string("rm file")]))
        let result = CodexHookShim.handle(stdinData: stdin) { _, _ in
            Data(#"{"decision":"deny","reason":"  "}"#.utf8)
        }

        XCTAssertEqual(try permissionOutput(result.stdout).message, "Denied via TapQ")
    }

    func testPermissionRequestDeclinesToDecideForAskAndBrokerErrors() {
        let stdin = permissionInput(toolInput: .object(["command": .string("make")]))
        for reply in [
            #"{"decision":"ask"}"#,
            #"{"error":"timeout"}"#,
            #"{"error":"unauthorized","decision":"allow"}"#,
        ] {
            let result = CodexHookShim.handle(stdinData: stdin) { _, _ in Data(reply.utf8) }
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }
    }

    func testPermissionRequestAcceptsAllCurrentPermissionModesOnly() throws {
        for mode in ["default", "acceptEdits", "plan", "dontAsk", "bypassPermissions"] {
            var object = permissionObject()
            object["permission_mode"] = .string(mode)
            var capturedMode: String?
            let result = CodexHookShim.handle(
                stdinData: try JSONEncoder().encode(object)
            ) { message, _ in
                capturedMode = message["permission_mode"]?.stringValue
                return Data(#"{"decision":"allow"}"#.utf8)
            }

            XCTAssertEqual(try permissionOutput(result.stdout).behavior, "allow")
            XCTAssertEqual(capturedMode, mode)
        }

        var future = permissionObject()
        future["permission_mode"] = .string("futureMode")
        var called = false
        let result = CodexHookShim.handle(
            stdinData: try JSONEncoder().encode(future)
        ) { _, _ in
            called = true
            return Data(#"{"decision":"allow"}"#.utf8)
        }
        XCTAssertFalse(called)
        XCTAssertEqual(result, CodexHookShim.passThrough)
    }

    func testPermissionRequestFailsOpenWhenBrokerUnavailableOrReplyIsMalformed() {
        let stdin = permissionInput(toolInput: .object(["command": .string("make")]))

        let unavailable = CodexHookShim.handle(stdinData: stdin) { _, _ in
            throw StubError.unreachable
        }
        XCTAssertEqual(unavailable, CodexHookShim.passThrough)

        let malformed = CodexHookShim.handle(stdinData: stdin) { _, _ in Data("not json".utf8) }
        XCTAssertEqual(malformed, CodexHookShim.passThrough)
    }

    func testInvalidPermissionRequestDoesNotReachBroker() {
        var invalidObjects: [[String: JSONValue]] = []
        for key in [
            "session_id", "turn_id", "transcript_path", "cwd", "model",
            "permission_mode", "tool_name", "tool_input",
        ] {
            var missing = permissionObject()
            missing.removeValue(forKey: key)
            invalidObjects.append(missing)
        }
        var wrongTranscriptType = permissionObject()
        wrongTranscriptType["transcript_path"] = .bool(false)
        invalidObjects.append(wrongTranscriptType)
        var wrongModelType = permissionObject()
        wrongModelType["model"] = .number(5)
        invalidObjects.append(wrongModelType)
        var emptySession = permissionObject()
        emptySession["session_id"] = .string("  ")
        invalidObjects.append(emptySession)
        var nonObjectInput = permissionObject()
        nonObjectInput["tool_input"] = .string("command")
        invalidObjects.append(nonObjectInput)

        for object in invalidObjects {
            var called = false
            let result = CodexHookShim.handle(
                stdinData: try! JSONEncoder().encode(object)
            ) { _, _ in
                called = true
                return Data(#"{"decision":"allow"}"#.utf8)
            }
            XCTAssertFalse(called)
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }
    }

    // MARK: - Stop

    func testStopAnswerUsesLastAssistantMessageAndEmitsTopLevelContinuation() throws {
        let stdin = stopInput(message: .string("Deploy to staging or production?"))
        var sentTypes: [String] = []
        let result = CodexHookShim.handle(stdinData: stdin) { message, timeout in
            sentTypes.append(message["type"]?.stringValue ?? "")
            XCTAssertEqual(message["agent"]?["id"]?.stringValue, "codex")
            XCTAssertEqual(message["session_id"]?.stringValue, "session-1")
            XCTAssertEqual(message["request_id"]?.stringValue, "turn-1")
            XCTAssertEqual(message["text"]?.stringValue, "Deploy to staging or production?")
            XCTAssertEqual(timeout, CodexHookShim.approvalTimeout)
            return Data(#"{"action":"answer","reply":"The user chose staging."}"#.utf8)
        }

        XCTAssertEqual(result.exitCode, 0)
        let object = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(try XCTUnwrap(result.stdout).utf8)
        )
        XCTAssertEqual(object["decision"]?.stringValue, "block")
        XCTAssertEqual(object["reason"]?.stringValue, "The user chose staging.")
        XCTAssertNil(object["hookSpecificOutput"])
        XCTAssertEqual(sentTypes, [WireType.stopQuestion])
    }

    func testStopPassSendsCompletionNotification() {
        let stdin = stopInput(message: .string("Which target?"))
        var sentTypes: [String] = []
        var notificationEvent: String?
        let result = CodexHookShim.handle(stdinData: stdin) { message, timeout in
            let type = message["type"]?.stringValue ?? ""
            sentTypes.append(type)
            if type == WireType.stopQuestion {
                return Data(#"{"action":"pass"}"#.utf8)
            }
            notificationEvent = message["event"]?.stringValue
            XCTAssertEqual(message["agent"]?["display_name"]?.stringValue, "Codex")
            XCTAssertEqual(timeout, CodexHookShim.notifyTimeout)
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sentTypes, [WireType.stopQuestion, WireType.notification])
        XCTAssertEqual(notificationEvent, "stop")
    }

    func testActiveStopSkipsQuestionInterceptionButStillNotifies() {
        let stdin = stopInput(message: .string("Ask again?"), active: true)
        var sentTypes: [String] = []
        let result = CodexHookShim.handle(stdinData: stdin) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sentTypes, [WireType.notification])
    }

    func testStopWithoutQuestionOnlyNotifies() {
        let stdin = stopInput(message: .string("All tests pass."))
        var sentTypes: [String] = []
        let result = CodexHookShim.handle(stdinData: stdin) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sentTypes, [WireType.notification])
    }

    func testStopWithNullAssistantMessageOnlyNotifies() {
        let stdin = stopInput(message: .null)
        var sentTypes: [String] = []
        let result = CodexHookShim.handle(stdinData: stdin) { message, _ in
            sentTypes.append(message["type"]?.stringValue ?? "")
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sentTypes, [WireType.notification])
    }

    func testStopQuestionBrokerFailureFailsOpenWithoutSecondSend() {
        let stdin = stopInput()
        var sends = 0
        let result = CodexHookShim.handle(stdinData: stdin) { _, _ in
            sends += 1
            throw StubError.unreachable
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sends, 1)
    }

    func testMalformedStopReplyFailsOpenAndStillNotifies() {
        let stdin = stopInput()
        var sends = 0
        let result = CodexHookShim.handle(stdinData: stdin) { message, _ in
            sends += 1
            if message["type"]?.stringValue == WireType.stopQuestion {
                return Data("not json".utf8)
            }
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sends, 2)
    }

    func testEmptyStopAnswerFailsOpenAndStillNotifies() {
        var sentTypes: [String] = []
        let result = CodexHookShim.handle(stdinData: stopInput()) { message, _ in
            let type = message["type"]?.stringValue ?? ""
            sentTypes.append(type)
            if type == WireType.stopQuestion {
                return Data(#"{"action":"answer","reply":"   "}"#.utf8)
            }
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CodexHookShim.passThrough)
        XCTAssertEqual(sentTypes, [WireType.stopQuestion, WireType.notification])
    }

    func testStopQuestionTextIsTailCapped() {
        let long = String(repeating: "a", count: 20_000) + " Continue?"
        let stdin = stopInput(message: .string(long))
        var sentText: String?

        _ = CodexHookShim.handle(stdinData: stdin) { message, _ in
            if message["type"]?.stringValue == WireType.stopQuestion {
                sentText = message["text"]?.stringValue
                return Data(#"{"action":"pass"}"#.utf8)
            }
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(sentText?.count, CodexHookShim.maxStopQuestionCharacters)
        XCTAssertTrue(sentText?.hasSuffix("Continue?") ?? false)
    }

    func testInvalidStopInputDoesNotReachBroker() {
        var invalidObjects: [[String: JSONValue]] = []
        for key in [
            "session_id", "turn_id", "transcript_path", "cwd", "model",
            "permission_mode", "stop_hook_active", "last_assistant_message",
        ] {
            var missing = stopObject()
            missing.removeValue(forKey: key)
            invalidObjects.append(missing)
        }
        var wrongActiveType = stopObject()
        wrongActiveType["stop_hook_active"] = .string("false")
        invalidObjects.append(wrongActiveType)
        var emptyTurn = stopObject()
        emptyTurn["turn_id"] = .string("")
        invalidObjects.append(emptyTurn)
        var unknownMode = stopObject()
        unknownMode["permission_mode"] = .string("futureMode")
        invalidObjects.append(unknownMode)
        var wrongMessageType = stopObject()
        wrongMessageType["last_assistant_message"] = .array([])
        invalidObjects.append(wrongMessageType)

        for object in invalidObjects {
            var called = false
            let result = CodexHookShim.handle(
                stdinData: try! JSONEncoder().encode(object)
            ) { _, _ in
                called = true
                return Data(#"{"ok":true}"#.utf8)
            }

            XCTAssertFalse(called)
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }
    }

    // MARK: - Generic fail-open behavior

    func testUnknownEventAndMalformedStdinDoNothing() {
        for stdin in [input(#"{"hook_event_name":"PreToolUse"}"#), input("not json")] {
            var called = false
            let result = CodexHookShim.handle(stdinData: stdin) { _, _ in
                called = true
                return Data()
            }
            XCTAssertFalse(called)
            XCTAssertEqual(result, CodexHookShim.passThrough)
        }
    }
}
