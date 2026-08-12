import XCTest
import TapQContracts
@testable import TapQCursorAdapter
import TapQWireProtocol

/// Fixture payloads follow the documented Cursor hook input reference at
/// https://cursor.com/docs/agent/hooks: the common fields every hook receives plus the
/// per-event fields for `beforeShellExecution`, `preToolUse`, and `stop`.
final class CursorHookShimTests: XCTestCase {
    private enum StubError: Error { case unreachable }

    private func commonFields(event: String) -> [String: JSONValue] {
        [
            "conversation_id": .string("conv-1"),
            "generation_id": .string("gen-1"),
            "model": .string("composer-1"),
            "hook_event_name": .string(event),
            "cursor_version": .string("2026.07.30"),
            "workspace_roots": .array([.string("/tmp/project")]),
            "user_email": .null,
            "transcript_path": .null,
        ]
    }

    private func shellObject(
        command: String = "swift test",
        sandbox: JSONValue? = .bool(false)
    ) -> [String: JSONValue] {
        var object = commonFields(event: "beforeShellExecution")
        object["command"] = .string(command)
        object["cwd"] = .string("/tmp/project")
        if let sandbox { object["sandbox"] = sandbox }
        return object
    }

    private func shellInput(
        command: String = "swift test",
        sandbox: JSONValue? = .bool(false)
    ) -> Data {
        try! JSONEncoder().encode(shellObject(command: command, sandbox: sandbox))
    }

    private func preToolUseObject(
        toolName: String = "Write",
        toolInput: JSONValue = .object(["file_path": .string("/tmp/project/App.swift")])
    ) -> [String: JSONValue] {
        var object = commonFields(event: "preToolUse")
        object["tool_name"] = .string(toolName)
        object["tool_input"] = toolInput
        object["tool_use_id"] = .string("toolu-1")
        object["cwd"] = .string("/tmp/project")
        object["agent_message"] = .string("Updating the entry point.")
        return object
    }

    private func preToolUseInput(
        toolName: String = "Write",
        toolInput: JSONValue = .object(["file_path": .string("/tmp/project/App.swift")])
    ) -> Data {
        try! JSONEncoder().encode(
            preToolUseObject(toolName: toolName, toolInput: toolInput)
        )
    }

    private func stopObject(status: String = "completed") -> [String: JSONValue] {
        var object = commonFields(event: "stop")
        object["status"] = .string(status)
        object["loop_count"] = .number(3)
        return object
    }

    private func stopInput(status: String = "completed") -> Data {
        try! JSONEncoder().encode(stopObject(status: status))
    }

    private func permissionOutput(
        _ stdout: String?
    ) throws -> (permission: String, agentMessage: String?, keys: Set<String>) {
        let data = Data((stdout ?? "").utf8)
        let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
        return (
            object["permission"]?.stringValue ?? "",
            object["agent_message"]?.stringValue,
            Set(object.keys)
        )
    }

    // MARK: - beforeShellExecution

    func testShellAllowUsesExactCursorShapeAndNormalizedWireMessage() throws {
        var captured: [String: JSONValue]?
        var capturedTimeout: TimeInterval?

        let result = CursorHookShim.handle(stdinData: shellInput()) { message, timeout in
            captured = message
            capturedTimeout = timeout
            return Data(#"{"decision":"allow"}"#.utf8)
        }

        XCTAssertEqual(result.exitCode, 0)
        let output = try permissionOutput(result.stdout)
        XCTAssertEqual(output.permission, "allow")
        XCTAssertNil(output.agentMessage)
        XCTAssertEqual(output.keys, ["permission"])

        XCTAssertEqual(captured?["type"]?.stringValue, WireType.approval)
        XCTAssertEqual(captured?["agent"]?["id"]?.stringValue, "cursor")
        XCTAssertEqual(captured?["agent"]?["display_name"]?.stringValue, "Cursor")
        XCTAssertEqual(captured?["session_id"]?.stringValue, "conv-1")
        XCTAssertEqual(captured?["cwd"]?.stringValue, "/tmp/project")
        XCTAssertEqual(captured?["tool_name"]?.stringValue, "Shell")
        XCTAssertEqual(captured?["tool_input"]?["command"]?.stringValue, "swift test")
        XCTAssertEqual(captured?["permission_mode"], .null)
        XCTAssertEqual(
            captured?["approval_source"]?.stringValue,
            ApprovalSource.preToolUse.rawValue
        )
        XCTAssertEqual(captured?["summary"]?.stringValue, "run swift test")
        XCTAssertEqual(captured?["detail"]?.stringValue, "Run the command: swift test")
        XCTAssertFalse(captured?["request_id"]?.stringValue?.isEmpty ?? true)
        XCTAssertEqual(captured?["protocol_version"]?.intValue, WireProtocol.version)
        XCTAssertEqual(capturedTimeout, CursorHookShim.approvalTimeout)

        var authenticated = try XCTUnwrap(captured)
        authenticated["token"] = .string("token")
        let request = try BrokerRequest(from: JSONEncoder().encode(authenticated))
        guard case .approval(let approval) = request else {
            return XCTFail("expected approval request")
        }
        XCTAssertEqual(approval.agent, AgentIdentity(id: "cursor", displayName: "Cursor"))
        XCTAssertEqual(approval.approvalSource, .preToolUse)
        XCTAssertEqual(approval.toolName, "Shell")
    }

    func testShellDenyCarriesTheBrokerReasonToTheModel() throws {
        let denied = CursorHookShim.handle(stdinData: shellInput()) { _, _ in
            Data(#"{"decision":"deny","reason":"Declined via TapQ nod"}"#.utf8)
        }

        let output = try permissionOutput(denied.stdout)
        XCTAssertEqual(output.permission, "deny")
        XCTAssertEqual(output.agentMessage, "Declined via TapQ nod")
        XCTAssertEqual(output.keys, ["permission", "agent_message"])
    }

    func testShellDenyFallsBackToTapQReasonAndEscapesIt() throws {
        let plain = CursorHookShim.handle(stdinData: shellInput()) { _, _ in
            Data(#"{"decision":"deny"}"#.utf8)
        }
        XCTAssertEqual(
            try permissionOutput(plain.stdout).agentMessage,
            CursorHookShim.denyReason
        )

        let quoted = CursorHookShim.handle(stdinData: shellInput()) { _, _ in
            let reply: [String: JSONValue] = [
                "decision": .string("deny"),
                "reason": .string("Refused \"rm -rf\"\nby voice"),
            ]
            return try! JSONEncoder().encode(reply)
        }
        XCTAssertEqual(
            try permissionOutput(quoted.stdout).agentMessage,
            "Refused \"rm -rf\"\nby voice"
        )
    }

    /// Cursor runs sandboxed commands without asking, so intercepting them would add an
    /// interruption Cursor never intended.
    func testSandboxedShellExecutionNeverReachesTapQ() {
        var reachedBroker = false
        let result = CursorHookShim.handle(
            stdinData: shellInput(sandbox: .bool(true))
        ) { _, _ in
            reachedBroker = true
            return Data(#"{"decision":"allow"}"#.utf8)
        }

        XCTAssertEqual(result, CursorHookShim.passThrough)
        XCTAssertFalse(reachedBroker)
    }

    func testAbsentSandboxFlagStillReachesTapQ() {
        var reachedBroker = false
        let result = CursorHookShim.handle(stdinData: shellInput(sandbox: nil)) { _, _ in
            reachedBroker = true
            return Data(#"{"decision":"allow"}"#.utf8)
        }

        XCTAssertTrue(reachedBroker)
        XCTAssertEqual(try? permissionOutput(result.stdout).permission, "allow")
    }

    func testInvalidShellInputDoesNotReachBroker() {
        var invalid: [[String: JSONValue]] = []
        for key in ["conversation_id", "generation_id", "workspace_roots", "cwd", "command"] {
            var missing = shellObject()
            missing.removeValue(forKey: key)
            invalid.append(missing)
        }
        var blankCommand = shellObject()
        blankCommand["command"] = .string("   ")
        invalid.append(blankCommand)
        var blankConversation = shellObject()
        blankConversation["conversation_id"] = .string(" ")
        invalid.append(blankConversation)
        var badRoots = shellObject()
        badRoots["workspace_roots"] = .string("/tmp/project")
        invalid.append(badRoots)
        var badSandbox = shellObject(sandbox: .string("false"))
        badSandbox["command"] = .string("swift test")
        invalid.append(badSandbox)

        for object in invalid {
            var reachedBroker = false
            let result = CursorHookShim.handle(
                stdinData: try! JSONEncoder().encode(object)
            ) { _, _ in
                reachedBroker = true
                return Data(#"{"decision":"allow"}"#.utf8)
            }
            XCTAssertFalse(reachedBroker)
            XCTAssertEqual(result, CursorHookShim.passThrough)
        }
    }

    // MARK: - preToolUse

    func testWriteForwardsCursorToolNameAndOpaqueInputVerbatim() throws {
        let toolInput: JSONValue = .object([
            "file_path": .string("/tmp/project/Sources/App.swift"),
            "contents": .string("let secret = \"tapq-secret-value\""),
        ])
        var captured: [String: JSONValue]?

        let result = CursorHookShim.handle(
            stdinData: preToolUseInput(toolName: "Write", toolInput: toolInput)
        ) { message, _ in
            captured = message
            return Data(#"{"decision":"allow"}"#.utf8)
        }

        XCTAssertEqual(try permissionOutput(result.stdout).permission, "allow")
        XCTAssertEqual(captured?["tool_name"]?.stringValue, "Write")
        XCTAssertEqual(captured?["tool_input"], toolInput)

        let summary = try XCTUnwrap(captured?["summary"]?.stringValue)
        let detail = try XCTUnwrap(captured?["detail"]?.stringValue)
        XCTAssertEqual(summary, "write the file App.swift")
        for presentation in [summary, detail] {
            XCTAssertFalse(presentation.contains("tapq-secret-value"))
        }
    }

    func testDeleteIsAnsweredAndDeferralStaysNative() throws {
        let deleted = CursorHookShim.handle(
            stdinData: preToolUseInput(
                toolName: "Delete",
                toolInput: .object(["file_path": .string("/tmp/project/stale.txt")])
            )
        ) { message, _ in
            XCTAssertEqual(message["tool_name"]?.stringValue, "Delete")
            XCTAssertEqual(message["summary"]?.stringValue, "delete the file stale.txt")
            return Data(#"{"decision":"deny","reason":"Kept the file"}"#.utf8)
        }
        XCTAssertEqual(try permissionOutput(deleted.stdout).permission, "deny")

        let deferred = CursorHookShim.handle(
            stdinData: preToolUseInput(toolName: "Delete")
        ) { _, _ in
            Data(#"{"decision":"ask"}"#.utf8)
        }
        XCTAssertEqual(deferred, CursorHookShim.passThrough)
    }

    /// Shell arrives through `beforeShellExecution`; answering it again here would double
    /// every command a user-authored `Shell` matcher happens to route to this executable.
    func testUnmanagedPreToolUseTypesPassThroughWithoutReachingBroker() {
        for toolName in ["Shell", "Read", "Grep", "Task", "MCP:github"] {
            var reachedBroker = false
            let result = CursorHookShim.handle(
                stdinData: preToolUseInput(toolName: toolName)
            ) { _, _ in
                reachedBroker = true
                return Data(#"{"decision":"allow"}"#.utf8)
            }
            XCTAssertFalse(reachedBroker, "\(toolName) must stay native")
            XCTAssertEqual(result, CursorHookShim.passThrough)
        }
    }

    func testInvalidPreToolUseInputDoesNotReachBroker() {
        var invalid: [[String: JSONValue]] = []
        for key in ["conversation_id", "generation_id", "workspace_roots", "cwd", "tool_input"] {
            var missing = preToolUseObject()
            missing.removeValue(forKey: key)
            invalid.append(missing)
        }
        var scalarInput = preToolUseObject()
        scalarInput["tool_input"] = .string("{\"file_path\":\"/tmp/App.swift\"}")
        invalid.append(scalarInput)

        for object in invalid {
            var reachedBroker = false
            let result = CursorHookShim.handle(
                stdinData: try! JSONEncoder().encode(object)
            ) { _, _ in
                reachedBroker = true
                return Data(#"{"decision":"allow"}"#.utf8)
            }
            XCTAssertFalse(reachedBroker)
            XCTAssertEqual(result, CursorHookShim.passThrough)
        }
    }

    // MARK: - Fail-open

    func testApprovalFailsOpenWhenBrokerUnavailableOrReplyIsUnusable() {
        for stdin in [shellInput(), preToolUseInput()] {
            let unreachable = CursorHookShim.handle(stdinData: stdin) { _, _ in
                throw StubError.unreachable
            }
            XCTAssertEqual(unreachable, CursorHookShim.passThrough)

            for reply in [
                #"not json"#,
                #"{"error":"timeout"}"#,
                #"{"error":"bad token"}"#,
                #"{"decision":"ask"}"#,
                #"{"decision":"unknown"}"#,
                #"{"ok":true}"#,
            ] {
                let result = CursorHookShim.handle(stdinData: stdin) { _, _ in
                    Data(reply.utf8)
                }
                XCTAssertEqual(result, CursorHookShim.passThrough, "reply: \(reply)")
            }
        }
    }

    // MARK: - stop

    func testCompletedStopSendsNotificationAndEmitsNoOutput() throws {
        var captured: [String: JSONValue]?
        var capturedTimeout: TimeInterval?

        let result = CursorHookShim.handle(stdinData: stopInput()) { message, timeout in
            captured = message
            capturedTimeout = timeout
            return Data(#"{"ok":true}"#.utf8)
        }

        XCTAssertEqual(result, CursorHookShim.passThrough)
        XCTAssertEqual(captured?["type"]?.stringValue, WireType.notification)
        XCTAssertEqual(captured?["agent"]?["id"]?.stringValue, "cursor")
        XCTAssertEqual(captured?["session_id"]?.stringValue, "conv-1")
        XCTAssertEqual(captured?["event"]?.stringValue, "stop")
        XCTAssertEqual(captured?["summary"], .null)
        XCTAssertEqual(capturedTimeout, CursorHookShim.notifyTimeout)

        var authenticated = try XCTUnwrap(captured)
        authenticated["token"] = .string("token")
        let request = try BrokerRequest(from: JSONEncoder().encode(authenticated))
        guard case .notification(let notification) = request else {
            return XCTFail("expected notification")
        }
        XCTAssertEqual(notification.event, .stop)
        XCTAssertEqual(notification.agent, AgentIdentity(id: "cursor", displayName: "Cursor"))
    }

    func testAbortedAndFailedTurnsAreNotAnnounced() {
        for status in ["aborted", "error"] {
            var reachedBroker = false
            let result = CursorHookShim.handle(stdinData: stopInput(status: status)) { _, _ in
                reachedBroker = true
                return Data(#"{"ok":true}"#.utf8)
            }
            XCTAssertFalse(reachedBroker, "\(status) must not announce completion")
            XCTAssertEqual(result, CursorHookShim.passThrough)
        }
    }

    /// Cursor's `stop` payload carries no final assistant text, so TapQ never continues the
    /// turn: an unreachable broker changes nothing a caller can observe.
    func testStopStaysSilentWhenTheBrokerIsUnreachableOrInputIsInvalid() {
        let unreachable = CursorHookShim.handle(stdinData: stopInput()) { _, _ in
            throw StubError.unreachable
        }
        XCTAssertEqual(unreachable, CursorHookShim.passThrough)

        var invalid: [[String: JSONValue]] = []
        for key in ["conversation_id", "generation_id", "workspace_roots", "status"] {
            var missing = stopObject()
            missing.removeValue(forKey: key)
            invalid.append(missing)
        }

        for object in invalid {
            var reachedBroker = false
            let result = CursorHookShim.handle(
                stdinData: try! JSONEncoder().encode(object)
            ) { _, _ in
                reachedBroker = true
                return Data(#"{"ok":true}"#.utf8)
            }
            XCTAssertFalse(reachedBroker)
            XCTAssertEqual(result, CursorHookShim.passThrough)
        }
    }

    // MARK: - Unknown input

    func testUnknownEventAndMalformedStdinDoNothing() {
        var reachedBroker = false
        let send: ([String: JSONValue], TimeInterval) throws -> Data = { _, _ in
            reachedBroker = true
            return Data()
        }

        for stdin in [
            Data("not json".utf8),
            Data(),
            Data(#"{"hook_event_name":"afterFileEdit","conversation_id":"conv-1"}"#.utf8),
            Data(#"{"hook_event_name":"beforeMCPExecution","conversation_id":"conv-1"}"#.utf8),
            Data(#"{"hook_event_name":"sessionStart","conversation_id":"conv-1"}"#.utf8),
            Data(#"{"conversation_id":"conv-1"}"#.utf8),
        ] {
            XCTAssertEqual(
                CursorHookShim.handle(stdinData: stdin, send: send),
                CursorHookShim.passThrough
            )
        }
        XCTAssertFalse(reachedBroker)
    }
}
